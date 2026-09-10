//! sync_crypto — 同步密码派生与 Data Key 管理
//!
//! 作为同步加密的单一实现源（Single Source of Truth），管理跨设备端到端加密的密钥层次。
//! 两代方案共存（meta.key_derivation 字段区分）：
//!
//! **v1（存量兼容）**：随机 Data Key + 密码包装，跨设备靠云端 crypto/config 分发：
//! ```text
//! sync_password ──PBKDF2(HMAC-SHA256, 600k iter, 16B salt)──→ master_key
//! random_data_key(32B) ──AES-256-GCM(master_key)──→ encrypted_data_key（云端分发）
//! ```
//!
//! **v2（现行默认）**：Data Key 由密码确定性派生（对齐 SiYuan 模型），
//! 同密码跨设备必然同 Key，KeyMismatch 的「密码对但 Key 不匹配」分叉态结构性消失：
//! ```text
//! salt      = PBKDF2(密码, "orbit-sync-v2-salt", 1)
//! data_key  = PBKDF2(密码, salt|"orbit-sync-v2-key", 600k)
//! encrypted_data_key（保留包装字段作为 unlock 验证子，防 meta 篡改）
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
pub use service::{KEY_DERIVATION_V2, SyncCryptoService, derive_data_key_v2};
