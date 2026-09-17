//! sync_conflict — 移动端桥接层：冲突败方副本（03 文档 §八 遗留项）
//!
//! 与桌面壳命令一一对应（薄包装，业务在 `orbit_core::api::sync_conflict_api`）：
//! 列表 / 计数 / 恢复 / 忽略 / 清空。`clear` 在 Dart 侧无 u64，故桥面统一收成 i64。

use orbit_core::api::sync_conflict_api;

use super::dto::SyncConflict;
use super::state::with_state;

/// 列出冲突记录（`resolution` 为 None 时返回全部；按时间倒序分页）
pub async fn sync_conflict_list(
    resolution: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<Vec<SyncConflict>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    sync_conflict_api::list_conflicts(&pool, resolution, limit, offset)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(SyncConflict::from).collect())
}

/// 统计冲突记录数（传 "unresolved" 只要待处理）
pub async fn sync_conflict_count(resolution: Option<String>) -> Result<i64, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    sync_conflict_api::count_conflicts(&pool, resolution)
        .await
        .map_err(|e| e.to_string())
}

/// 恢复某条冲突的败方内容（返回被写回的原行 id）
pub async fn sync_conflict_restore(id: i64) -> Result<i64, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    sync_conflict_api::restore_conflict(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 忽略某条冲突（不改业务数据）
pub async fn sync_conflict_dismiss(id: i64) -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    sync_conflict_api::dismiss_conflict(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 清空冲突记录（`resolution` 为 None 时清全部），返回删除条数
pub async fn sync_conflict_clear(resolution: Option<String>) -> Result<i64, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    sync_conflict_api::clear_conflicts(&pool, resolution)
        .await
        .map(|n| n as i64)
        .map_err(|e| e.to_string())
}
