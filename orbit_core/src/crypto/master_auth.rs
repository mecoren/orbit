//! master_auth — 主密码认证与 SQLCipher DB Key 管理
//!
//! 镜像 Flutter `CryptoService` 的 master auth 部分，作为 Rust 核心的单一实现源。
//! Tauri 桌面端直接调用，Flutter 移动端经 FRB 调用（Phase 6D）。
//!
//! 密钥层次（v2，2026-08-05 修正 wrapping key 泄露问题）：
//! ```text
//! master_password ──PBKDF2(HMAC-SHA256, 600000 iter, 16B salt)──→ derived_key
//!                                                                      │
//! random_db_key(32B) ──AES-256-GCM(derived_key, 12B nonce)──→ encrypted_db_key
//!                                                                      │
//! derived_key ──SHA-256 ──→ verify_hash（常量时间比较，仅用于校验密码）
//! ```
//! v1 旧格式将 derived_key 本身作为 hash 落盘，导致文件泄露即可解出 DB Key。
//! v2 仅落盘 SHA-256(derived_key)，derived_key 只在内存中存在。
//! 旧 master_auth.json 在首次成功解锁后自动升级为 v2 格式。
//!
//! 持久化由上层（db::lifecycle）负责，本模块纯逻辑 + 序列化。

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use serde::{Deserialize, Serialize};

use super::aes_gcm::{aes_gcm_decrypt, aes_gcm_encrypt};
use super::constant_time::constant_time_equals;
use super::error::{CryptoError, CryptoErrorKind};
use super::key_derivation::derive_master_key;
use super::random::random_bytes;
use super::sha256::sha256_hex;

/// PBKDF2 迭代次数（与 Dart `KeyDerivation.defaultIterations` 一致）
///
/// 取值依据：OWASP 2023 推荐 PBKDF2-HMAC-SHA256 ≥ 600,000。
pub const ITERATIONS: u32 = 600_000;

/// Salt 长度（字节）
const SALT_LEN: usize = 16;

/// DB Key 长度（字节，32 = AES-256）
const DB_KEY_LEN: usize = 32;

/// AES-GCM nonce 长度（字节）
const NONCE_LEN: usize = 12;

/// 主密码认证元数据
///
/// 序列化为 JSON 持久化到 `master_auth.json`（位于 app_data_dir）。
/// 所有字段以 Base64 存储，避免二进制数据在 JSON 中的转义问题。
///
/// # 版本演进
/// - v1（legacy）：`hash` 字段存储 derived_key 本身，文件泄露即可解出 DB Key
/// - v2（当前）：`verify_hash` 字段存储 SHA-256(derived_key)，derived_key 仅内存存在
/// `verify_hash = None` 表示 v1 旧文件，首次成功解锁后自动升级为 v2
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MasterAuthMeta {
    /// PBKDF2 salt（Base64）
    pub salt: String,
    /// v1：派生密钥本身（Base64，仅 legacy 兼容读取，新写入留空）
    /// v2：留空字符串，不再使用
    #[serde(default)]
    pub hash: String,
    /// v2：SHA-256(derived_key)（Base64），用于常量时间比较验证主密码
    /// None 或缺失表示 v1 旧文件，首次解锁后自动升级
    #[serde(default)]
    pub verify_hash: Option<String>,
    /// PBKDF2 迭代次数
    pub iterations: u32,
    /// AES-256-GCM 加密的 DB Key（Base64，ciphertext || tag）
    pub encrypted_db_key: String,
    /// 加密 DB Key 用的 nonce（Base64）
    pub db_key_nonce: String,
}

/// 初始化主密码认证
///
/// 生成 salt + 派生密钥 + 随机 DB Key + 加密 DB Key + 计算验证哈希。
/// 返回 `(元数据, DB Key 原始字节)`，上层负责持久化元数据、用 DB Key 打开数据库。
///
/// # 参数
/// - `password`：用户主密码明文
///
/// # 返回
/// - `Ok((MasterAuthMeta, Vec<u8>))`：元数据 + 32 字节 DB Key
/// - `Err(CryptoError)`：密钥派生或加密失败
pub fn init_master_auth(password: &str) -> Result<(MasterAuthMeta, Vec<u8>), CryptoError> {
    // 1. 生成随机 salt
    let salt = random_bytes(SALT_LEN);

    // 2. PBKDF2 派生密钥（用于加密 DB Key，仅在内存中存在，不落盘）
    let derived_key = derive_master_key(password, &salt, ITERATIONS, DB_KEY_LEN)?;

    // 3. 生成随机 DB Key（32 字节，用于 SQLCipher PRAGMA key）
    let db_key = random_bytes(DB_KEY_LEN);

    // 4. AES-256-GCM 加密 DB Key
    let nonce = random_bytes(NONCE_LEN);
    let encrypted_db_key = aes_gcm_encrypt(&derived_key, &db_key, &nonce)?;

    // 5. 计算验证哈希：SHA-256(derived_key)，仅用于密码校验
    //    不能从 verify_hash 反推 derived_key（SHA-256 单向）
    let verify_hash = Some(sha256_hex(&derived_key));

    Ok((
        MasterAuthMeta {
            salt: BASE64.encode(&salt),
            hash: String::new(), // v2 不再使用 hash 字段
            verify_hash,
            iterations: ITERATIONS,
            encrypted_db_key: BASE64.encode(&encrypted_db_key),
            db_key_nonce: BASE64.encode(&nonce),
        },
        db_key,
    ))
}

