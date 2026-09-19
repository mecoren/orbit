//! activity_log — 移动端桥接层：任务活动历史（历史区块批次，桌面 2026-09-18 已上线）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core::api::activity_log_api）：
//! - [activity_log_cmd](../../../../apps/desktop/src-tauri/src/commands/activity_log_cmd.rs)
//!   的 task_activity_list（单任务倒序查询，详情页「历史」区块）。
//! 轨迹埋点（log_activity）不经桥接面——core 写路径在业务函数内直接落库；
//! 本表是本地操作轨迹，不进同步白名单（各端各自记录）。

use orbit_core::api::activity_log_api;

use super::dto::ActivityLogRow;
use super::state::with_state;

/// 查询单任务活动历史（倒序；limit 缺省 30、上限 100 在 core 收口）
pub async fn task_activity_list(
    task_id: i64,
    limit: Option<i64>,
) -> Result<Vec<ActivityLogRow>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    activity_log_api::list_task_activity(&pool, task_id, limit)
        .await
        .map_err(|e| format!("[activity-log] {e}"))
        .map(|list| list.into_iter().map(ActivityLogRow::from).collect())
}
