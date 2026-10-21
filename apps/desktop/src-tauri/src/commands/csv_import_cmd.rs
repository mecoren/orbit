//! csv_import_cmd — CSV 导入命令组（导入迁移路径）
//!
//! 包装 orbit_core::api::csv_import_api；两段式：
//! - `csv_import_preview`：解析 + 映射（不写库），返回预览行与统计
//! - `csv_import_execute`：按同源逻辑写库（项目自动创建、逐行独立成败）
//!
//! 文件内容读取由前端经 tauri-plugin-fs（打开对话框选文件后 readTextFile）
//! 完成，本命令只收文本内容；三档预设 orbit / todoist / ticktick。

use orbit_core::api::csv_import_api::{
    self, CsvImportPreview, CsvImportStats, ImportJobStatus, ImportLimits,
};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
}

/// 导入限额（字节 / 行数）：前端选文件后先读 `stat` 比对，超限即拦，
/// 不把整份内容读进内存再拒绝。单一来源在 orbit-core。
#[tauri::command]
pub fn csv_import_limits() -> ImportLimits {
    csv_import_api::import_limits()
}

/// 预览导入（不写库）：前 N 条映射行 + 全量统计
#[tauri::command]
pub async fn csv_import_preview(
    app: tauri::AppHandle,
    content: String,
    preset: String,
    preview_limit: Option<usize>,
) -> Result<CsvImportPreview, String> {
    let pool = pool_of(&app)?;
    // pool 在预览路径未使用（纯解析），保持签名一致以便未来扩展
    let _ = &pool;
    csv_import_api::preview_csv_import(&content, &preset, preview_limit.unwrap_or(20))
        .await
        .map_err(|e| format!("[import] {e}"))
}

/// 执行导入（写库）：逐行写入，项目标题自动创建；返回统计与逐行说明
#[tauri::command]
pub async fn csv_import_execute(
    app: tauri::AppHandle,
    content: String,
    preset: String,
) -> Result<CsvImportStats, String> {
    let pool = pool_of(&app)?;
    csv_import_api::execute_csv_import(&pool, &content, &preset)
        .await
        .map_err(|e| format!("[import] {e}"))
}

// ── 可取消导入（进度 + 取消；docs/13 §6.2 M2 第 3/5 点）──
//
// 一次性 `csv_import_execute` 保留给小文件（无进度需求）；大批量走 job 三件套：
// start 返回 job_id，前端轮询 status 显示进度，cancel 在行边界中止。

/// 启动可取消导入：同步预检限额后返回 job_id（后台执行）
#[tauri::command]
pub fn csv_import_job_start(
    app: tauri::AppHandle,
    content: String,
    preset: String,
) -> Result<String, String> {
    let pool = pool_of(&app)?;
    csv_import_api::start_csv_import_job(pool, content, preset)
        .map_err(|e| format!("[import] {e}"))
}

/// 轮询导入任务状态（processed / total / finished / cancelled / stats）
#[tauri::command]
pub fn csv_import_job_status(job_id: String) -> Result<ImportJobStatus, String> {
    csv_import_api::csv_import_job_status(&job_id).map_err(|e| format!("[import] {e}"))
}

/// 请求取消导入（行边界生效；已写入的行保留）
#[tauri::command]
pub fn csv_import_job_cancel(job_id: String) -> Result<(), String> {
    csv_import_api::csv_import_job_cancel(&job_id).map_err(|e| format!("[import] {e}"))
}

/// 释放任务条目（拿到终态后调用，避免任务表滞留）
#[tauri::command]
pub fn csv_import_job_drop(job_id: String) {
    csv_import_api::csv_import_job_drop(&job_id);
}
