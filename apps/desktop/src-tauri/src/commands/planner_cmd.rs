//! planner_cmd - 日排程命令薄层（F3；预览与应用语义见 day_planner_api）

use orbit_core::api::day_planner_api::{
    self, ApplyResult, ApplySlotInput, DayPlan, DayPlanPrefs,
};
use tauri::State;

use crate::AppState;

/// 规划今天：排程预览（now_ms 由前端传 Date.now()，
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

/// 读取排程偏好（cfg_kv，缺键回落默认；编辑区初值）
#[tauri::command]
pub async fn day_plan_prefs_get(state: State<'_, AppState>) -> Result<DayPlanPrefs, String> {
    day_planner_api::get_day_plan_prefs(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 保存排程偏好（校验钳制后落库，返回存后生效值供 UI 回显）
#[tauri::command]
pub async fn day_plan_prefs_set(
    state: State<'_, AppState>,
    prefs: DayPlanPrefs,
) -> Result<DayPlanPrefs, String> {
    day_planner_api::set_day_plan_prefs(&state.pool, &prefs)
        .await
        .map_err(|e| e.to_string())
}

/// 应用排程（阶段二）：勾选槽位写入 my_day_date + start_date（不改 due_date，
/// 单事务）；返回 prev 快照供前端撤销。day_start_ms 由前端传今天本地零点。
#[tauri::command]
pub async fn day_plan_apply(
    state: State<'_, AppState>,
    day_start_ms: i64,
    slots: Vec<ApplySlotInput>,
) -> Result<ApplyResult, String> {
    day_planner_api::apply_day_plan(&state.pool, day_start_ms, &slots)
        .await
        .map_err(|e| e.to_string())
}
