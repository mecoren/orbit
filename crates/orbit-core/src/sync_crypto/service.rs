//! SyncCryptoService — 同步密码与 Data Key 的有状态管理服务
//!
//! 持有运行时 Data Key（内存驻留），提供初始化、解锁、轮换、改密等操作。
//! 持久化委托 `meta_store` 模块，加密原语委托 `crate::crypto` 模块。

use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};

use crate::crypto::{aes_gcm_decrypt, aes_gcm_encrypt, derive_master_key, random_bytes};
use crate::sync_crypto::error::SyncCryptoError;
use crate::sync_crypto::meta_store::{
    SyncCryptoMeta, has_sync_crypto, load_sync_crypto_meta, save_sync_crypto_meta,
};

/// PBKDF2 迭代次数（与 master_auth 一致）
///
/// 取值依据：OWASP 2023 推荐 PBKDF2-HMAC-SHA256 ≥ 600,000。
/// 历史值曾为 200k（旧版）与 600k（更早版本），现统一为 600k。
/// 旧 200k 用户首次解锁后会自动升级到 600k（见 `upgrade_iterations`）。
pub const ITERATIONS: u32 = 600_000;

/// 旧版迭代次数（兼容已存在数据，解锁时自动升级到 `ITERATIONS`）
///
/// 历史 200k 低于 OWASP 2023 推荐值，需在解锁成功后升级到 600k。
const LEGACY_ITERATIONS: u32 = 200_000;

/// Salt 长度（字节）
const SALT_LEN: usize = 16;

/// Data Key 长度（字节，32 = AES-256）
const DATA_KEY_LEN: usize = 32;

/// AES-GCM nonce 长度（字节）
const NONCE_LEN: usize = 12;

/// v2 确定性派生标记（写入 meta.key_derivation）
pub const KEY_DERIVATION_V2: &str = "v2";

/// v2 确定性盐派生的固定域分隔（domain separation）
///
/// 单次 PBKDF2 仅用于从密码派生盐本身，不承担抗暴力强度（真正的强度
/// 在 data_key 派生的 ITERATIONS 轮），故 1 次迭代即可。固定字符串
/// 确保同一密码在任何设备派生出完全相同的 salt。
const V2_SALT_DOMAIN: &str = "orbit-sync-v2-salt";

/// v2 Data Key 派生的固定域分隔
const V2_KEY_DOMAIN: &str = "orbit-sync-v2-key";

/// v2 确定性派生 Data Key（对齐 SiYuan 密码派生模型）
///
/// `salt = PBKDF2(密码, "orbit-sync-v2-salt", 1)`、
/// `data_key = PBKDF2(密码, salt|domain, ITERATIONS)`。
/// 同一密码在任何设备、任何时间派生出同一把 Key——「密码对」与「Key 对」
/// 合并为同一件事，结构性消灭 KeyMismatch 中"密码正确但 Key 不匹配"的
/// 分叉态（该分叉源于 v1 的随机 Data Key + 云端 crypto/config 分发过期）。
pub fn derive_data_key_v2(sync_password: &str) -> Result<(Vec<u8>, Vec<u8>), SyncCryptoError> {
    let salt = derive_master_key(sync_password, V2_SALT_DOMAIN.as_bytes(), 1, SALT_LEN)?;
    // 域分隔字节拼入 salt 作为 PBKDF2 输入，使 v2 Key 与 v1 master_key
    // （同密码同 salt 派生）在输出上不可区分用途
    let mut key_input = salt.clone();
    key_input.extend_from_slice(V2_KEY_DOMAIN.as_bytes());
    let data_key = derive_master_key(sync_password, &key_input, ITERATIONS, DATA_KEY_LEN)?;
    Ok((salt, data_key))
}

/// 同步加密服务
///
/// 线程安全：内部用 `Arc<RwLock>` 保护 Data Key，可跨线程共享。
/// 典型用法：应用启动时创建单例，配置同步密码后调用 `unlock`。
///
/// `Clone` 语义：克隆后两个实例共享同一 `Arc<RwLock>`，Data Key 内存状态同步。
/// `app_data_dir` 字段也克隆（仅路径，廉价），用于读写 meta 文件。
#[derive(Clone)]
pub struct SyncCryptoService {
    app_data_dir: PathBuf,
    /// 运行时 Data Key，未解锁时为 None
    data_key: Arc<RwLock<Option<Vec<u8>>>>,
}

impl SyncCryptoService {
    /// 创建服务实例
    pub fn new(app_data_dir: &Path) -> Self {
        Self {
            app_data_dir: app_data_dir.to_path_buf(),
            data_key: Arc::new(RwLock::new(None)),
        }
    }

    /// 返回 app_data_dir 路径（供 bundle_io 读取本地元数据比对 salt）
    pub fn app_data_dir(&self) -> &Path {
        &self.app_data_dir
    }

