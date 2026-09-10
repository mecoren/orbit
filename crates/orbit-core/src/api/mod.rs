//! api — 业务编排层（纯 Rust 公共 API）
//!
//! 组合 repository + sync + crypto，暴露给薄壳（src-tauri commands）调用。
//! 函数签名约定：首个参数为 `pool: &SqlitePool`（由 AppState 注入）。

pub mod asset_api;
pub mod business_api;
pub mod cloud_sync_api;
pub mod csv_import_api;
pub mod db_maintenance_api;
pub mod full_sync_backup_api;
pub mod holiday_api;
pub mod ics_export_api;
pub mod import_api;
pub mod notification_log_api;
pub mod plaintext_export_api;
pub mod saved_filter_api;
pub mod stats_api;
pub mod template_api;
pub mod todo_api;
pub mod trash_api;
pub mod widget_api;
