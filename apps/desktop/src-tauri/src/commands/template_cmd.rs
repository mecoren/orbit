//! template_cmd — 任务模板命令组（竞品矩阵高价值缺口）
//!
//! 薄壳包装 orbit_core::api::template_api：
//! - `templates_list` / `template_create` / `template_update` / `template_delete`
//! 套用（按 payload 预填任务表单）在前端完成——预填是纯 UI 行为，
//! 不值得过 IPC 走服务端。

use orbit_core::api::template_api;
use orbit_core::models::business::{
    TodoTemplate, TodoTemplateCreateInput, TodoTemplateUpdateInput,
};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
}

/// 列出全部任务模板
#[tauri::command]
pub async fn templates_list(app: tauri::AppHandle) -> Result<Vec<TodoTemplate>, String> {
    let pool = pool_of(&app)?;
    template_api::list_templates(&pool)
        .await
        .map_err(|e| format!("[template] {e}"))
}

/// 创建任务模板
#[tauri::command]
pub async fn template_create(
    app: tauri::AppHandle,
    input: TodoTemplateCreateInput,
) -> Result<TodoTemplate, String> {
    let pool = pool_of(&app)?;
    template_api::create_template(&pool, &input)
        .await
        .map_err(|e| format!("[template] {e}"))
}

/// 更新任务模板
#[tauri::command]
pub async fn template_update(
    app: tauri::AppHandle,
    id: i64,
    input: TodoTemplateUpdateInput,
) -> Result<TodoTemplate, String> {
    let pool = pool_of(&app)?;
    template_api::update_template(&pool, id, &input)
        .await
        .map_err(|e| format!("[template] {e}"))
}

/// 删除任务模板（软删）
#[tauri::command]
pub async fn template_delete(app: tauri::AppHandle, id: i64) -> Result<(), String> {
    let pool = pool_of(&app)?;
    template_api::delete_template(&pool, id)
        .await
        .map_err(|e| format!("[template] {e}"))
}
