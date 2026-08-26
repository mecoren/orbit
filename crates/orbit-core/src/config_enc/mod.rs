//! config_enc — 配置文件加密存储
//!
//! 提供 CEK（Config Encryption Key）管理和加密配置文件读写。
//! CEK 由 OS 安全存储保护（桌面端 keyring，移动端 flutter_secure_storage），
//! 用于加密本地配置文件（如 sync_config、full_sync_backup_prefs）。
//!
//! 文件格式：`[12B nonce][N B ciphertext][16B GCM tag]` 二进制。

pub mod cek;
pub mod error;
pub mod registry;
pub mod storage;

pub use cek::{CEK_LEN, CekProvider, InMemoryCekProvider};
pub use error::{ConfigEncError, ConfigEncResult};
pub use registry::{get_global_storage, set_global_storage, try_with_global_storage};
pub use storage::EncryptedConfigStorage;
