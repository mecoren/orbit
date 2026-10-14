//! diagnostics — 移动端桥接层诊断域（docs/09 内存专项「应用内诊断分区」）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在
//! `orbit_core::api::diagnostics_api`）：
//! - [diagnostics_snapshot] → 桌面 `diagnostics_snapshot`。
//!
//! ## 口径
//! - **只读聚合**：不 emit db-change、不进 `sync_registry` 白名单（AGENTS
//!   「只读聚合不进同步白名单」），UI 靠主动 refetch 刷新；
//! - 附件目录 = `{base_dir}/attachments`，与 [super::asset] / [super::sync] 同源。
//!
//! ## DTO 镜像模式
//! [DiagnosticsSnapshot]/[TableRowCount] 为本地镜像（同 [super::dto] 规则），
//! 避免 core 类型过桥被 FRB 降级为 opaque。

use orbit_core::api::diagnostics_api;
use serde::Serialize;

use super::state::with_state;

/// 单表活行数
#[derive(Debug, Clone, Serialize)]
pub struct TableRowCount {
    pub table: String,
    pub rows: i64,
}

/// 应用内诊断快照（镜像 orbit_core::api::diagnostics_api::DiagnosticsSnapshot）
#[derive(Debug, Clone, Serialize)]
pub struct DiagnosticsSnapshot {
    /// 本地库体积（字节，SQLite `page_count × page_size`）
    pub db_size_bytes: i64,
    /// 各表活行数（顺序 = 同步白名单顺序）
    pub table_rows: Vec<TableRowCount>,
    /// 全部可同步表的墓碑行数合计
    pub tombstone_rows: i64,
    /// 附件本地缓存体积（字节）
    pub attachment_cache_bytes: i64,
    /// 附件本地缓存文件数
    pub attachment_cache_files: i64,
}

impl From<diagnostics_api::DiagnosticsSnapshot> for DiagnosticsSnapshot {
    fn from(s: diagnostics_api::DiagnosticsSnapshot) -> Self {
        Self {
            db_size_bytes: s.db_size_bytes,
            table_rows: s
                .table_rows
                .into_iter()
                .map(|r| TableRowCount {
                    table: r.table,
                    rows: r.rows,
                })
                .collect(),
            tombstone_rows: s.tombstone_rows,
            attachment_cache_bytes: s.attachment_cache_bytes,
            attachment_cache_files: s.attachment_cache_files,
        }
    }
}

// ── FRB 导出 ──

/// 采集诊断快照（库体积 / 各表活行数 / 墓碑行数 / 附件缓存占用）
pub async fn diagnostics_snapshot() -> Result<DiagnosticsSnapshot, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    diagnostics_api::diagnostics_snapshot(&pool, &dir)
        .await
        .map_err(|e| format!("[diagnostics] {e}"))
        .map(DiagnosticsSnapshot::from)
}
