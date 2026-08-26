//! EncryptedConfigStorage — 加密配置文件存储
//!
//! 文件格式（二进制）：
//! ```text
//! 偏移  长度  内容
//! 0     12    nonce（每次写入随机生成）
//! 12    N     ciphertext（明文长度 = N）
//! 12+N  16    GCM authentication tag
//! ```
//!
//! 文件命名：基础名 + `.enc` 扩展名（如 `sync_config.enc`）。

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::config_enc::cek::CekProvider;
use crate::config_enc::error::{ConfigEncError, ConfigEncResult};
use crate::crypto::aes_gcm::{aes_gcm_decrypt, aes_gcm_encrypt};
use crate::crypto::random::random_bytes;

/// nonce 长度（AES-GCM 标准 12 字节）
const NONCE_LEN: usize = 12;
/// GCM tag 长度
const TAG_LEN: usize = 16;
/// 文件最小长度（nonce + tag，ciphertext 可以为空）
const MIN_FILE_LEN: usize = NONCE_LEN + TAG_LEN;
/// 加密后文件扩展名
const ENC_EXTENSION: &str = "enc";

/// 加密配置存储
///
/// 通过 `CekProvider` 获取 CEK，对配置文件进行 AES-256-GCM 加解密。
/// 所有文件位于 `app_data_dir` 下，文件名为 `{name}.enc`。
///
/// `Clone` 语义：内部 CEK 为 `Arc` 引用计数，克隆共享同一 CEK 实例。
#[derive(Clone)]
pub struct EncryptedConfigStorage {
    cek: std::sync::Arc<dyn CekProvider>,
    app_data_dir: PathBuf,
}

impl EncryptedConfigStorage {
    /// 构造存储实例
    pub fn new(cek: std::sync::Arc<dyn CekProvider>, app_data_dir: PathBuf) -> Self {
        Self { cek, app_data_dir }
    }

    /// 返回 `.enc` 文件路径
    pub fn enc_path(&self, name: &str) -> PathBuf {
        self.app_data_dir
            .join(format!("{}.{}", name, ENC_EXTENSION))
    }

    /// 判断 `.enc` 文件是否存在
    pub fn is_encrypted(&self, name: &str) -> bool {
        self.enc_path(name).exists()
    }

    /// 读取并解密配置文件
    ///
    /// 文件不存在返回 `Ok(None)`。
    /// 解密失败返回 `ConfigEncError`（CEK 不匹配或文件损坏）。
    pub fn load<T: DeserializeOwned>(&self, name: &str) -> ConfigEncResult<Option<T>> {
        let path = self.enc_path(name);
        if !path.exists() {
            return Ok(None);
        }
        let bytes = std::fs::read(&path)?;
        if bytes.len() < MIN_FILE_LEN {
            return Err(crate::config_enc::error::ConfigEncError::Corrupted(
                format!("文件长度不足: {} < {}", bytes.len(), MIN_FILE_LEN),
            ));
        }
        let nonce = &bytes[..NONCE_LEN];
        let ciphertext_with_tag = &bytes[NONCE_LEN..];
        let cek = self.cek.get_or_create()?;
        let plaintext = aes_gcm_decrypt(&cek, ciphertext_with_tag, nonce)?;
        let value: T = serde_json::from_slice(&plaintext)?;
        Ok(Some(value))
    }

    /// 加密并写入配置文件
    ///
    /// 写入流程：序列化 → 加密 → 原子写临时文件 → 重命名替换（Fix-04：
    /// 原子写协议统一收敛到 `fs_util::write_atomic`）。
    pub fn save<T: Serialize>(&self, name: &str, value: &T) -> ConfigEncResult<()> {
        let plaintext = serde_json::to_vec(value)?;
        let cek = self.cek.get_or_create()?;
        let nonce = random_bytes(NONCE_LEN);
        let ciphertext_with_tag = aes_gcm_encrypt(&cek, &plaintext, &nonce)?;

        // 组装最终文件内容：nonce + ciphertext + tag
        let mut file_bytes = Vec::with_capacity(NONCE_LEN + ciphertext_with_tag.len());
        file_bytes.extend_from_slice(&nonce);
        file_bytes.extend_from_slice(&ciphertext_with_tag);

        crate::fs_util::write_atomic(&self.enc_path(name), &file_bytes)?;
        Ok(())
    }

