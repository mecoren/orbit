//! planner_cmd - 日排程预览命令薄层（F3 阶段一只读；语义见 day_planner_api）

use orbit_core::api::day_planner_api::{self, DayPlan, DayPlanPrefs};
use tauri::State;

use crate::AppState;

/// 规划今天：只读排程预览（不写库；now_ms 由前端传 Date.now()，
/// 偏好阶段一双端传默认值，阶段三落 cfg_kv 可编辑）
#[tauri::command]
pub async fn day_plan_preview(
    state: State<'_, AppState>,
    prefs: DayPlanPrefs,
    now_ms: i64,
) -> Result<DayPlan, String> {
    day_planner_api::plan_day(&state.pool, &prefs, now_ms)
        .await
        .map_err(|e| e.to_string())
}
