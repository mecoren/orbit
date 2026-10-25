//! db_maintenance_cmd — 数据库维护命令（性能批次：磁盘维护 + 碎片整理）
//!
//! 薄壳包装 orbit_core::api::db_maintenance_api：
//! - `db_maintenance`：一条命令跑全套维护（WAL checkpoint → 附件 GC →
//!   全量 ANALYZE → VACUUM），返回量化结果供设置页展示。
//! - `spawn_idle_plan_stats`：启动后空闲时机补一次查询计划统计
//!   （docs/13 §七 P5）——不是命令，由 `lib.rs` 的 setup 直接调用。
//!
//! 只读维护路径：不 emit db-change（前端缓存无需失效），不进同步白名单。

use std::time::Duration;

use orbit_core::api::db_maintenance_api::{self, DbMaintenanceResult, MIN_ROWS_FOR_PLAN_STATS};
use tauri::Manager;

use crate::AppState;

/// 首屏之后再等多久才去建统计
///
/// 取值理由：首位列表查询在首帧后几十毫秒内就会发出，而全量 `ANALYZE` 在
/// 50k 行要 47～88ms、1M 行线性外推到 1～2s——两者叠在一起会直接吃掉
/// P1「首屏可交互 < 1.5s」的预算。15s 后用户基本已进入正常操作节奏，且
/// 「空闲时不抢 IO」比「尽早建好」更重要（收益是每次列表 10ms，晚 15s 无感）。
const IDLE_DELAY_SECS: u64 = 15;

/// 启动后空闲时机补一次查询计划统计（docs/13 §七 P5）
///
/// 只在「从来没有统计 + `todo_tasks` 行数到门槛」时真跑（判据在 core 的
/// `maybe_analyze_plan_stats` 里）；跑过一次之后再启动都是零成本空转。
///
/// 失败只记日志：统计是纯优化项，缺它只是首屏列表慢 10ms，不影响任何正确性
/// ——绝不因为建统计失败去打扰用户或阻断启动。
pub fn spawn_idle_plan_stats(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(IDLE_DELAY_SECS)).await;
        let Some(state) = app.try_state::<AppState>() else {
            return; // DB 未就绪（或已卸载），静默跳过
        };
        let pool = state.pool.clone();
        match db_maintenance_api::maybe_analyze_plan_stats(&pool, MIN_ROWS_FOR_PLAN_STATS).await {
            Ok(true) => log::info!("[maintenance] 空闲时机建立查询计划统计（首屏列表计划切换）"),
            Ok(false) => {}
            Err(e) => log::warn!("[maintenance] 建立查询计划统计失败（不影响功能）: {e}"),
        }
    });
}

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
