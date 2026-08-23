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

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::config_enc::cek::CekProvider;
use crate::config_enc::error::ConfigEncResult;
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
            return Err(crate::config_enc::error::ConfigEncError::Corrupted(format!(
                "文件长度不足: {} < {}",
                bytes.len(),
                MIN_FILE_LEN
            )));
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