    /// 同步密码是否已设置（sync_crypto_meta.json 是否存在）
    pub fn has_sync_password(&self) -> bool {
        has_sync_crypto(&self.app_data_dir)
    }

    /// 同步加密是否已解锁（Data Key 是否在内存中）
    pub fn is_unlocked(&self) -> bool {
        self.data_key
            .read()
            .map(|guard| guard.is_some())
            .unwrap_or(false)
    }

    /// 当前 meta 的密钥方案版本
    ///
    /// 返回 `Ok(None)` = 未设置密码；`Ok(Some("v1"))` / `Ok(Some("v2"))`。
    /// 未知未来版本值按 v1 处理（保守：不会对未知格式做 v2 假设）。
    pub fn meta_version(&self) -> Result<Option<String>, SyncCryptoError> {
        match load_sync_crypto_meta(&self.app_data_dir) {
            Ok(None) => Ok(None),
            Ok(Some(meta)) => Ok(Some(match meta.key_derivation.as_deref() {
                Some(KEY_DERIVATION_V2) => KEY_DERIVATION_V2.to_string(),
                _ => "v1".to_string(),
            })),
            Err(e) => Err(SyncCryptoError::Meta {
                message: e.to_string(),
            }),
        }
    }

    /// v1 → v2 一次性升级：验证密码后用同密码确定性派生替换随机 Key
    ///
    /// **不触碰云端**——云端数据仍是 v1 Key 加密的，调用方必须随后执行
    /// `cloud_sync_api::rekey_cloud` 全量重传（升级后本机新 Key 与云端 v1
    /// 密文必然 KeyMismatch，重传完成前其他设备也不可同步）。
    /// 重传失败时本机已是 v2：下次「立即同步」探针会报 KeyMismatch，
    /// 恢复页提供「以本机为准」兜底（与 rekey 幂等，重传完成即闭环）。
    pub fn upgrade_to_v2(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;

        if meta.key_derivation.as_deref() == Some(KEY_DERIVATION_V2) {
            return Err(SyncCryptoError::Meta {
                message: "当前已是 v2 密钥方案，无需迁移".to_string(),
            });
        }

        // 验证旧密码（v1 解包装，防误操作）
        self.decrypt_data_key_internal(sync_password, &meta)?;

        // 写入 v2 meta（同密码确定性派生）
        let new_meta = self.build_v2_meta(sync_password)?;
        save_sync_crypto_meta(&self.app_data_dir, &new_meta).map_err(|e| {
            SyncCryptoError::Meta {
                message: e.to_string(),
            }
        })?;

        let (_, data_key) = derive_data_key_v2(sync_password)?;
        self.set_data_key(data_key.clone());
        Ok(data_key)
    }

    /// 获取 Data Key（未解锁返回 None）
    pub fn get_data_key(&self) -> Option<Vec<u8>> {
        self.data_key.read().ok().and_then(|guard| guard.clone())
    }

    /// 获取 Data Key 的 base64 编码（供同步引擎桥接使用）
    pub fn get_data_key_base64(&self) -> Option<String> {
        self.get_data_key().map(|k| BASE64.encode(&k))
    }

    /// 初始化同步加密（首次设置同步密码）
    ///
    /// v2：Data Key 由密码确定性派生（跨设备同密码同 Key），用 master_key
    /// 包装派生 Key 作为验证子后持久化，并将 Key 载入内存。
    pub fn init(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        if self.has_sync_password() {
            return Err(SyncCryptoError::Meta {
                message: "同步密码已设置，请使用 unlock 或 change_sync_password".to_string(),
            });
        }

        let meta = self.build_v2_meta(sync_password)?;
        save_sync_crypto_meta(&self.app_data_dir, &meta).map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;

        let (_, data_key) = derive_data_key_v2(sync_password)?;
        self.set_data_key(data_key.clone());
        Ok(data_key)
    }

    /// 构造 v2 元数据：确定性派生 Key + master_key 包装验证子
    ///
    /// encrypted_data_key 字段在 v2 下语义为「验证子」：unlock 时先解包装
    /// 验证密码，再重派生比对一致性，防 meta 被篡改后静默换 Key。
    fn build_v2_meta(&self, sync_password: &str) -> Result<SyncCryptoMeta, SyncCryptoError> {
        let (salt, data_key) = derive_data_key_v2(sync_password)?;
        let master_key = derive_master_key(sync_password, &salt, ITERATIONS, DATA_KEY_LEN)?;
        let nonce = random_bytes(NONCE_LEN);
        let encrypted = aes_gcm_encrypt(&master_key, &data_key, &nonce)?;

        Ok(SyncCryptoMeta {
            salt: BASE64.encode(&salt),
            encrypted_data_key: BASE64.encode(&encrypted),
            data_key_nonce: BASE64.encode(&nonce),
            iterations: ITERATIONS,
            key_derivation: Some(KEY_DERIVATION_V2.to_string()),
        })
    }

