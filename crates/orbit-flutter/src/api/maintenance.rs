//! maintenance — 移动端桥接层：数据库维护（性能批次）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在
//! orbit_core::api::db_maintenance_api）：
//! - [db_maintenance_cmd](../../../../../apps/desktop/src-tauri/src/commands/db_maintenance_cmd.rs)
//!   的 db_maintenance。
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
            freelist_before: r.freelist_before,
            freelist_after: r.freelist_after,
            pages_reclaimed: r.pages_reclaimed,
        }
    }
}

/// 一键数据库维护：WAL checkpoint → 附件 GC → PRAGMA optimize → VACUUM
pub async fn db_maintenance() -> Result<DbMaintenanceView, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let dir = base_dir.join("attachments").to_string_lossy().to_string();
    db_maintenance_api::db_maintenance(&pool, &dir)
        .await
        .map_err(|e| e.to_string())
        .map(DbMaintenanceView::from)
}