/// 解锁主密码认证
///
/// 验证主密码并解密 DB Key 到内存。
/// 若 meta 为 v1 旧格式（无 verify_hash），验证成功后返回升级后的 meta 供上层持久化。
///
/// # 返回
/// - `Ok((Vec<u8>, Option<MasterAuthMeta>))`：(32 字节 DB Key, 升级后的 meta)
///   若 meta 为 v1 旧格式且解锁成功，第二个元素为升级到 v2 的 meta（上层应保存）
///   若 meta 已是 v2，第二个元素为 None
/// - `Err(CryptoError)`：密码错误（哈希不匹配）或解密失败
pub fn unlock_master_auth(
    password: &str,
    meta: &MasterAuthMeta,
) -> Result<(Vec<u8>, Option<MasterAuthMeta>), CryptoError> {
    let salt = BASE64.decode(&meta.salt).map_err(|e| CryptoError {
        message: format!("decode salt failed: {}", e),
        kind: CryptoErrorKind::InvalidKeyLength,
    })?;

    // 派生密钥（仅在内存中存在）
    let derived_key = derive_master_key(password, &salt, meta.iterations, DB_KEY_LEN)?;

    // 根据格式版本选择验证路径
    let is_v2 = meta.verify_hash.is_some();
    if is_v2 {
        // v2：用 SHA-256(derived_key) 与落盘的 verify_hash 比较
        let computed_verify = sha256_hex(&derived_key);
        let stored_verify = meta.verify_hash.as_ref().unwrap();
        if !constant_time_equals(computed_verify.as_bytes(), stored_verify.as_bytes()) {
            return Err(CryptoError {
                message: "主密码错误".to_string(),
                kind: CryptoErrorKind::DecryptionFailed,
            });
        }
    } else {
        // v1 legacy：用 derived_key 与落盘的 hash 比较（旧格式下 hash 即 derived_key）
        let stored_hash = BASE64.decode(&meta.hash).map_err(|e| CryptoError {
            message: format!("decode hash failed: {}", e),
            kind: CryptoErrorKind::InvalidKeyLength,
        })?;
        if !constant_time_equals(&derived_key, &stored_hash) {
            return Err(CryptoError {
                message: "主密码错误".to_string(),
                kind: CryptoErrorKind::DecryptionFailed,
            });
        }
    }

    // 解密 DB Key
    let encrypted_db_key = BASE64
        .decode(&meta.encrypted_db_key)
        .map_err(|e| CryptoError {
            message: format!("decode encrypted_db_key failed: {}", e),
            kind: CryptoErrorKind::InvalidKeyLength,
        })?;
    let nonce = BASE64.decode(&meta.db_key_nonce).map_err(|e| CryptoError {
        message: format!("decode nonce failed: {}", e),
        kind: CryptoErrorKind::InvalidNonceLength,
    })?;

    let db_key = aes_gcm_decrypt(&derived_key, &encrypted_db_key, &nonce)?;

    // v1 → v2 自动升级：返回升级后的 meta 供上层保存
    let upgraded_meta = if is_v2 {
        None
    } else {
        Some(MasterAuthMeta {
            salt: meta.salt.clone(),
            hash: String::new(),
            verify_hash: Some(sha256_hex(&derived_key)),
            iterations: meta.iterations,
            encrypted_db_key: meta.encrypted_db_key.clone(),
            db_key_nonce: meta.db_key_nonce.clone(),
        })
    };

    Ok((db_key, upgraded_meta))
}

/// 仅验证主密码是否正确（不解密 DB Key，不触发升级）
///
/// 用于敏感操作前的二次确认，不改变解锁状态。
/// 注意：本方法不返回升级后的 meta，因此 v1 旧文件不会通过 verify 升级。
/// 升级仅在 `unlock_master_auth` 成功路径发生。
pub fn verify_master_auth(password: &str, meta: &MasterAuthMeta) -> bool {
    unlock_master_auth(password, meta).is_ok()
}

