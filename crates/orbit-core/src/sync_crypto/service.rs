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
    /// 生成 salt + Data Key，用同步密码派生 master_key 加密 Data Key，
    /// 持久化到 `sync_crypto_meta.json`，并将 Data Key 载入内存。
    pub fn init(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        if self.has_sync_password() {
            return Err(SyncCryptoError::Meta {
                message: "同步密码已设置，请使用 unlock 或 change_sync_password".to_string(),
            });
        }

        let meta = self.build_initial_meta(sync_password)?;
        save_sync_crypto_meta(&self.app_data_dir, &meta).map_err(|e| SyncCryptoError::Meta {
            message: e.to_string(),
        })?;

        // 解码 Data Key 载入内存（build_initial_meta 返回的 meta 已含加密后的 Data Key，
        // 这里需返回原始 Data Key）
        // 实际上 build_initial_meta 内部已生成 Data Key，我们通过解密还原
        let data_key = self.decrypt_data_key_internal(sync_password, &meta)?;
        self.set_data_key(data_key.clone());
        Ok(data_key)
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
    /// 若使用旧迭代次数（200000）解锁成功，自动升级到 600000 并重新持久化。
    pub fn unlock(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;

        let data_key = self.decrypt_data_key_internal(sync_password, &meta)?;

        // 旧迭代次数自动升级（仅一次慢解锁）
        if meta.iterations != ITERATIONS {
            self.upgrade_iterations(sync_password, &data_key, meta.iterations)?;
        }

        self.set_data_key(data_key.clone());
        Ok(data_key)
    }

    /// 锁定同步加密（清除内存中的 Data Key）
    pub fn lock(&self) {
        if let Ok(mut guard) = self.data_key.write() {
            *guard = None;
        }
    }

    /// 修改同步密码
    ///
    /// 验证旧密码后，用新密码重新包装当前 Data Key（不重新生成 Data Key）。
    pub fn change_sync_password(
        &self,
        old_password: &str,
        new_password: &str,
    ) -> Result<(), SyncCryptoError> {
        // 1. 验证旧密码并解密 Data Key
        let data_key = self.unlock(old_password)?;

        // 2. 用新密码生成新 salt + 派生新 master_key
        let new_meta = self.build_meta_with_key(new_password, &data_key)?;

        // 3. 持久化新元数据
        save_sync_crypto_meta(&self.app_data_dir, &new_meta).map_err(|e| {
            SyncCryptoError::Meta {
                message: e.to_string(),
            }
        })?;

        Ok(())
    }

    /// 密钥轮换（重新生成 Data Key，用同步密码加密）
    ///
    /// 注意：轮换后旧 Data Key 加密的云端 .waitsync 将无法解密，
    /// 需配合全量重新上传。
    pub fn rotate_key(&self, sync_password: &str) -> Result<Vec<u8>, SyncCryptoError> {
        let meta = load_sync_crypto_meta(&self.app_data_dir)
            .map_err(|e| SyncCryptoError::Meta {
                message: e.to_string(),
            })?
            .ok_or(SyncCryptoError::NotInitialized)?;

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

    /// 生成初始元数据（生成 salt + Data Key + 加密）
    fn build_initial_meta(&self, sync_password: &str) -> Result<SyncCryptoMeta, SyncCryptoError> {
        let data_key = random_bytes(DATA_KEY_LEN);
        self.build_meta_with_key(sync_password, &data_key)
    }

    /// 用同步密码派生 master_key 并加密给定 Data Key，构建元数据
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
        let (svc, _tmp) = make_service();
        let original_key = svc.init("old_pw").unwrap();
        svc.lock();

        svc.change_sync_password("old_pw", "new_pw").unwrap();

        // 旧密码应解锁失败
        svc.lock();
        assert!(svc.unlock("old_pw").is_err());

        // 新密码应解锁成功，且 Data Key 不变
        let unlocked = svc.unlock("new_pw").unwrap();
        assert_eq!(unlocked, original_key, "改密后 Data Key 必须不变");
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
        let (svc, _tmp) = make_service();
        let old_key = svc.init("pw").unwrap();

        let new_key = svc.rotate_key("pw").unwrap();
        assert_ne!(new_key, old_key, "轮换后 Data Key 必须不同");
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
}
