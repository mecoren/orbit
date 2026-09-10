//! ics_export_cmd — ICS 日历导出命令（#4 高价值缺口）
//!
//! 包装 orbit_core::api::ics_export_api：任务以 RFC 5545 VTODO 输出，
//! 供系统日历/其他日历软件导入或订阅。落盘由前端经系统保存对话框完成。

use serde::Serialize;
use tauri::Manager;

use orbit_core::api::ics_export_api::{self, IcsExportResult};

use crate::AppState;

/// 命令层导出结果（与 PlaintextExportView 同形；counts 供 UI 汇总提示）
#[derive(Debug, Clone, Serialize)]
pub struct IcsExportView {
    pub content: String,
    pub table_counts: std::collections::BTreeMap<String, usize>,
    /// 建议文件名（含时间戳，调用方可改）
    pub suggested_filename: String,
}

/// 导出全部任务为 ICS（VTODO 日历；含完成态/优先级/截止映射）
#[tauri::command]
pub async fn ics_export(app: tauri::AppHandle) -> Result<IcsExportView, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let result: IcsExportResult = ics_export_api::export_ics(&pool)
        .await
        .map_err(|e| format!("[export] {e}"))?;
    Ok(IcsExportView {
        content: result.content,
        table_counts: result.table_counts,
        suggested_filename: result.suggested_filename,
    })
}
