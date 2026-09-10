//! notification_log_cmd — 通知历史命令组（#5）
//!
//! 薄壳包装 orbit_core::api::notification_log_api（查询/清空/TTL 清理）。
//! 写入（log_notification）不经命令面——桌面 notification_scheduler.rs
//! 在呈现处直接调 core API 落库。

use orbit_core::api::notification_log_api::{self, NotificationLogRow};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
}

/// 查询通知历史（倒序；kind 可选过滤；limit 默认 50 上限 200）
#[tauri::command]
pub async fn notification_log_list(
    app: tauri::AppHandle,
    kind: Option<String>,
    limit: Option<i64>,
) -> Result<Vec<NotificationLogRow>, String> {
    let pool = pool_of(&app)?;
    notification_log_api::list_notification_log(&pool, kind, limit)
        .await
        .map_err(|e| format!("[notification-log] {e}"))
}

/// 清空通知历史
#[tauri::command]
pub async fn notification_log_clear(app: tauri::AppHandle) -> Result<u64, String> {
    let pool = pool_of(&app)?;
    notification_log_api::clear_notification_log(&pool)
        .await
        .map_err(|e| format!("[notification-log] {e}"))
}
