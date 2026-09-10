//! db_maintenance_cmd — 数据库维护命令（性能批次：磁盘维护 + 碎片整理）
//!
//! 薄壳包装 orbit_core::api::db_maintenance_api：
//! - `db_maintenance`：一条命令跑全套维护（WAL checkpoint → 附件 GC →
//!   PRAGMA optimize → VACUUM），返回量化结果供设置页展示。
//!
//! 只读维护路径：不 emit db-change（前端缓存无需失效），不进同步白名单。

use orbit_core::api::db_maintenance_api::{self, DbMaintenanceResult};
use tauri::Manager;

use crate::AppState;

/// 执行全套数据库维护（WAL checkpoint / 附件 GC / 查询统计 / VACUUM）
#[tauri::command]
pub async fn db_maintenance(app: tauri::AppHandle) -> Result<DbMaintenanceResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let dir = crate::commands::data_dir::resolve_app_data_dir(&app)?;
    let attachments_dir = crate::commands::sync_runtime::attachments_dir(&dir);
    db_maintenance_api::db_maintenance(&pool, &attachments_dir)
        .await
        .map_err(|e| format!("[maintenance] {e}"))
}
