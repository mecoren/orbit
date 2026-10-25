//! maintenance — 移动端桥接层：数据库维护（性能批次）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在
//! orbit_core::api::db_maintenance_api）：
//! - [db_maintenance_cmd](../../../../../apps/desktop/src-tauri/src/commands/db_maintenance_cmd.rs)
//!   的 db_maintenance（设置页「立即维护」，含 VACUUM）；
//! - 同文件的轻维护口径（启动路径，不含 VACUUM）在移动端由
//!   [db_maintenance_routine] 承载。
//!
//! 只读维护路径：不 emit db-change、不进同步白名单（与 core 口径一致）。

use orbit_core::api::db_maintenance_api::{self, DbMaintenanceResult as CoreResultView};

use super::state::with_state;

/// 数据库维护结果视图（core DbMaintenanceResult 的本地 DTO 镜像——
/// FRB 不跨 crate 暴露 core 类型，保持两端壳独立演进自由度）
#[derive(Debug, Clone)]
pub struct DbMaintenanceView {
    /// WAL checkpoint 后 -wal 文件剩余大小（字节）
    pub wal_bytes_after_checkpoint: i64,
    /// 附件 GC 清理的孤立文件数
    pub attachments_cleaned: i32,
    /// 日志 TTL 清理的行数（通知历史 + 活动日志，30 天口径）
    pub log_rows_pruned: i32,
    /// VACUUM 前空闲页数（碎片页）
    pub freelist_before: i64,
    /// VACUUM 后空闲页数（应为 0）
    pub freelist_after: i64,
    /// VACUUM 实际回收的页数
    pub pages_reclaimed: i64,
}

impl From<CoreResultView> for DbMaintenanceView {
    fn from(r: CoreResultView) -> Self {
        DbMaintenanceView {
            wal_bytes_after_checkpoint: r.wal_bytes_after_checkpoint,
            attachments_cleaned: r.attachments_cleaned as i32,
            log_rows_pruned: r.log_rows_pruned as i32,
            freelist_before: r.freelist_before,
            freelist_after: r.freelist_after,
            pages_reclaimed: r.pages_reclaimed,
        }
    }
}

/// 一键数据库维护：WAL checkpoint → 附件 GC → 附件缓存上限 → 日志 TTL → 全量 ANALYZE → VACUUM
///
/// 设置页「立即维护」用。**不要在启动路径调用**——`VACUUM` 的成本与库体积
/// 成正比、收益只与空闲页成正比，50k 稳态实测 429ms 换回 0 字节（见
/// `db_maintenance_api::db_maintenance_routine` 的实测口径）。
pub async fn db_maintenance() -> Result<DbMaintenanceView, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    db_maintenance_api::db_maintenance(&pool, &dir)
        .await
        .map_err(|e| e.to_string())
        .map(DbMaintenanceView::from)
}

/// 启动轻维护：WAL checkpoint → 附件 GC → 附件缓存上限 → 日志 TTL → 统计（仅在缺失时）
///
/// 与 [db_maintenance] 的唯一差别是**不做 VACUUM**：四步都是「不跑就会无界增长」
/// 且成本与库体积无关的动作，适合每次冷启动；VACUUM 只回收磁盘空间，归设置页
/// 手动入口（口径与桌面一致——桌面从来没有启动自动 VACUUM）。
///
/// 返回值里 `pages_reclaimed` 恒为 0：没跑 VACUUM 就没有「回收」可言。
pub async fn db_maintenance_routine() -> Result<DbMaintenanceView, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    db_maintenance_api::db_maintenance_routine(&pool, &dir)
        .await
        .map_err(|e| e.to_string())
        .map(DbMaintenanceView::from)
}