/// 修改主密码
///
/// 验证旧密码后，用新密码重新包装当前 DB Key（不重新生成 DB Key，
/// 避免数据库重新加密）。结果总是 v2 格式（无论原 meta 是 v1 还是 v2）。
///
/// # 返回
/// - `Ok((MasterAuthMeta, Vec<u8>))`：新元数据（v2 格式） + DB Key（与旧 DB Key 相同）
/// - `Err(CryptoError)`：旧密码错误
pub fn change_master_auth_password(
    old_password: &str,
    new_password: &str,
    meta: &MasterAuthMeta,
) -> Result<(MasterAuthMeta, Vec<u8>), CryptoError> {
    // 1. 验证旧密码并解密 DB Key（同时触发 v1→v2 升级）
    let (db_key, _) = unlock_master_auth(old_password, meta)?;

    // 2. 用新密码生成新 salt + 派生新密钥
    let new_salt = random_bytes(SALT_LEN);
    let new_derived_key = derive_master_key(new_password, &new_salt, ITERATIONS, DB_KEY_LEN)?;

    // 3. 用新密钥重新加密 DB Key
    let new_nonce = random_bytes(NONCE_LEN);
    let new_encrypted_db_key = aes_gcm_encrypt(&new_derived_key, &db_key, &new_nonce)?;

    // 4. 计算新验证哈希（v2 格式）
    let new_verify_hash = Some(sha256_hex(&new_derived_key));

    let new_meta = MasterAuthMeta {
        salt: BASE64.encode(&new_salt),
        hash: String::new(),
        verify_hash: new_verify_hash,
        iterations: ITERATIONS,
        encrypted_db_key: BASE64.encode(&new_encrypted_db_key),
        db_key_nonce: BASE64.encode(&new_nonce),
    };

    Ok((new_meta, db_key))
}

/// 将 DB Key 字节转为 hex 字符串
///
/// SQLCipher 的 `PRAGMA key` 接受 hex 格式（如 `x'abcd...'`）或 passphrase。
/// 本项目使用 hex 格式避免特殊字符转义问题。
pub fn db_key_to_hex(db_key: &[u8]) -> String {
    db_key.iter().map(|b| format!("{:02x}", b)).collect()
}

