//! activity_log_cmd — 任务活动日志命令组（2026-09-12 F6）
//!
//! 薄壳包装 orbit_core::api::activity_log_api（单任务历史查询）。
//! 写入（log_activity）不经命令面——core 写路径（create/update/
//! complete/delete/restore）在业务函数内直接埋点。

use orbit_core::api::activity_log_api::{self, ActivityLogRow};

use crate::AppState;

/// 查询单任务活动历史（倒序；详情抽屉「历史」区块）
#[tauri::command]
pub async fn task_activity_list(
    state: tauri::State<'_, AppState>,
    task_id: i64,
    limit: Option<i64>,
) -> Result<Vec<ActivityLogRow>, String> {
    activity_log_api::list_task_activity(&state.pool, task_id, limit)
        .await
        .map_err(|e| format!("[activity-log] {e}"))
}
