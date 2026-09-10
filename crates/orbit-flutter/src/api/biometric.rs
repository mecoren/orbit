//! biometric — 生物识别解锁（密钥链编排）
//!
//! 对接 `orbit_core::crypto::biometric`：Rust 侧负责密钥链加解密编排，
//! Dart 侧仅用 `local_auth` 采集指纹闸门（不参与密钥派生）。
//!
//! 密钥链（与 core::crypto::biometric 模块文档一致）：
//! ```text
//! 指纹闸门（local_auth，Dart 侧）
//!   └─► Secure Storage 三件套（encrypted_db_key_bio / biometric_key / nonce，
//!        均为 Base64 standard 编码，由 Dart 侧 flutter_secure_storage 读写）
//!         └─► AES-256-GCM 解密 encrypted_db_key_bio → DB Key hex
//!               └─► dbInitEncrypted 进入主界面（与主密码解锁路径汇合）
//! ```
//!
//! 边界：Secure Storage 的读写留在 Dart（凭据存储属平台职责）；
//! 密钥生成/加密/解密/销毁全在 Rust，保证加解密口径单一（core 单测覆盖）。

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};

use orbit_core::crypto::aes_gcm::aes_gcm_encrypt;
use orbit_core::crypto::biometric::biometric_unlock_db_key;
use orbit_core::crypto::master_auth::verify_master_auth;
use orbit_core::crypto::random::random_bytes;
use orbit_core::db::lifecycle;

/// Biometric Key 长度（字节，32 = AES-256；与 core 同口径）
const BIOMETRIC_KEY_LEN: usize = 32;

/// GCM nonce 长度（字节，与 core AES-GCM 实现口径一致）
const NONCE_LEN: usize = 12;

/// 生成 biometric 密钥链三件套（Base64 standard 编码，供 Dart 写入 Secure Storage）
///
/// 调用前提：用户已通过主密码解锁（本次会话持有 DB Key），且刚通过
/// local_auth 认证成功。返回值即 Secure Storage 的存储载荷：
/// - `encrypted_db_key_bio`：AES-256-GCM(Biometric Key, DB Key, nonce)
/// - `biometric_key`：32 字节随机 Biometric Key
/// - `nonce`：12 字节随机 nonce
///
/// 随机性由 core::crypto::random 提供（ring OsRng）。
pub fn biometric_setup(db_key_hex: String) -> Result<BiometricSecretBundle, String> {
    let db_key = hex_decode(&db_key_hex)?;

    let biometric_key = random_bytes(BIOMETRIC_KEY_LEN);
    let nonce = random_bytes(NONCE_LEN);
    let encrypted_db_key = aes_gcm_encrypt(&biometric_key, &db_key, &nonce)
        .map_err(|e| format!("加密 DB Key 失败: {e}"))?;

    Ok(BiometricSecretBundle {
        encrypted_db_key_bio: BASE64.encode(&encrypted_db_key),
        biometric_key: BASE64.encode(&biometric_key),
        nonce: BASE64.encode(&nonce),
    })
}

/// 用 Biometric Key 解密出 DB Key hex（对齐 masterAuthUnlock 契约，
/// 不直接初始化数据库）
///
/// Dart 侧流程：local_auth 认证通过 → Secure Storage 读三件套 → 调本函数
/// 拿 db_key_hex → dbInitEncrypted —— 与密码解锁路径在 BootGate 汇合为
/// 同一终态，保持 DB 初始化单一路径。密钥错误（GCM tag 校验失败）抛
/// `[biometric_failed]`，由 UnlockPage 展示后回落密码输入。
pub fn biometric_unlock(
    encrypted_db_key_bio_base64: String,
    biometric_key_base64: String,
    nonce_base64: String,
) -> Result<String, String> {
    biometric_unlock_db_key(
        &encrypted_db_key_bio_base64,
        &biometric_key_base64,
        &nonce_base64,
    )
    .map_err(|e| format!("[biometric_failed] 生物识别解锁失败（密钥数据可能已损坏）: {e}"))
}

/// 关闭生物识别前的密码确认（防误触；Dart 侧验证通过后删除 Secure Storage 三件套）
///
/// 仅验证主密码是否正确，不产生任何写入；真正的密钥链清除在 Dart 侧
/// 删除 Secure Storage 三键后即完成，Rust 无状态可清。
pub fn biometric_disable(base_dir: String, password: String) -> Result<(), String> {
    let dir = std::path::PathBuf::from(base_dir);
    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;
    if verify_master_auth(&password, &meta) {
        Ok(())
    } else {
        Err("[wrong_password] 主密码错误".to_string())
    }
}

/// hex 字符串解码为字节（DB Key hex 双向转换；小写/大写均收）
fn hex_decode(hex: &str) -> Result<Vec<u8>, String> {
    if hex.len() % 2 != 0 {
        return Err("[invalid_input] DB Key hex 长度非法".to_string());
    }
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
        .collect::<Result<Vec<u8>, _>>()
        .map_err(|_| "[invalid_input] DB Key hex 含非法字符".to_string())?;
    Ok(bytes)
}

/// biometric 密钥链三件套（Base64 standard 编码）
pub struct BiometricSecretBundle {
    pub encrypted_db_key_bio: String,
    pub biometric_key: String,
    pub nonce: String,
}
