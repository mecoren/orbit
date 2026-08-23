//! sync — 云端备份与同步适配器
//!
//! 本模块为云端备份提供 S3/WebDAV 适配器构造与配置校验能力。
//! 云端同步功能为占位状态，暂未实现。
//!
//! 模块结构：
//! - engine: 适配器构造 + 配置校验（SyncConfig/create_adapter/validate_config）
//! - error: SyncError（供 sync_adapters / sync_crypto / full_sync_backup 复用）

pub mod engine;
pub mod error;

pub use error::SyncError;
