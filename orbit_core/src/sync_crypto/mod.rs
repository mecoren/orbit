//! sync_crypto — 同步密码派生与 Data Key 管理
//!
//! 作为同步加密的单一实现源（Single Source of Truth），管理跨设备端到端加密的密钥层次：
//! ```text
//! sync_password ──PBKDF2(HMAC-SHA256, 200000 iter, 16B salt)──→ master_key
//!                                                                    │
//! random_data_key(32B) ──AES-256-GCM(master_key, 12B nonce)──→ encrypted_data_key
//! ```
//!
//! 持久化：`sync_crypto_meta.json`（位于 app_data_dir），参考 `master_auth.json` 模式。
//! Data Key 内存驻留（`Arc<RwLock>`），进程退出即清除。
//!
//! 与 `master_auth`（主密码/DB Key 认证）完全独立，两套密码体系互不干扰。

pub mod bundle_io;
pub mod error;
pub mod meta_store;
pub mod service;

pub use error::SyncCryptoError;
pub use meta_store::{
    SyncCryptoMeta, clear_sync_crypto_meta, has_sync_crypto, load_sync_crypto_meta,
    save_sync_crypto_meta, sync_crypto_meta_path,
};
pub use service::SyncCryptoService;
