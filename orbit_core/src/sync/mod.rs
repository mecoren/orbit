//! sync — 云端备份与同步适配器
//!
//! 本模块为云端备份（full_sync_backup_api）与云端增量同步
//! （cloud_sync，经 sync_adapters）提供 S3/WebDAV 适配器构造与配置校验能力。
//!
//! 模块结构：
//! - engine: 适配器构造 + 配置校验（SyncConfig/create_adapter/validate_config）
//! - error: SyncError（供 sync_adapters / sync_crypto / full_sync_backup 复用）

pub mod engine;
pub mod error;

pub use error::SyncError;
