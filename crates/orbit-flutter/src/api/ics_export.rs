//! ics_export — 移动端桥接层：ICS 日历导出（#4）
//!
//! 与桌面壳命令一一对应（薄包装，业务在 orbit_core::api::ics_export_api）。
//! 内容返回给 Dart 落盘（移动端固定写应用文档目录 exports/）。
//! counts 用 Vec<IcsTableCount> 规避 BTreeMap 过桥差异（plaintext_export 同口径）。

use serde::Serialize;

use super::state::with_state;
use orbit_core::api::ics_export_api;

/// ICS 导出结果（FRB 镜像）
#[derive(Debug, Clone, Serialize)]
pub struct IcsExportView {
    pub content: String,
    /// 各表行数（表名, 行数）有序对
    pub table_counts: Vec<IcsTableCount>,
    /// 建议文件名（含时间戳）
    pub suggested_filename: String,
}

/// 表行数统计项（独立类型名：FRB codegen 与 plaintext_export 的同名
/// TableCount 会混串生成物，独有名规避）
#[derive(Debug, Clone, Serialize)]
pub struct IcsTableCount {
    pub table: String,
    pub count: usize,
}

/// 导出全部任务为 ICS（VTODO 日历；含完成态/优先级/截止映射）
pub async fn ics_export() -> Result<IcsExportView, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let r = ics_export_api::export_ics(&pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(IcsExportView {
        content: r.content,
        table_counts: r
            .table_counts
            .into_iter()
            .map(|(table, count)| IcsTableCount { table, count })
            .collect(),
        suggested_filename: r.suggested_filename,
    })
}
