//! Tauri command 模块：每个业务域一个文件，薄壳包装 orbit_core::api。

pub mod backup_scheduler;
pub mod business_cmd;
pub mod cloud_sync_cmd;
pub mod crypto_cmd;
pub mod data_dir;
pub mod db_cmd;
pub mod full_sync_cmd;
pub mod holiday_cmd;
pub mod holiday_scheduler;
pub mod mica_cmd;
pub mod notification_scheduler;
pub mod plaintext_export_cmd;
#[cfg(target_os = "windows")]
pub mod scheduled_toast;
pub mod sync_cmd;
pub mod sync_crypto_cmd;
pub mod sync_runtime;
pub mod sync_scheduler;
pub mod todo_cmd;
pub mod trash_cmd;
pub mod trash_scheduler;
pub mod tray;
