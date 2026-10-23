//! asset_cmd — 任务附件命令组（07 排查报告后续批次：附件功能）
//!
//! 薄壳包装 orbit_core::api::asset_api：
//! - `task_attachment_add`：前端经 tauri-plugin-fs 读文件后传 {文件名, mime, bytes}；
//! - `task_attachments_list` / `task_attachment_read` / `task_attachment_remove`；
//! - `attachments_gc`：本地孤儿清理（启动时/手动触发）；
//! - `attachments_unused_list` / `attachments_unused_delete`：诊断页「清除未使用
//!   附件」的清单与按 hash 清理（只删本地文件+账本行，云端对象保留）。
//!
//! 附件目录 = `{app_data_dir}/attachments`（与 sync_runtime::attachments_dir 同源）。

use orbit_core::api::asset_api::{self, TaskAttachmentView, UnusedAttachmentView};
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

/// 上传并挂载附件到任务（bytes 由前端 fs 插件读得，剪贴板/拖放路径用）
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

/// 从本地文件路径流式上传并挂载附件（文件选择器主路径，M3/T1.1）
///
/// 与 `task_attachment_add` 的区别只在数据来源：core 直接从磁盘按块读取并
/// 计算 hash，IPC 不再搬运整份文件字节（50MB 附件省去 JS→Rust 的整包拷贝）。
#[tauri::command]
pub async fn task_attachment_add_from_path(
    app: tauri::AppHandle,
    task_id: i64,
    file_name: String,
    mime_type: String,
    source_path: String,
) -> Result<TaskAttachmentView, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::add_task_attachment_from_path(
        &pool,
        &dir,
        task_id,
        &file_name,
        &mime_type,
        std::path::Path::new(&source_path),
    )
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

/// 流式导出附件到指定路径（大文件预览/系统程序打开，M3/T1.1）
///
/// 不把内容带进前端内存：按块复制到 `target_path`（壳层选的缓存路径），
/// 返回写入字节数。
#[tauri::command]
pub async fn task_attachment_export(
    app: tauri::AppHandle,
    hash: String,
    target_path: String,
) -> Result<i64, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::export_task_attachment(&pool, &dir, &hash, std::path::Path::new(&target_path))
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

/// 列出未使用附件（无任何存活任务引用的账本行；诊断页清理入口，只读）
#[tauri::command]
pub async fn attachments_unused_list(
    app: tauri::AppHandle,
) -> Result<Vec<UnusedAttachmentView>, String> {
    let pool = pool_of(&app)?;
    asset_api::list_unused_attachments(&pool)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}

/// 按 hash 批量删除未使用附件（本地文件 + 账本行；云端对象保留），返回清理数
#[tauri::command]
pub async fn attachments_unused_delete(
    app: tauri::AppHandle,
    hashes: Vec<String>,
) -> Result<usize, String> {
    let pool = pool_of(&app)?;
    let dir = attachments_dir_of(&app)?;
    asset_api::delete_unused_attachments(&pool, &dir, &hashes)
        .await
        .map_err(|e| format!("[attachment] {e}"))
}
