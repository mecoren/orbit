//! asset — 移动端桥接层：任务附件（迁移路径批次：附件功能）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core::api::asset_api）：
//! - [asset_cmd](../../../../../apps/desktop/src-tauri/src/commands/asset_cmd.rs)
//!   的 task_attachment_add / task_attachments_list / task_attachment_read /
//!   task_attachment_remove / attachments_gc。
//! 文件读取由 Dart 侧 file_picker 完成后传 bytes（附件目录 = base_dir/attachments，
//! 与 sync.rs 的 attachments_dir 同源）。

use orbit_core::api::asset_api;

use super::dto::TaskAttachmentView;
use super::state::with_state;

/// 上传并挂载附件到任务（bytes 由 Dart file_picker 读得）
pub async fn task_attachment_add(
    task_id: i64,
    file_name: String,
    mime_type: String,
    data: Vec<u8>,
) -> Result<TaskAttachmentView, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::add_task_attachment(&pool, &dir, task_id, &file_name, &mime_type, &data)
        .await
        .map_err(|e| e.to_string())
        .map(TaskAttachmentView::from)
}

/// 列出任务全部附件（含本地缓存状态）
pub async fn task_attachments_list(task_id: i64) -> Result<Vec<TaskAttachmentView>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    asset_api::get_task_attachments(&pool, task_id)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(TaskAttachmentView::from).collect())
}

/// 读取附件本地文件字节（详情页预览/保存用）
pub async fn task_attachment_read(hash: String) -> Result<Vec<u8>, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::read_task_attachment(&pool, &dir, &hash)
        .await
        .map_err(|e| e.to_string())
}

/// 卸下任务附件（软删关联；孤儿二进制的本地清理由 GC 负责）
pub async fn task_attachment_remove(link_id: i64) -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    asset_api::remove_task_attachment(&pool, link_id)
        .await
        .map_err(|e| e.to_string())
}

/// 本地附件 GC（清无引用文件与账本行），返回清理数
pub async fn attachments_gc() -> Result<usize, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::gc_local_attachments(&pool, &dir)
        .await
        .map_err(|e| e.to_string())
}
