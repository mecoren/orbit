//! digest_cmd — 每日摘要提醒命令面（对标 TickTick Daily Reminder）
//!
//! 薄壳包装 `orbit_core::api::digest_api`：
//! - `digest_prefs`：读开关与目标时刻（"HH:mm"）；
//! - `digest_set_prefs`：写开关 + 时刻（hour 0–23 / minute 0–59，越界报错）；
//! - `digest_summary`：当前时刻的摘要计数（设置页实时预览「今天会提醒什么」）。
//!
//! 到点发送由 [super::digest_scheduler] 守护执行（60s tick + 每日一次判定）。
//! 偏好存 `cfg_kv`（本机设置，不随云同步），与回收站保留时间同边界。

use orbit_core::api::digest_api;
use tauri::State;

use crate::AppState;

/// 读摘要偏好（开关 + 目标时刻）
#[tauri::command]
pub async fn digest_prefs(state: State<'_, AppState>) -> Result<digest_api::DigestPrefs, String> {
    digest_api::digest_prefs(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 设置摘要偏好（enabled + hour 0–23 + minute 0–59）
#[tauri::command]
pub async fn digest_set_prefs(
    state: State<'_, AppState>,
    enabled: bool,
    hour: i64,
    minute: i64,
) -> Result<(), String> {
    digest_api::set_digest_prefs(&state.pool, enabled, hour, minute)
        .await
        .map_err(|e| e.to_string())
}

/// 当前时刻摘要计数（设置页预览；只读，不改每日记账）
#[tauri::command]
pub async fn digest_summary(
    state: State<'_, AppState>,
) -> Result<digest_api::DigestSummary, String> {
    let now = chrono::Utc::now().timestamp_millis();
    digest_api::digest_summary(&state.pool, now)
        .await
        .map_err(|e| e.to_string())
}
