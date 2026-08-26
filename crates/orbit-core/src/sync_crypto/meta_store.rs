//! sync_crypto_meta.json 文件持久化
//!
//! 参考 `db::lifecycle` 的 `master_auth.json` 模式。
//! 文件布局：
//! ```text
//! {app_data_dir}/
//! ├── wait_home.db
//! ├── master_auth.json      ← 主密码认证元数据
//! └── sync_crypto_meta.json ← 同步密码加密元数据（本模块）
//! ```

use std::path::{Path, PathBuf};

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use serde::{Deserialize, Serialize};

use crate::error::CoreResult;

/// 同步加密元数据
///
/// 序列化为 JSON 持久化到 `sync_crypto_meta.json`（位于 app_data_dir）。
/// 所有字段以 Base64 存储，避免二进制数据在 JSON 中的转义问题。
///
/// 与 `MasterAuthMeta` 的区别：不存储验证哈希（sync password 通过 AES-GCM
/// tag 验证失败来判定密码错误，无需额外哈希）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncCryptoMeta {
    /// PBKDF2 salt（Base64）
    pub salt: String,
    /// AES-256-GCM 加密的 Data Key（Base64，ciphertext || tag）
    pub encrypted_data_key: String,
    /// 加密 Data Key 用的 nonce（Base64）
    pub data_key_nonce: String,
    /// PBKDF2 迭代次数
    pub iterations: u32,
}

impl SyncCryptoMeta {
    /// 解码 salt 为原始字节
    pub fn decode_salt(&self) -> Result<Vec<u8>, base64::DecodeError> {
        BASE64.decode(&self.salt)
    }

    /// 解码 encrypted_data_key 为原始字节
    pub fn decode_encrypted_data_key(&self) -> Result<Vec<u8>, base64::DecodeError> {
        BASE64.decode(&self.encrypted_data_key)
    }

    /// 解码 nonce 为原始字节
    pub fn decode_nonce(&self) -> Result<Vec<u8>, base64::DecodeError> {
        BASE64.decode(&self.data_key_nonce)
    }
}

/// 同步加密元数据文件名
const META_FILE_NAME: &str = "sync_crypto_meta.json";

/// 返回同步加密元数据文件路径
pub fn sync_crypto_meta_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(META_FILE_NAME)
}

/// 判断同步密码是否已设置（sync_crypto_meta.json 是否存在）
pub fn has_sync_crypto(app_data_dir: &Path) -> bool {
    sync_crypto_meta_path(app_data_dir).exists()
}

/// 从文件加载同步加密元数据
///
/// 文件不存在返回 `Ok(None)`（表示未设置同步密码）。
/// 文件存在但损坏：先改名留证（`*.corrupt-{ts}`，Fix-04），再返回明确错误——
/// **绝不**返回 `Ok(None)`，否则上层会误判"未设置密码"并允许重新 init，
/// 生成全新 Data Key 导致云端旧数据全部不可解密。
pub fn load_sync_crypto_meta(app_data_dir: &Path) -> CoreResult<Option<SyncCryptoMeta>> {
    let path = sync_crypto_meta_path(app_data_dir);
    if !path.exists() {
        return Ok(None);
    }
    let content = std::fs::read_to_string(&path)?;
    match serde_json::from_str::<SyncCryptoMeta>(&content) {
        Ok(meta) => Ok(Some(meta)),
        Err(e) => {
            // 损坏留证后再报错，避免后续写入覆盖最后的可诊断证据
            let quarantined =
                crate::fs_util::quarantine_corrupt_file(&path).unwrap_or_else(|_| path.clone());
            log::error!(
                "[meta_store] sync_crypto_meta.json 损坏已隔离至 {:?}，\
                 请勿重新初始化同步密码（会导致云端数据无法解密）：{}",
                quarantined,
                e
            );
            Err(crate::error::CoreError::Other(format!(
                "sync_crypto_meta.json 损坏（已留证 {:?}）：{}",
                quarantined, e
            )))
        }
    }
}

/// 持久化同步加密元数据到文件（原子写，Fix-04）
pub fn save_sync_crypto_meta(app_data_dir: &Path, meta: &SyncCryptoMeta) -> CoreResult<()> {
    let path = sync_crypto_meta_path(app_data_dir);
    let content = serde_json::to_string_pretty(meta)?;
    crate::fs_util::write_atomic(&path, content.as_bytes())?;
    Ok(())
}

/// 清除同步加密元数据（用于重置同步配置）
///
/// 删除 `sync_crypto_meta.json` 文件。若文件不存在则无操作。
pub fn clear_sync_crypto_meta(app_data_dir: &Path) -> CoreResult<()> {
    let path = sync_crypto_meta_path(app_data_dir);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn meta_path_is_in_app_data_dir() {
        let dir = Path::new("/tmp/test_app");
        assert_eq!(
            sync_crypto_meta_path(dir),
            Path::new("/tmp/test_app/sync_crypto_meta.json")
        );
    }

    #[test]
    fn has_sync_crypto_returns_false_when_no_file() {
        let tmp = TempDir::new().unwrap();
        assert!(!has_sync_crypto(tmp.path()));
    }

    #[test]
    fn save_load_clear_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();

        // 初始无元数据
        assert!(!has_sync_crypto(dir));
        assert!(load_sync_crypto_meta(dir).unwrap().is_none());

        // 构造并保存
        let meta = SyncCryptoMeta {
            salt: "dGVzdA==".to_string(),
            encrypted_data_key: "ZW5jcnlwdGVk".to_string(),
            data_key_nonce: "bm9uY2U=".to_string(),
            iterations: 200_000,
        };
        save_sync_crypto_meta(dir, &meta).unwrap();
        assert!(has_sync_crypto(dir));

        // 加载并验证
        let loaded = load_sync_crypto_meta(dir).unwrap().unwrap();
        assert_eq!(loaded.salt, meta.salt);
        assert_eq!(loaded.encrypted_data_key, meta.encrypted_data_key);
        assert_eq!(loaded.data_key_nonce, meta.data_key_nonce);
        assert_eq!(loaded.iterations, meta.iterations);

        // 清除
        clear_sync_crypto_meta(dir).unwrap();
        assert!(!has_sync_crypto(dir));
        assert!(load_sync_crypto_meta(dir).unwrap().is_none());
    }

    #[test]
    fn clear_sync_crypto_meta_is_idempotent() {
        let tmp = TempDir::new().unwrap();
        clear_sync_crypto_meta(tmp.path()).unwrap();
    }
}