    /// 使用已有 Data Key 初始化同步加密（从明文 data key 迁移场景）
    ///
    /// 用同步密码派生 master_key 加密给定的 Data Key（不重新生成），
    /// 持久化到 `sync_crypto_meta.json`，并将 Data Key 载入内存。
    ///
    /// 适用场景：桌面端旧 `sync_config.json` 含明文 `data_key_base64`，
    /// 用户首次设置同步密码时，用此方法包装已有 Data Key，保持云端数据可读。
    pub fn init_with_data_key(
        &self,
        sync_password: &str,
        data_key: &[u8],
    ) -> Result<(), SyncCryptoError> {
        if self.has_sync_password() {
            return Err(SyncCryptoError::Meta {
                message: "同步密码已设置，请使用 unlock 或 change_sync_password".to_string(),
            });
        }

        let meta = self.build_meta_with_key(sync_password, data_key)?;
        save_sync_crypto_meta(&self.app_data_dir, &meta).map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;

        self.set_data_key(data_key.to_vec());
        Ok(())
    }

    /// 解锁同步加密
    ///
    /// 验证同步密码并解密 Data Key 到内存。返回 Data Key。
    ///
    /// - v2 meta：密码派生确定性 Key + 解包装验证子双重校验
    /// - v1 meta：随机 Key 解包装（历史路径，保持存量设备可用）
    /// - v1 旧迭代次数（200000）解锁成功后自动升级到 600000 并重新持久化
    pub fn unlock(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;

        let data_key = if meta.key_derivation.as_deref() == Some(KEY_DERIVATION_V2) {
            self.unlock_v2(sync_password, &meta)?
        } else {
            self.decrypt_data_key_internal(sync_password, &meta)?
        };

        // 旧迭代次数自动升级（仅一次慢解锁；v2 meta 恒为 ITERATIONS 不触发）
        if meta.key_derivation.as_deref() != Some(KEY_DERIVATION_V2)
            && meta.iterations != ITERATIONS
        {
            self.upgrade_iterations(sync_password, &data_key, meta.iterations)?;
        }

        self.set_data_key(data_key.clone());
        Ok(data_key)
    }

    /// v2 解锁：派生 Key 与包装验证子双重校验
    ///
    /// 1. 解包装 encrypted_data_key（密码正确性由 AES-GCM tag 保证）
    /// 2. 重派生确定性 Key 并与包装内容比对（防 meta 被篡改后静默换 Key：
    ///    攻击者改写 meta 内的包装密文可行，但无法使其解出与派生 Key 一致的明文）
    fn unlock_v2(
        &self,
        sync_password: &str,
        meta: &SyncCryptoMeta,
    ) -> Result<Vec<u8>, SyncCryptoError> {
        let wrapped = self.decrypt_data_key_internal(sync_password, meta)?;
        let (_, derived) = derive_data_key_v2(sync_password)?;
        if wrapped != derived {
            return Err(SyncCryptoError::Meta {
                message: "v2 元数据校验失败：包装的 Data Key 与密码派生结果不一致\
                          （元数据可能被篡改，请重设同步密码）"
                    .to_string(),
            });
        }
        Ok(derived)
    }

    /// 锁定同步加密（清除内存中的 Data Key）
    pub fn lock(&self) {
        if let Ok(mut guard) = self.data_key.write() {
            *guard = None;
        }
    }

    /// 修改同步密码
    ///
    /// 验证旧密码后，按当前 meta 版本处理：
    /// - v1：用新密码重新包装当前 Data Key（不重新生成 Data Key）
    /// - v2：新密码确定性派生出新 Data Key 并写入新 meta。**云端旧数据仍是
    ///   旧密码 Key 加密的**——调用方必须随后执行 rekey 全量重传
    ///   （engine::rekey_cloud_reencrypt），否则其他设备将报 KeyMismatch。
    ///   本函数只负责本机 meta，云端编排在命令层。
    pub fn change_sync_password(
        &self,
        old_password: &str,
        new_password: &str,
    ) -> Result<(), SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;

        // 验证旧密码（v2 双重校验 / v1 解包装）
        let _ = self.unlock(old_password)?;

        let new_meta = if meta.key_derivation.as_deref() == Some(KEY_DERIVATION_V2) {
            self.build_v2_meta(new_password)?
        } else {
            // v1：保持现有语义，新密码包装原 Key（Key 不变，云端数据不受影响）
            let data_key = self.decrypt_data_key_internal(old_password, &meta)?;
            self.build_meta_with_key(new_password, &data_key)?
        };

        save_sync_crypto_meta(&self.app_data_dir, &new_meta).map_err(|e| {
            SyncCryptoError::Meta {
                message: e.to_string(),
            }
        })?;

        // v2：改密即换 Key，立即切换内存中的 Key；v1 Key 不变无需切换
        if new_meta.key_derivation.as_deref() == Some(KEY_DERIVATION_V2) {
            let (_, data_key) = derive_data_key_v2(new_password)?;
            self.set_data_key(data_key);
        }

