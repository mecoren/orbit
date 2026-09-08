//! saved_filter_cmd — 保存的筛选器命令组（#35）
//!
//! 薄壳包装 orbit_core::api::saved_filter_api：
//! - `saved_filters_list` / `saved_filter_create` / `saved_filter_update` / `saved_filter_delete`
//! 条件应用（过滤执行）在前端 `applySavedFilter` 共享函数完成——条件语义简单，
//! 不值得过 IPC 走服务端过滤。

use orbit_core::api::saved_filter_api;
use orbit_core::models::business::{
    TodoSavedFilter, TodoSavedFilterCreateInput, TodoSavedFilterUpdateInput,
};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
}

/// 列出全部保存的筛选器
#[tauri::command]
pub async fn saved_filters_list(
    app: tauri::AppHandle,
) -> Result<Vec<TodoSavedFilter>, String> {
    let pool = pool_of(&app)?;
    saved_filter_api::list_saved_filters(&pool)
        .await
        .map_err(|e| format!("[saved-filter] {e}"))
}

/// 创建保存的筛选器
#[tauri::command]
pub async fn saved_filter_create(
    app: tauri::AppHandle,
    input: TodoSavedFilterCreateInput,
) -> Result<TodoSavedFilter, String> {
    let pool = pool_of(&app)?;
    saved_filter_api::create_saved_filter(&pool, &input)
        .await
        .map_err(|e| format!("[saved-filter] {e}"))
}

/// 更新保存的筛选器
#[tauri::command]
pub async fn saved_filter_update(
    app: tauri::AppHandle,
    id: i64,
    input: TodoSavedFilterUpdateInput,
) -> Result<TodoSavedFilter, String> {
    let pool = pool_of(&app)?;
    saved_filter_api::update_saved_filter(&pool, id, &input)
        .await
        .map_err(|e| format!("[saved-filter] {e}"))
}

/// 删除保存的筛选器（软删）
#[tauri::command]
pub async fn saved_filter_delete(app: tauri::AppHandle, id: i64) -> Result<(), String> {
    let pool = pool_of(&app)?;
    saved_filter_api::delete_saved_filter(&pool, id)
        .await
        .map_err(|e| format!("[saved-filter] {e}"))
}
