//! stats_cmd — 统计仪表盘命令面（backlog #25）
//!
//! 薄壳包装 orbit_core::api::stats_api（只读聚合，不进同步白名单）：
//! - `stats_aggregate`：一次性返回全部统计卡片（总览/热力图/连续天数/项目/
//!   优先级/星期分布/可选年份），UI 单次调用（避免七路往返）。
//!
//! 口径见 stats_api 模块头：done_at 本地时区日界，仅统计存活任务；
//! 热力图按年聚合（2026-09-10 对齐 wait-home：当前年滚动 365 天、历史年完整年）。

use orbit_core::api::stats_api;
use tauri::State;

use crate::AppState;

/// 统计聚合（year 为热力图年份，None = 当前年；返回含 available_years 供年份 pill）
#[tauri::command]
pub async fn stats_aggregate(
    state: State<'_, AppState>,
    year: Option<i64>,
) -> Result<stats_api::StatsAggregate, String> {
    stats_api::aggregate(&state.pool, year)
        .await
        .map_err(|e| e.to_string())
}
