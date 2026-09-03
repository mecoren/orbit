//! plaintext_export_cmd — 明文数据导出命令组（07 报告 #15）
//!
//! 包装 orbit_core::api::plaintext_export_api；返回文件内容字符串，
//! 落盘由前端经系统保存对话框（tauri-plugin-dialog）+ fs 插件完成。
//! 明文导出的隐私口径见 PRIVACY.md §七（用户主动触发、未加密明示）。

use serde::Serialize;
use tauri::Manager;

use orbit_core::api::plaintext_export_api::{self, PlaintextExportResult};

use crate::AppState;

/// 命令层导出结果（剥离 chrono 等非必要字段；counts 供 UI 汇总提示）
#[derive(Debug, Clone, Serialize)]
pub struct PlaintextExportView {
    pub content: String,
    pub table_counts: std::collections::BTreeMap<String, usize>,
    /// 建议文件名（含时间戳，调用方可改）
    pub suggested_filename: String,
}

fn to_view(result: PlaintextExportResult, ext: &str) -> PlaintextExportView {
    let ts = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    PlaintextExportView {
        content: result.content,
        table_counts: result.table_counts,
        suggested_filename: format!("orbit-export-{ts}.{ext}"),
    }
}

/// 导出全部待办数据为结构化 JSON（默认排除墓碑行）
#[tauri::command]
pub async fn plaintext_export_json(
    app: tauri::AppHandle,
    exclude_deleted: Option<bool>,
) -> Result<PlaintextExportView, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let result =
        plaintext_export_api::export_plaintext_json(&pool, exclude_deleted.unwrap_or(true))
            .await
            .map_err(|e| format!("[export] {e}"))?;
    Ok(to_view(result, "json"))
}

/// 导出任务主视图 CSV（UTF-8 with BOM；默认排除墓碑行）
#[tauri::command]
pub async fn plaintext_export_csv(
    app: tauri::AppHandle,
    exclude_deleted: Option<bool>,
) -> Result<PlaintextExportView, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let result = plaintext_export_api::export_plaintext_csv(&pool, exclude_deleted.unwrap_or(true))
        .await
        .map_err(|e| format!("[export] {e}"))?;
    Ok(to_view(result, "csv"))
}
