//! stats_cmd — 统计仪表盘命令面（backlog #25）
//!
//! 薄壳包装 orbit_core::api::stats_api（只读聚合，不进同步白名单）：
//! - `stats_aggregate`：一次性返回全部统计卡片（总览/热力图/连续天数/项目/
//!   优先级/星期分布），UI 单次调用（避免六路往返）。
//!
//! 口径见 stats_api 模块头：done_at 本地时区日界，仅统计存活任务。

use orbit_core::api::stats_api;
use tauri::State;

use crate::AppState;

/// 统计聚合（days 为热力图窗口天数，35–371 钳制，默认 182=半年）
#[tauri::command]
pub async fn stats_aggregate(
    state: State<'_, AppState>,
    days: Option<i64>,
) -> Result<stats_api::StatsAggregate, String> {
    stats_api::aggregate(&state.pool, days.unwrap_or(182))
        .await
        .map_err(|e| e.to_string())
}
