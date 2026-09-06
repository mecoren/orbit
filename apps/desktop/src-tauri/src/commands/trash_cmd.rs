//! trash_cmd — 回收站命令面（用户需求：删除的任务进回收站，保留时间可配，可恢复）
//!
//! 薄壳包装 orbit_core::api::trash_api：
//! - `trash_tasks_list`：回收站列表（最近删除排最前）；
//! - `trash_task_restore`：恢复（原项目已删则落未分组）；
//! - `trash_task_purge` / `trash_purge_all`：彻底删除单个 / 清空回收站；
//! - `trash_purge_expired`：手动触发 TTL 清理（含同步守卫）；
//! - `trash_meta` / `trash_set_retention_days`：保留档位（7/30/90/永久，默认 30）。
//!
//! 自动过期清理由 [super::trash_scheduler] 守护执行（60s tick +
//! should_purge_now 每日判定；启动首轮即补清，不等下一分钟 tick）。

use orbit_core::api::trash_api;
use tauri::State;

use crate::AppState;

/// 回收站任务列表（is_deleted=1 墓碑行，deleted_at 降序）
#[tauri::command]
pub async fn trash_tasks_list(
    state: State<'_, AppState>,
) -> Result<Vec<orbit_core::models::business::TodoTask>, String> {
    trash_api::list_trashed_tasks(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 恢复任务（翻转回存活态；原项目已删则落入未分组）
#[tauri::command]
pub async fn trash_task_restore(
    state: State<'_, AppState>,
    id: i64,
) -> Result<orbit_core::models::business::TodoTask, String> {
    trash_api::restore_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 彻底删除单个回收站任务（物理 DELETE，含子任务/标签关联/评论/关系/提醒）
#[tauri::command]
pub async fn trash_task_purge(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    trash_api::purge_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 清空回收站（全部墓碑任务物理删除），返回删除数
#[tauri::command]
pub async fn trash_purge_all(state: State<'_, AppState>) -> Result<u64, String> {
    trash_api::purge_all_trashed_tasks(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// TTL 过期清理一次（60s tick 守护调用；也可手动触发）
#[tauri::command]
pub async fn trash_purge_expired(
    state: State<'_, AppState>,
) -> Result<trash_api::PurgeStats, String> {
    trash_api::maybe_purge_expired(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 回收站元数据（保留档位 + 上次自动清理时间）
#[tauri::command]
pub async fn trash_meta(state: State<'_, AppState>) -> Result<trash_api::TrashMeta, String> {
    trash_api::trash_meta(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 设置保留天数（合法档位 7/30/90/0=永久；默认 30）
#[tauri::command]
pub async fn trash_set_retention_days(
    state: State<'_, AppState>,
    days: i64,
) -> Result<(), String> {
    trash_api::set_trash_retention_days(&state.pool, days)
        .await
        .map_err(|e| e.to_string())
}