        Ok(())
    }

    /// 密钥轮换（重新生成 Data Key，用同步密码加密）
    ///
    /// 仅 v1 meta 可用（随机 Key 模型）。v2 下 Key 由密码确定性派生，
    /// 「随机换 Key」与确定性语义矛盾——轮换等价于换密码（change_sync_password），
    /// 且同样需要 rekey 全量重传。v2 meta 调用返回错误。
    ///
    /// 注意：轮换后旧 Data Key 加密的云端 .waitsync 将无法解密，
    /// 需配合全量重新上传。
    pub fn rotate_key(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;
        if meta.key_derivation.as_deref() == Some(KEY_DERIVATION_V2) {
            return Err(SyncCryptoError::Meta {
                message: "v2 确定性密钥不支持轮换：请使用 change_sync_password（同样\
                          需要全量重传云端数据）"
                    .to_string(),
            });
        }

        // 用同步密码派生 master_key
        let salt = meta.decode_salt().map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;
        let master_key = derive_master_key(sync_password, &salt, meta.iterations, DATA_KEY_LEN)?;

        // 生成新 Data Key
        let new_data_key = random_bytes(DATA_KEY_LEN);
        let new_nonce = random_bytes(NONCE_LEN);
        let new_encrypted = aes_gcm_encrypt(&master_key, &new_data_key, &new_nonce)?;

        let new_meta = SyncCryptoMeta {
            salt: meta.salt.clone(),
            encrypted_data_key: BASE64.encode(&new_encrypted),
            data_key_nonce: BASE64.encode(&new_nonce),
            iterations: meta.iterations,
            key_derivation: None,
        };

        save_sync_crypto_meta(&self.app_data_dir, &new_meta).map_err(|e| {
            SyncCryptoError::Meta {
                message: e.to_string(),
            }
        })?;

        self.set_data_key(new_data_key.clone());
        Ok(new_data_key)
    }

    /// 导出同步加密元数据包（用于跨设备同步 Data Key）
    ///
    /// 返回当前 `sync_crypto_meta.json` 的内容，可序列化为 JSON 上传到云端。
    /// 其他设备用相同同步密码即可还原 Data Key。
    pub fn export_crypto_bundle(&self) -> Result<SyncCryptoMeta, SyncCryptoError> {
        load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)
    }

    /// 导入同步加密元数据包（从云端同步 Data Key）
    ///
    /// 用同步密码派生 master_key 解密云端的 Data Key，成功则覆盖本地元数据。
    /// 用于 B 设备从云端获取 A 设备的 Data Key。
    ///
    /// **Fix-10 守卫**：本地已设置同步密码且元数据与云端不一致时，
    /// `force = false` 返回 `LocalMetaExists`（导入会静默切换本机 Data Key，
    /// 必须经用户确认后以 `force = true` 重试）。云端 bundle 与本地完全一致
    /// 时无论 force 与否都直接成功（幂等）。
    pub fn import_crypto_bundle(
        &self,
        bundle: &SyncCryptoMeta,
        sync_password: &str,
        force: bool,
    ) -> Result<Vec<u8>, SyncCryptoError> {
        // Fix-10：覆盖守卫——先比对本地 meta，不一致且未确认时拒绝。
        // 放在解密之前可避免"先花 600k 次 PBKDF2 再被拒"的浪费。
        if !force
            && let Ok(Some(local)) =
                crate::sync_crypto::meta_store::load_sync_crypto_meta(&self.app_data_dir)
            && local != *bundle
        {
            return Err(SyncCryptoError::LocalMetaExists);
        }

        // 用同步密码 + 云端 salt 派生 master_key
        let salt = bundle.decode_salt().map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;
        let master_key = derive_master_key(sync_password, &salt, bundle.iterations, DATA_KEY_LEN)?;

        // 用 master_key 解密云端的 Data Key
        let encrypted = bundle
            .decode_encrypted_data_key()
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?;
        let nonce = bundle.decode_nonce().map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;
        let data_key = aes_gcm_decrypt(&master_key, &encrypted, &nonce)?;

        // 覆盖本地元数据
        save_sync_crypto_meta(&self.app_data_dir, bundle).map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;

        self.set_data_key(data_key.clone());
        Ok(data_key)
    }

    // ==================== 内部辅助方法 ====================

    /// 用同步密码派生 master_key 并加密给定 Data Key，构建 v1 元数据
    ///
    /// 仅供 v1 路径使用：`init_with_data_key`（旧明文 Key 迁移）、
    /// `rotate_key`、v1 的 `change_sync_password`。v2 走 `build_v2_meta`。
    fn build_meta_with_key(
        &self,
        sync_password: &str,
        data_key: &[u8],
    ) -> Result<SyncCryptoMeta, SyncCryptoError> {
        let salt = random_bytes(SALT_LEN);
        let master_key = derive_master_key(sync_password, &salt, ITERATIONS, DATA_KEY_LEN)?;
        let nonce = random_bytes(NONCE_LEN);
        let encrypted = aes_gcm_encrypt(&master_key, data_key, &nonce)?;

        Ok(SyncCryptoMeta {
            salt: BASE64.encode(&salt),
            encrypted_data_key: BASE64.encode(&encrypted),
            data_key_nonce: BASE64.encode(&nonce),
            iterations: ITERATIONS,
            key_derivation: None,
        })
    }

    /// 用同步密码解密 Data Key（内部复用）
    fn decrypt_data_key_internal(
        &self,
        sync_password: &str,
        meta: &SyncCryptoMeta,
    ) -> Result<Vec<u8>, SyncCryptoError> {
        let salt = meta.decode_salt().map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;
        let master_key = derive_master_key(sync_password, &salt, meta.iterations, DATA_KEY_LEN)?;

        let encrypted = meta
            .decode_encrypted_data_key()
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?;
        let nonce = meta.decode_nonce().map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;

        // AES-GCM 解密失败自动转为 WrongPassword 错误（由 From<CryptoError> 实现）
        let data_key = aes_gcm_decrypt(&master_key, &encrypted, &nonce)?;
        Ok(data_key)
    }

    /// 旧迭代次数升级（200000 → 600000），仅解锁成功后调用
    ///
    /// 安全语义：升级必须使强度**单调上升**，不允许降级。
    /// 当前仅处理已知旧值 LEGACY_ITERATIONS（200k），目标为 ITERATIONS（600k）。
    /// 若读到比 ITERATIONS 更高的未知值，保持原值不降级（返回 Ok 跳过）。
    fn upgrade_iterations(
        &self,
        sync_password: &str,
        data_key: &[u8],
        old_iterations: u32,
    ) -> Result<(), SyncCryptoError> {
        // 仅处理已知的旧迭代次数（200k）；其他值（含未来更高值）保持不变
        if old_iterations != LEGACY_ITERATIONS {
            return Ok(());
        }
        let new_meta = self.build_meta_with_key(sync_password, data_key)?;
        save_sync_crypto_meta(&self.app_data_dir, &new_meta).map_err(|e| {
            SyncCryptoError::Meta {
                message: e.to_string(),
            }
        })?;
        Ok(())
    }

    /// 设置内存中的 Data Key
    fn set_data_key(&self, key: Vec<u8>) {
        if let Ok(mut guard) = self.data_key.write() {
            *guard = Some(key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_service() -> (SyncCryptoService, TempDir) {
        let tmp = TempDir::new().unwrap();
        (SyncCryptoService::new(tmp.path()), tmp)
    }

    #[test]
    fn init_then_unlock_roundtrip() {
        let (svc, _tmp) = make_service();

        let data_key = svc.init("sync_pw_123").unwrap();
        assert_eq!(data_key.len(), DATA_KEY_LEN);
        assert!(svc.is_unlocked());

        svc.lock();
        assert!(!svc.is_unlocked());

        let unlocked = svc.unlock("sync_pw_123").unwrap();
        assert_eq!(unlocked, data_key, "解锁的 Data Key 必须与初始一致");
    }

    #[test]
    fn unlock_with_wrong_password_fails() {
        let (svc, _tmp) = make_service();
        svc.init("correct_pw").unwrap();
        svc.lock();

        let result = svc.unlock("wrong_pw");
        assert!(matches!(result, Err(SyncCryptoError::WrongPassword)));
        assert!(!svc.is_unlocked());
    }

    #[test]
    fn unlock_without_init_fails() {
        let (svc, _tmp) = make_service();
        let result = svc.unlock("any_pw");
        assert!(matches!(result, Err(SyncCryptoError::NotInitialized)));
    }

    #[test]
    fn double_init_fails() {
        let (svc, _tmp) = make_service();
        svc.init("pw1").unwrap();
        let result = svc.init("pw2");
        assert!(matches!(result, Err(SyncCryptoError::Meta { .. })));
    }

    #[test]
    fn change_sync_password_preserves_data_key() {
        // v1 语义回归：随机 Key + 改密只换包装（通过手工构造 v1 meta 起步）
        let (svc, _tmp) = make_service();
        let original_key = random_bytes(DATA_KEY_LEN);
        svc.init_with_data_key("old_pw", &original_key).unwrap();
        svc.lock();

        svc.change_sync_password("old_pw", "new_pw").unwrap();

        // 旧密码应解锁失败
        svc.lock();
        assert!(svc.unlock("old_pw").is_err());

        // 新密码应解锁成功，且 Data Key 不变
        let unlocked = svc.unlock("new_pw").unwrap();
        assert_eq!(unlocked, original_key, "v1 改密后 Data Key 必须不变");
    }

    #[test]
    fn change_sync_password_with_wrong_old_fails() {
        let (svc, _tmp) = make_service();
        svc.init("old_pw").unwrap();
        svc.lock();

        let result = svc.change_sync_password("wrong", "new");
        assert!(result.is_err());
    }

    #[test]
    fn rotate_key_generates_new_data_key() {
        // v1 语义回归：轮换仅对 v1 meta 有意义（v2 由 v2_rotate_key_rejected 覆盖）
        let (svc, _tmp) = make_service();
        let original_key = random_bytes(DATA_KEY_LEN);
        svc.init_with_data_key("pw", &original_key).unwrap();

        let new_key = svc.rotate_key("pw").unwrap();
        assert_ne!(new_key, original_key, "轮换后 Data Key 必须不同");
        assert!(svc.is_unlocked());
    }

    #[test]
    fn export_then_import_bundle_cross_device() {
        // 模拟 A 设备
        let tmp_a = TempDir::new().unwrap();
        let svc_a = SyncCryptoService::new(tmp_a.path());
        let data_key_a = svc_a.init("shared_pw").unwrap();
        let bundle = svc_a.export_crypto_bundle().unwrap();

        // 模拟 B 设备（不同 app_data_dir）
        let tmp_b = TempDir::new().unwrap();
        let svc_b = SyncCryptoService::new(tmp_b.path());
        assert!(!svc_b.has_sync_password());

        // B 设备导入 A 的 bundle
        let data_key_b = svc_b
            .import_crypto_bundle(&bundle, "shared_pw", true)
            .unwrap();

        // 两端 Data Key 必须一致
        assert_eq!(data_key_a, data_key_b, "跨设备导入后 Data Key 必须一致");
        assert!(svc_b.is_unlocked());
        assert!(svc_b.has_sync_password());
    }

    #[test]
    fn import_bundle_with_wrong_password_fails() {
        let tmp_a = TempDir::new().unwrap();
        let svc_a = SyncCryptoService::new(tmp_a.path());
        svc_a.init("correct_pw").unwrap();
        let bundle = svc_a.export_crypto_bundle().unwrap();

        let tmp_b = TempDir::new().unwrap();
        let svc_b = SyncCryptoService::new(tmp_b.path());

        let result = svc_b.import_crypto_bundle(&bundle, "wrong_pw", true);
        assert!(matches!(result, Err(SyncCryptoError::WrongPassword)));
    }

    // ========================================================================
    // Fix-10: import_crypto_bundle 覆盖守卫
    // ========================================================================

    #[test]
    fn import_guard_rejects_overwrite_without_force() {
        // 设备 A 生成 bundle（密码 pw_a）
        let tmp_a = TempDir::new().unwrap();
        let svc_a = SyncCryptoService::new(tmp_a.path());
        svc_a.init("pw_a").unwrap();
        let bundle_a = svc_a.export_crypto_bundle().unwrap();

        // 设备 B 已设置自己的同步密码（不同的 Data Key）
        let tmp_b = TempDir::new().unwrap();
        let svc_b = SyncCryptoService::new(tmp_b.path());
        svc_b.init("pw_b").unwrap();

        // force=false：本地 meta 与云端不一致 → 必须拒绝，不得静默切换 Key
        let result = svc_b.import_crypto_bundle(&bundle_a, "pw_a", false);
        assert!(
            matches!(result, Err(SyncCryptoError::LocalMetaExists)),
            "未确认时必须返回 LocalMetaExists"
        );
        // 拒绝后本地 meta 与内存 Key 均未被改动
        assert!(svc_b.unlock("pw_b").is_ok(), "本地原 Data Key 必须保持不变");

        // force=true：用户确认后允许覆盖
        let key = svc_b.import_crypto_bundle(&bundle_a, "pw_a", true).unwrap();
        assert_eq!(key.len(), DATA_KEY_LEN);
        assert!(svc_b.unlock("pw_a").is_ok(), "覆盖后应能用云端密码解锁");
    }

    #[test]
    fn import_guard_allows_identical_meta_without_force() {
        let tmp_a = TempDir::new().unwrap();
        let svc_a = SyncCryptoService::new(tmp_a.path());
        svc_a.init("shared_pw").unwrap();
        let bundle = svc_a.export_crypto_bundle().unwrap();

        let tmp_b = TempDir::new().unwrap();
        let svc_b = SyncCryptoService::new(tmp_b.path());
        svc_b
            .import_crypto_bundle(&bundle, "shared_pw", true)
            .unwrap();

        // 云端与本地完全一致时，force=false 也应幂等成功（不触发守卫）
        assert!(
            svc_b
                .import_crypto_bundle(&bundle, "shared_pw", false)
                .is_ok(),
            "meta 一致时应幂等成功"
        );
    }

    #[test]
    fn legacy_iterations_auto_upgrade() {
        let (svc, _tmp) = make_service();

        // 手动写入旧迭代次数的元数据（LEGACY_ITERATIONS=200k）
        let salt = random_bytes(SALT_LEN);
        let master_key =
            derive_master_key("legacy_pw", &salt, LEGACY_ITERATIONS, DATA_KEY_LEN).unwrap();
        let data_key = random_bytes(DATA_KEY_LEN);
        let nonce = random_bytes(NONCE_LEN);
        let encrypted = aes_gcm_encrypt(&master_key, &data_key, &nonce).unwrap();

        let legacy_meta = SyncCryptoMeta {
            salt: BASE64.encode(&salt),
            encrypted_data_key: BASE64.encode(&encrypted),
            data_key_nonce: BASE64.encode(&nonce),
            iterations: LEGACY_ITERATIONS,
            key_derivation: None,
        };
        save_sync_crypto_meta(&svc.app_data_dir, &legacy_meta).unwrap();

        // 解锁应自动升级迭代次数（200k → 600k）
        let unlocked = svc.unlock("legacy_pw").unwrap();
        assert_eq!(unlocked, data_key);

        // 验证已升级到 600k（高于 LEGACY_ITERATIONS，符合"单调上升"语义）
        let updated_meta = load_sync_crypto_meta(&svc.app_data_dir).unwrap().unwrap();
        assert_eq!(updated_meta.iterations, ITERATIONS, "迭代次数必须已升级");
        assert!(
            updated_meta.iterations > LEGACY_ITERATIONS,
            "升级后强度必须高于旧值，不允许降级"
        );
    }

    // ========================================================================
    // v2 确定性派生
    // ========================================================================

    #[test]
    fn v2_init_writes_v2_meta_and_derives_key() {
        let (svc, _tmp) = make_service();
        let key = svc.init("pw_v2").unwrap();

        let meta = load_sync_crypto_meta(&svc.app_data_dir).unwrap().unwrap();
        assert_eq!(meta.key_derivation.as_deref(), Some(KEY_DERIVATION_V2));
        assert_eq!(meta.iterations, ITERATIONS);

        // init 返回的 Key 必须与密码派生结果一致
        let (_, derived) = derive_data_key_v2("pw_v2").unwrap();
        assert_eq!(key, derived);
        assert!(svc.is_unlocked());
    }

    #[test]
    fn v2_derivation_is_deterministic_across_instances() {
        // 核心性质：同一密码在任何目录/设备派生出同一把 Key
        let tmp_a = TempDir::new().unwrap();
        let svc_a = SyncCryptoService::new(tmp_a.path());
        let key_a = svc_a.init("shared_pw").unwrap();

        let tmp_b = TempDir::new().unwrap();
        let svc_b = SyncCryptoService::new(tmp_b.path());
        let key_b = svc_b.init("shared_pw").unwrap();

        assert_eq!(
            key_a, key_b,
            "同密码跨设备必须派生同一 Data Key（v2 核心不变量）"
        );
        // meta 的 salt 也一致（确定性盐），但包装密文不同（随机 nonce）
        let meta_a = load_sync_crypto_meta(&svc_a.app_data_dir).unwrap().unwrap();
        let meta_b = load_sync_crypto_meta(&svc_b.app_data_dir).unwrap().unwrap();
        assert_eq!(meta_a.salt, meta_b.salt);
        assert_ne!(meta_a.encrypted_data_key, meta_b.encrypted_data_key);
    }

    #[test]
    fn v2_unlock_roundtrip_and_wrong_password() {
        let (svc, _tmp) = make_service();
        let key = svc.init("correct").unwrap();

        assert_eq!(svc.unlock("correct").unwrap(), key);
        // 注意：unlock 失败不改变已解锁状态（lock 是显式操作），故先锁定再试错密码
        svc.lock();
        assert!(!svc.is_unlocked());

        let err = svc.unlock("wrong");
        assert!(matches!(err, Err(SyncCryptoError::WrongPassword)));
        assert!(!svc.is_unlocked());
    }

    #[test]
    fn v2_change_password_switches_key() {
        let (svc, _tmp) = make_service();
        let old_key = svc.init("old_pw").unwrap();

        svc.change_sync_password("old_pw", "new_pw").unwrap();

        // 改密即换 Key：新密码解锁得到不同于旧 Key 的新 Key（v1 语义是保 Key）
        svc.lock();
        let new_key = svc.unlock("new_pw").unwrap();
        assert_ne!(old_key, new_key, "v2 改密后 Data Key 必须更换");

        // 旧密码不再可用
        svc.lock();
        assert!(svc.unlock("old_pw").is_err());

        // meta 仍是 v2
        let meta = load_sync_crypto_meta(&svc.app_data_dir).unwrap().unwrap();
        assert_eq!(meta.key_derivation.as_deref(), Some(KEY_DERIVATION_V2));
    }

    #[test]
    fn v2_rotate_key_rejected() {
        let (svc, _tmp) = make_service();
        svc.init("pw").unwrap();
        let result = svc.rotate_key("pw");
        assert!(matches!(result, Err(SyncCryptoError::Meta { .. })));
    }

    #[test]
    fn v2_meta_tamper_detected_on_unlock() {
        // 篡改场景：把 v2 meta 的包装密文换成「另一个密码派生的 Key 的包装」，
        // unlock_v2 的双重校验必须拒绝（包装内容 ≠ 密码派生结果）
        let (svc, _tmp) = make_service();
        svc.init("real_pw").unwrap();

        let mut meta = load_sync_crypto_meta(&svc.app_data_dir).unwrap().unwrap();
        let (_, other_key) = derive_data_key_v2("attacker_pw").unwrap();
        // 用 real_pw 的 master_key 包装 attacker 的 Key（模拟部分篡改）
        let salt = meta.decode_salt().unwrap();
        let master = derive_master_key("real_pw", &salt, meta.iterations, DATA_KEY_LEN).unwrap();
        let nonce = random_bytes(NONCE_LEN);
        let enc = aes_gcm_encrypt(&master, &other_key, &nonce).unwrap();
        meta.encrypted_data_key = BASE64.encode(&enc);
        meta.data_key_nonce = BASE64.encode(&nonce);
        save_sync_crypto_meta(&svc.app_data_dir, &meta).unwrap();

        svc.lock();
        let result = svc.unlock("real_pw");
        assert!(
            matches!(result, Err(SyncCryptoError::Meta { .. })),
            "包装与派生不一致必须拒绝解锁，实际: {:?}",
            result
        );
    }

    #[test]
    fn v1_meta_unlock_still_works() {
        // 兼容性回归：手工构造 v1 meta（随机 Key），unlock 走 v1 路径成功
        let (svc, _tmp) = make_service();
        let salt = random_bytes(SALT_LEN);
        let master_key = derive_master_key("v1_pw", &salt, ITERATIONS, DATA_KEY_LEN).unwrap();
        let random_key = random_bytes(DATA_KEY_LEN);
        let nonce = random_bytes(NONCE_LEN);
        let encrypted = aes_gcm_encrypt(&master_key, &random_key, &nonce).unwrap();
        let v1_meta = SyncCryptoMeta {
            salt: BASE64.encode(&salt),
            encrypted_data_key: BASE64.encode(&encrypted),
            data_key_nonce: BASE64.encode(&nonce),
            iterations: ITERATIONS,
            key_derivation: None,
        };
        save_sync_crypto_meta(&svc.app_data_dir, &v1_meta).unwrap();

        let unlocked = svc.unlock("v1_pw").unwrap();
        assert_eq!(unlocked, random_key, "v1 meta 必须解开原随机 Key");
    }

    #[test]
    fn meta_version_reports_none_v1_v2() {
        let (svc, _tmp) = make_service();
        assert_eq!(svc.meta_version().unwrap(), None, "未设置密码");

        svc.init("pw").unwrap();
        assert_eq!(svc.meta_version().unwrap().as_deref(), Some("v2"));
    }

    #[test]
    fn upgrade_to_v2_switches_meta_and_key() {
        // v1 起步 → 升级 v2：meta 标记切换、Key 换为确定性派生、原密码继续可用
        let (svc, _tmp) = make_service();
        let v1_key = random_bytes(DATA_KEY_LEN);
        svc.init_with_data_key("same_pw", &v1_key).unwrap();
        assert_eq!(svc.meta_version().unwrap().as_deref(), Some("v1"));

        let v2_key = svc.upgrade_to_v2("same_pw").unwrap();
        let (_, derived) = derive_data_key_v2("same_pw").unwrap();
        assert_eq!(v2_key, derived, "升级后 Key 必须是同密码派生结果");
        assert_ne!(v2_key, v1_key, "升级必须脱离原随机 Key");
        assert_eq!(svc.meta_version().unwrap().as_deref(), Some("v2"));
        assert!(svc.is_unlocked());

        // 原密码解锁正常（v2 路径）
        svc.lock();
        assert_eq!(svc.unlock("same_pw").unwrap(), derived);
    }

    #[test]
    fn upgrade_to_v2_rejects_wrong_password() {
        let (svc, _tmp) = make_service();
        let v1_key = random_bytes(DATA_KEY_LEN);
        svc.init_with_data_key("real_pw", &v1_key).unwrap();

        let result = svc.upgrade_to_v2("wrong_pw");
        assert!(matches!(result, Err(SyncCryptoError::WrongPassword)));
        // meta 未被改动
        assert_eq!(svc.meta_version().unwrap().as_deref(), Some("v1"));
    }

    #[test]
    fn upgrade_to_v2_is_idempotent_rejected() {
        let (svc, _tmp) = make_service();
        svc.init("pw").unwrap(); // 直接 v2
        let result = svc.upgrade_to_v2("pw");
        assert!(matches!(result, Err(SyncCryptoError::Meta { .. })));
    }
}
