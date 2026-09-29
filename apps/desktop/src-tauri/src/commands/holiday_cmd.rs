//! holiday_cmd — 节假日数据命令面（用户需求：日历视图联网更新节假日）
//!
//! 薄壳包装 orbit_core::api::holiday_api：
//! - `holidays_list` / `holiday_is_on`：日历视图渲染徽标用（按年合并兜底预置表）；
//! - `holidays_update`：**手动更新**（无视记账，失败返回错误文案给 toast）；
//! - `holiday_meta`：上次更新/尝试时间、连续失败次数、自动更新开关（设置页/日历工具栏）；
//! - `holiday_fetch_year`：按单年补写（设置页年份分组「更新该年」）；
//! - `holiday_fetch_range`：按年份范围补写（分片并发 + 连续失败熔断 + 可取消）；
//! - `holiday_cancel_fetch`：请求取消进行中的范围补写；
//! - `holiday_set_auto_enabled`：自动更新总开关。
//!
//! 自动更新由 [super::holiday_scheduler] 守护执行（60s tick + 每月一次判定）；
//! 范围补写的逐年进度经 `holiday-progress` 事件下发给前端，转发泵见
//! [super::holiday_scheduler::holiday_progress_pump_start]。

use orbit_core::api::holiday_api;
use tauri::State;

use crate::AppState;

/// 全部节假日行（date 升序；按年合并：DB 已覆盖年份为准，预置表兜底其余年份）
#[tauri::command]
pub async fn holidays_list(
    state: State<'_, AppState>,
) -> Result<Vec<holiday_api::HolidayInfo>, String> {
    holiday_api::list_holidays(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 判定某日期：Some(true) 放假 / Some(false) 调休补班 / None 普通日
#[tauri::command]
pub async fn holiday_is_on(
    state: State<'_, AppState>,
    date: String,
) -> Result<Option<bool>, String> {
    holiday_api::is_holiday_on(&state.pool, &date)
        .await
        .map_err(|e| e.to_string())
}

/// 手动更新（强制拉取；网络失败时错误文案给前端 toast，旧缓存保留）
#[tauri::command]
pub async fn holidays_update(
    state: State<'_, AppState>,
) -> Result<holiday_api::HolidayMeta, String> {
    holiday_api::update_holidays(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 更新记账（上次成功/尝试时间、连续失败次数、自动更新开关）
#[tauri::command]
pub async fn holiday_meta(state: State<'_, AppState>) -> Result<holiday_api::HolidayMeta, String> {
    holiday_api::holiday_meta(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 按单年补写（年份需在 2013 ~ 明年范围内；整年替换 + AC-E6 记账差异）
///
/// 返回记账 + 该年实际行数（`row_count == 0` = 该年线上无数据，UI 提示用）
#[tauri::command]
pub async fn holiday_fetch_year(
    state: State<'_, AppState>,
    year: i32,
) -> Result<holiday_api::HolidayYearOutcome, String> {
    holiday_api::fetch_holiday_year(&state.pool, year)
        .await
        .map_err(|e| e.to_string())
}

/// 按年份范围补写（并发拉取 + 串行落库 + 熔断；进度经 `holiday-progress` 事件）
#[tauri::command]
pub async fn holiday_fetch_range(
    state: State<'_, AppState>,
    start: i32,
    end: i32,
) -> Result<holiday_api::HolidayRangeSummary, String> {
    holiday_api::fetch_holiday_range(&state.pool, start, end)
        .await
        .map_err(|e| e.to_string())
}

/// 请求取消进行中的范围补写（幂等；无进行中操作时无害）
#[tauri::command]
pub async fn holiday_cancel_fetch() -> Result<(), String> {
    holiday_api::cancel_holiday_range_fetch();
    Ok(())
}

/// 设置自动更新总开关（关闭后调度器不再联网，仅保留手动与按年补写）
#[tauri::command]
pub async fn holiday_set_auto_enabled(
    state: State<'_, AppState>,
    enabled: bool,
) -> Result<(), String> {
    holiday_api::set_holiday_auto_enabled(&state.pool, enabled)
        .await
        .map_err(|e| e.to_string())
}
