//! holiday_cmd — 节假日数据命令面（用户需求：日历视图联网更新节假日）
//!
//! 薄壳包装 orbit_core::api::holiday_api：
//! - `holidays_list` / `holiday_is_on`：日历视图渲染徽标用（空库回落预置表）；
//! - `holidays_update`：**手动更新**（无视每日记账，失败返回错误文案给 toast）；
//! - `holiday_meta`：上次更新时间/连续失败次数（设置页/日历工具栏展示）；
//! - `holiday_set_fixed_hour`：每日固定更新时刻（默认 8 点，可调 0-23）。
//!
//! 自动更新由 [super::holiday_scheduler] 守护执行（60s tick +
//! should_update_now 判定；错过固定时刻后下次启动/下轮 tick 自动补更）。

use orbit_core::api::holiday_api;
use tauri::State;

use crate::AppState;

/// 全部节假日行（date 升序；空库回落预置 2026 表）
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

/// 更新记账（上次成功/尝试时间、连续失败次数、固定时刻）
#[tauri::command]
pub async fn holiday_meta(
    state: State<'_, AppState>,
) -> Result<holiday_api::HolidayMeta, String> {
    holiday_api::holiday_meta(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 设置每日固定更新时刻（0-23，越界 clamp）
#[tauri::command]
pub async fn holiday_set_fixed_hour(
    state: State<'_, AppState>,
    hour: u32,
) -> Result<(), String> {
    holiday_api::set_holiday_fixed_hour(&state.pool, hour)
        .await
        .map_err(|e| e.to_string())
}
