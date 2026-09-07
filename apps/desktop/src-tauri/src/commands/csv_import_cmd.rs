//! csv_import_cmd — CSV 导入命令组（导入迁移路径）
//!
//! 包装 orbit_core::api::csv_import_api；两段式：
//! - `csv_import_preview`：解析 + 映射（不写库），返回预览行与统计
//! - `csv_import_execute`：按同源逻辑写库（项目自动创建、逐行独立成败）
//!
//! 文件内容读取由前端经 tauri-plugin-fs（打开对话框选文件后 readTextFile）
//! 完成，本命令只收文本内容；三档预设 orbit / todoist / ticktick。

use orbit_core::api::csv_import_api::{self, CsvImportPreview, CsvImportStats};
use tauri::Manager;

use crate::AppState;

fn pool_of(app: &tauri::AppHandle) -> Result<sqlx::SqlitePool, String> {
    app.try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())
        .map(|s| s.pool.clone())
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
