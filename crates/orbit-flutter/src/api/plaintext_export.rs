//! plaintext_export — 明文数据导出（07 报告 #15）
//!
//! 对齐桌面 `plaintext_export_cmd`（plaintext_export_json / plaintext_export_csv）：
//! 返回文件内容字符串 + 各表行数统计，落盘由 Dart 侧系统保存器完成
//!（移动端用 file picker + 应用文档目录写入）。隐私口径见 PRIVACY.md §七。
//!
//! DTO 用本模块自持结构（orbit_core 的 PlaintextExportResult 含 BTreeMap，
//! FRB 2.12 需显式镜像；counts 用 Vec<(String, usize)> 规避 map 支持差异）。

use serde::Serialize;

use super::state::with_state;
use orbit_core::api::plaintext_export_api;

/// 明文导出结果（FRB 镜像）
#[derive(Debug, Clone, Serialize)]
pub struct PlaintextExportView {
    /// 文件内容（JSON 文本或 CSV 文本，UTF-8；CSV 带 BOM）
    pub content: String,
    /// 各表行数（表名, 行数）有序对
    pub table_counts: Vec<TableCount>,
    /// 建议文件名（含时间戳）
    pub suggested_filename: String,
}

/// 表行数统计项
#[derive(Debug, Clone, Serialize)]
pub struct TableCount {
    pub table: String,
    pub count: usize,
}

fn to_view(result: plaintext_export_api::PlaintextExportResult, ext: &str) -> PlaintextExportView {
    let ts = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    PlaintextExportView {
        content: result.content,
        table_counts: result
            .table_counts
            .into_iter()
            .map(|(table, count)| TableCount { table, count })
            .collect(),
        suggested_filename: format!("orbit-export-{ts}.{ext}"),
    }
}

/// 导出全部待办数据为结构化 JSON（默认排除墓碑行）
pub async fn plaintext_export_json(
    exclude_deleted: Option<bool>,
) -> Result<PlaintextExportView, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let result =
        plaintext_export_api::export_plaintext_json(&pool, exclude_deleted.unwrap_or(true))
            .await
            .map_err(|e| format!("[export] {e}"))?;
    Ok(to_view(result, "json"))
}

/// 导出任务主视图 CSV（UTF-8 with BOM；默认排除墓碑行）
pub async fn plaintext_export_csv(
    exclude_deleted: Option<bool>,
) -> Result<PlaintextExportView, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let result = plaintext_export_api::export_plaintext_csv(&pool, exclude_deleted.unwrap_or(true))
        .await
        .map_err(|e| format!("[export] {e}"))?;
    Ok(to_view(result, "csv"))
}
