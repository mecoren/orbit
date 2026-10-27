//! asset — 移动端桥接层：任务附件（迁移路径批次：附件功能）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core::api::asset_api）：
//! - [asset_cmd](../../../../../apps/desktop/src-tauri/src/commands/asset_cmd.rs)
//!   的 task_attachment_add / task_attachments_list / task_attachment_read /
//!   task_attachment_remove / attachments_gc / attachments_unused_list /
//!   attachments_unused_delete。
//!
//! 文件选择器走路径入参（`task_attachment_add_path`，core 流式读盘，峰值与文件
//! 大小无关）；拍照等内存里已有字节的来源仍走字节版。附件目录 = base_dir/attachments，
//! 与 sync.rs 的 attachments_dir 同源。

use orbit_core::api::asset_api;

use super::dto::{TaskAttachmentView, UnusedAttachmentView};
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

/// 从本地文件路径流式上传并挂载（文件选择器主路径）
///
/// 与 [`task_attachment_add`] 的唯一区别是**不把整文件读成 `List<int>` 过桥**：
/// core 按 256KiB 块边读边算 SHA-256，Dart/Rust 两侧峰值都与文件大小无关。
/// 拍照等内存里已有字节的来源仍走字节版。
pub async fn task_attachment_add_path(
    task_id: i64,
    file_name: String,
    mime_type: String,
    source_path: String,
) -> Result<TaskAttachmentView, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::add_task_attachment_from_path(
        &pool,
        &dir,
        task_id,
        &file_name,
        &mime_type,
        std::path::Path::new(&source_path),
    )
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

/// 列出未使用附件（无任何存活任务引用的账本行；诊断页清理入口，只读）
pub async fn attachments_unused_list() -> Result<Vec<UnusedAttachmentView>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    asset_api::list_unused_attachments(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(UnusedAttachmentView::from).collect())
}

/// 按 hash 批量删除未使用附件（本地文件 + 账本行；云端对象保留），返回清理数
pub async fn attachments_unused_delete(hashes: Vec<String>) -> Result<usize, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::delete_unused_attachments(&pool, &dir, &hashes)
        .await
        .map_err(|e| e.to_string())
}

/// 流式导出附件到指定路径（另存/分享），返回写入字节数
///
/// 与 [`task_attachment_read`] 的区别：不把整份内容带过桥，峰值与附件大小无关；
/// 目标路径由 Dart 侧用 file_picker 的目录选择拼出（同名覆盖，失败不留半截文件）。
pub async fn export_task_attachment(hash: String, target_path: String) -> Result<i64, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    asset_api::export_task_attachment(&pool, &dir, &hash, std::path::Path::new(&target_path))
        .await
        .map_err(|e| e.to_string())
}