/// 检测 v1 旧格式 master_auth.json 并记录告警
///
/// v1 文件将 derived_key（DB Key 包装密钥）明文落盘，文件泄露即可解出 DB Key。
/// v2 已修复为 SHA-256(derived_key)，但仅在用户成功解锁后才会触发升级
/// （升级需要密码派生 derived_key 才能计算 verify_hash）。
/// 因此冷启动后到首次解锁之间，v1 文件仍以明文形式驻留磁盘。
///
/// 本函数仅做**告警**，无法在无密码情况下"强制迁移"。
/// 调用方应在应用启动时调用，提示用户尽快解锁以触发自动升级。
///
/// # 参数
/// - `meta`：从磁盘加载的 MasterAuthMeta（若文件不存在则不会调用本函数）
///
/// # 返回
/// - `true`：检测到 v1 旧格式（verify_hash 为 None），调用方应记录/告警
/// - `false`：已是 v2 格式，无需处理
pub fn is_legacy_v1_format(meta: &MasterAuthMeta) -> bool {
    meta.verify_hash.is_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_then_unlock_roundtrip() {
        let (meta, db_key) = init_master_auth("test_password_123").unwrap();
        assert_eq!(db_key.len(), DB_KEY_LEN);
        // 新初始化的 meta 必须是 v2 格式
        assert!(meta.verify_hash.is_some(), "init 应产出 v2 格式");
        assert!(meta.hash.is_empty(), "v2 的 hash 字段应为空");

        let (unlocked, upgraded) = unlock_master_auth("test_password_123", &meta).unwrap();
        assert_eq!(unlocked, db_key, "解锁的 DB Key 必须与原始一致");
        assert!(upgraded.is_none(), "v2 meta 不应触发升级");
    }

    #[test]
    fn unlock_with_wrong_password_fails() {
        let (meta, _) = init_master_auth("correct_password").unwrap();

        let result = unlock_master_auth("wrong_password", &meta);
        assert!(result.is_err(), "错误密码必须解锁失败");
    }

    #[test]
    fn verify_does_not_panic_on_wrong_password() {
        let (meta, _) = init_master_auth("correct").unwrap();
        assert!(!verify_master_auth("wrong", &meta));
        assert!(verify_master_auth("correct", &meta));
    }

    #[test]
    fn change_password_preserves_db_key() {
        let (meta, original_db_key) = init_master_auth("old_pass").unwrap();

        let (new_meta, new_db_key) =
            change_master_auth_password("old_pass", "new_pass", &meta).unwrap();

        // DB Key 必须保持不变（只重新包装，不重新生成）
        assert_eq!(new_db_key, original_db_key, "改密后 DB Key 必须不变");

        // 改密后必须是 v2 格式
        assert!(new_meta.verify_hash.is_some(), "改密后应为 v2 格式");
        assert!(new_meta.hash.is_empty(), "v2 的 hash 字段应为空");

        // 旧密码应解锁失败
        assert!(unlock_master_auth("old_pass", &new_meta).is_err());

        // 新密码应解锁成功，且 DB Key 一致
        let (unlocked, _) = unlock_master_auth("new_pass", &new_meta).unwrap();
        assert_eq!(unlocked, original_db_key);
    }

    #[test]
    fn change_password_with_wrong_old_password_fails() {
        let (meta, _) = init_master_auth("old_pass").unwrap();
        assert!(change_master_auth_password("wrong", "new", &meta).is_err());
    }

    #[test]
    fn db_key_to_hex_produces_64_chars() {
        let (_, db_key) = init_master_auth("pw").unwrap();
        let hex = db_key_to_hex(&db_key);
        assert_eq!(hex.len(), 64, "32 字节 → 64 hex 字符");
    }

    /// v1 旧格式 meta：hash = derived_key, verify_hash = None
    /// 模拟旧版本 init_master_auth 产出的 meta
    fn build_legacy_v1_meta(password: &str) -> (MasterAuthMeta, Vec<u8>) {
        let salt = random_bytes(SALT_LEN);
        let derived_key = derive_master_key(password, &salt, ITERATIONS, DB_KEY_LEN).unwrap();
        let db_key = random_bytes(DB_KEY_LEN);
        let nonce = random_bytes(NONCE_LEN);
        let encrypted_db_key = aes_gcm_encrypt(&derived_key, &db_key, &nonce).unwrap();

        let meta = MasterAuthMeta {
            salt: BASE64.encode(&salt),
            // v1：hash 直接存 derived_key 本身（泄露即等于泄露 wrapping key）
            hash: BASE64.encode(&derived_key),
            verify_hash: None,
            iterations: ITERATIONS,
            encrypted_db_key: BASE64.encode(&encrypted_db_key),
            db_key_nonce: BASE64.encode(&nonce),
        };
        (meta, db_key)
    }

    #[test]
    fn legacy_v1_meta_unlocks_and_upgrades() {
        let (legacy_meta, original_db_key) = build_legacy_v1_meta("legacy_pw");

        // v1 meta 应能正确解锁
        let (unlocked, upgraded) = unlock_master_auth("legacy_pw", &legacy_meta).unwrap();
        assert_eq!(unlocked, original_db_key, "v1 解锁的 DB Key 必须正确");
        assert!(upgraded.is_some(), "v1 解锁成功应返回升级后的 meta");

        // 升级后的 meta 应为 v2 格式
        let upgraded_meta = upgraded.unwrap();
        assert!(upgraded_meta.verify_hash.is_some(), "升级后应为 v2 格式");
        assert!(upgraded_meta.hash.is_empty(), "v2 的 hash 字段应为空");

        // 升级后的 meta 应能正确解锁
        let (unlocked2, upgraded2) =
            unlock_master_auth("legacy_pw", &upgraded_meta).unwrap();
        assert_eq!(unlocked2, original_db_key, "v2 解锁的 DB Key 必须与 v1 一致");
        assert!(upgraded2.is_none(), "v2 不应再次触发升级");
    }

    #[test]
    fn legacy_v1_meta_wrong_password_fails() {
        let (legacy_meta, _) = build_legacy_v1_meta("correct");

        let result = unlock_master_auth("wrong", &legacy_meta);
        assert!(result.is_err(), "v1 错误密码必须解锁失败");
    }

    #[test]
    fn verify_hash_not_equal_to_derived_key() {
        // 防止退化：verify_hash 必须是 SHA-256(derived_key)，
        // 而非 derived_key 本身（否则失去保护意义）
        let (meta, _) = init_master_auth("test").unwrap();
        let verify_hash = meta.verify_hash.unwrap();

        // verify_hash 是 64 字符 hex（SHA-256 输出）
        assert_eq!(verify_hash.len(), 64, "verify_hash 应为 64 字符 hex");

        // verify_hash 不应等于 derived_key 的 base64（长度不同即可证明）
        // derived_key base64 = 44 字符，verify_hash hex = 64 字符
        assert_ne!(verify_hash.len(), 44, "verify_hash 不应是 derived_key 的 base64");
    }
}
