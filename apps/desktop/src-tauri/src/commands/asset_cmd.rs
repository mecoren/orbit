//! asset_cmd — 任务附件命令组（07 排查报告后续批次：附件功能）
//!
//! 薄壳包装 orbit_core::api::asset_api：
//! - `task_attachment_add`：前端经 tauri-plugin-fs 读文件后传 {文件名, mime, bytes}；
//! - `task_attachments_list` / `task_attachment_read` / `task_attachment_remove`；
//! - `attachments_gc`：本地孤儿清理（启动时/手动触发）。
//!
//! 附件目录 = `{app_data_dir}/attachments`（与 sync_runtime::attachments_dir 同源）。

use orbit_core::api::asset_api::{self, TaskAttachmentView};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
}

fn attachments_dir_of(app: &tauri::AppHandle) -> Result<String, String> {
    let dir = crate::commands::data_dir::resolve_app_data_dir(app)?;
    Ok(crate::commands::sync_runtime::attachments_dir(&dir))
}

/// 上传并挂载附件到任务（bytes 由前端 fs 插件读得）
#[tauri::command]
pub async fn task_attachment_add(
    app: tauri::AppHandle,
    task_id: i64,
    file_name: String,
    mime_type: String,
    data: Vec<u8>,
) -> Result<TaskAttachmentView, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::add_task_attachment(&pool, &dir, task_id, &file_name, &mime_type, &data)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}

/// 列出任务全部附件（含本地缓存状态）
#[tauri::command]
pub async fn task_attachments_list(
    app: tauri::AppHandle,
    task_id: i64,
) -> Result<Vec<TaskAttachmentView>, String> {
    let pool = pool_of(&app)?;
    asset_api::get_task_attachments(&pool, task_id)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}

/// 读取附件本地文件字节（详情页预览/导出用）
#[tauri::command]
pub async fn task_attachment_read(
    app: tauri::AppHandle,
    hash: String,
) -> Result<Vec<u8>, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::read_task_attachment(&pool, &dir, &hash)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}

/// 卸下任务附件（软删关联；孤儿二进制的本地清理由 GC 负责）
#[tauri::command]
pub async fn task_attachment_remove(
    app: tauri::AppHandle,
    link_id: i64,
) -> Result<(), String> {
    let pool = pool_of(&app)?;
    asset_api::remove_task_attachment(&pool, link_id)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}

/// 本地附件 GC（清无引用文件与账本行），返回清理数
#[tauri::command]
pub async fn attachments_gc(app: tauri::AppHandle) -> Result<usize, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::gc_local_attachments(&pool, &dir)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}