    /// 加密保存；**仅** CEK 不可用时降级为明文 JSON（ADR 0001 §七-① 裁决方案 a）
    ///
    /// 与 `full_sync_backup::backup_prefs` 的「加密优先、明文降级」模式对称，
    /// 但触发条件收窄：只有 `CekUnavailable`（移动端 KeyringCekProvider 的恒定契约）
    /// 才降级；其余错误（磁盘 IO、序列化等）原样向上传播——桌面端钥匙串/IO 故障
    /// 不得静默把高敏感凭据落成明文再报成功。
    /// - 桌面端 CEK 可用，`save()` 恒成功，恒走 `.enc` 加密分支（行为零变化）；
    /// - 移动端 `KeyringCekProvider` 恒返 `CekUnavailable`，降级写同目录 `{name}.json`
    ///   （路径与读取侧 `read_device_name_from_config` 的明文降级一致）。
    ///
    /// 隐私让步：明文落盘按 ADR 0001 §四清单 #2 纳入本地攻击面披露。
    pub fn save_with_plaintext_fallback<T: Serialize>(
        &self,
        name: &str,
        value: &T,
    ) -> ConfigEncResult<()> {
        if let Err(e @ ConfigEncError::CekUnavailable(_)) = self.save(name, value) {
            // 安全降级事件须可观测（tauri-plugin-log 未接线前 eprintln 可见）；
            // 只记错误摘要，不落配置内容（02 §九 日志脱敏红线）
            eprintln!("[config_enc] {name} CEK 不可用，降级明文写入: {e}");
            let path = self.app_data_dir.join(format!("{name}.json"));
            let content = serde_json::to_vec_pretty(value)?;
            crate::fs_util::write_atomic(&path, &content)?;
            return Ok(());
        }
        self.save(name, value)
    }

    /// 删除 `.enc` 配置文件
    pub fn remove(&self, name: &str) -> ConfigEncResult<()> {
        let enc = self.enc_path(name);
        if enc.exists() {
            std::fs::remove_file(&enc)?;
        }
        Ok(())
    }

    /// 返回 app_data_dir 引用
    pub fn app_data_dir(&self) -> &Path {
        &self.app_data_dir
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_enc::cek::{CEK_LEN, CekProvider};
    use serde_json::json;
    use tempfile::TempDir;

    /// 恒失败的 CEK 提供者（模拟移动端 KeyringCekProvider 恒 CekUnavailable）
    struct UnavailableCekProvider;

    impl CekProvider for UnavailableCekProvider {
        fn get_or_create(&self) -> ConfigEncResult<[u8; CEK_LEN]> {
            Err(crate::config_enc::error::ConfigEncError::CekUnavailable(
                "test: 恒不可用".to_string(),
            ))
        }
        fn is_available(&self) -> bool {
            false
        }
    }

    #[test]
    fn fallback_writes_plain_json_when_cek_unavailable() {
        let dir = TempDir::new().unwrap();
        let storage = EncryptedConfigStorage::new(
            std::sync::Arc::new(UnavailableCekProvider),
            dir.path().to_path_buf(),
        );
        let cfg = json!({"engine": "webdav", "auto_sync_enabled": true});
        storage
            .save_with_plaintext_fallback("sync_config", &cfg)
            .unwrap();

        // .enc 不落盘，明文 JSON 落同目录同名（与读取侧降级路径一致）
        assert!(!storage.enc_path("sync_config").exists());
        let raw = std::fs::read_to_string(dir.path().join("sync_config.json")).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&raw).unwrap(),
            cfg
        );
    }

    #[test]
    fn fallback_prefers_encrypted_when_cek_ok() {
        let dir = TempDir::new().unwrap();
        let storage = EncryptedConfigStorage::new(
            std::sync::Arc::new(crate::config_enc::cek::InMemoryCekProvider::new()),
            dir.path().to_path_buf(),
        );
        let cfg = json!({"engine": "s3"});
        storage
            .save_with_plaintext_fallback("sync_config", &cfg)
            .unwrap();

        // CEK 可用走加密分支，不产生明文文件（桌面行为零变化）
        assert!(storage.enc_path("sync_config").exists());
        assert!(!dir.path().join("sync_config.json").exists());
        assert_eq!(
            storage.load::<serde_json::Value>("sync_config").unwrap(),
            Some(cfg)
        );
    }

    /// 非 CekUnavailable 错误必须向上传播，不得静默降级明文（评审 Issue：桌面
    /// 钥匙串/IO 故障不得把高敏感凭据落成明文再报成功）
    #[test]
    fn fallback_propagates_non_cek_errors() {
        struct BrokenIoProvider;
        impl CekProvider for BrokenIoProvider {
            fn get_or_create(&self) -> ConfigEncResult<[u8; CEK_LEN]> {
                Ok([7u8; CEK_LEN])
            }
            fn is_available(&self) -> bool {
                true
            }
        }

        let dir = TempDir::new().unwrap();
        // app_data_dir 指向一个文件路径，使 .enc 写入必然 IO 失败
        let blocker = dir.path().join("blocker");
        std::fs::write(&blocker, b"x").unwrap();
        let storage =
            EncryptedConfigStorage::new(std::sync::Arc::new(BrokenIoProvider), blocker.clone());
        let cfg = json!({"engine": "webdav"});

        let err = storage
            .save_with_plaintext_fallback("sync_config", &cfg)
            .unwrap_err();
        assert!(matches!(err, ConfigEncError::Io(_)));
        // 明文文件绝不允许出现
        assert!(!blocker.join("sync_config.json").exists());
    }
}
