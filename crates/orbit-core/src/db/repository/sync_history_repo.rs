//! sync_history_repo — 同步历史记录仓储
//!
//! 记录每次同步操作的元数据（类型、状态、计数、耗时）。
//! 同步引擎在 full_sync 开始时 insert，结束时 update_status。

use sqlx::SqlitePool;

use crate::error::CoreResult;
use crate::models::business::SyncHistory;

/// 插入一条同步历史记录，返回自增 id
///
/// - `sync_type`: "full" | "incremental" | "pull_only" | "push_only"
/// - `status`: "running" | "success" | "failed" | "cancelled"
pub async fn insert(
    pool: &SqlitePool,
    sync_type: &str,
    status: &str,
    started_at: i64,
) -> CoreResult<i64> {
    let result = sqlx::query(
        "INSERT INTO sync_history (sync_type, status, started_at, pulled_count, pushed_count, conflict_count)
         VALUES (?, ?, ?, 0, 0, 0)",
    )
    .bind(sync_type)
    .bind(status)
    .bind(started_at)
    .execute(pool)
    .await?;

    Ok(result.last_insert_rowid())
}

/// 更新同步历史状态（结束时调用）
#[allow(clippy::too_many_arguments)] // UPDATE 列一一对应，收组反而增加调用样板
pub async fn update_status(
    pool: &SqlitePool,
    id: i64,
    status: &str,
    finished_at: i64,
    pulled_count: i64,
    pushed_count: i64,
    conflict_count: i64,
    error_message: Option<&str>,
) -> CoreResult<()> {
    sqlx::query(
        "UPDATE sync_history
         SET status = ?, finished_at = ?, pulled_count = ?, pushed_count = ?,
             conflict_count = ?, error_message = ?
         WHERE id = ?",
    )
    .bind(status)
    .bind(finished_at)
    .bind(pulled_count)
    .bind(pushed_count)
    .bind(conflict_count)
    .bind(error_message)
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

/// 获取最近的同步历史（按 started_at 降序）
pub async fn get_recent(pool: &SqlitePool, limit: i64) -> CoreResult<Vec<SyncHistory>> {
    let items = sqlx::query_as::<_, SyncHistory>(
        "SELECT id, sync_type, status, started_at, finished_at,
                pulled_count, pushed_count, conflict_count, error_message
         FROM sync_history ORDER BY started_at DESC LIMIT ?",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(items)
}

/// 获取指定类型集合的最近同步历史（按 started_at 降序）
///
/// 用于桌面端 Tabs 布局下按 sync_type 过滤展示：
/// - 「云端全量备份」Tab 传入 `["cloud_full_backup", "local_full_backup"]`
/// - 「云端增量同步」Tab 暂不调用（功能开发中）
///
/// `sync_types` 为空时返回空 Vec，避免生成 `IN ()` 非法 SQL。
pub async fn get_recent_by_types(
    pool: &SqlitePool,
    sync_types: &[&str],
    limit: i64,
) -> CoreResult<Vec<SyncHistory>> {
    if sync_types.is_empty() {
        return Ok(Vec::new());
    }
    let placeholders = sync_types.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!(
        "SELECT id, sync_type, status, started_at, finished_at,
                pulled_count, pushed_count, conflict_count, error_message
         FROM sync_history
         WHERE sync_type IN ({})
         ORDER BY started_at DESC LIMIT ?",
        placeholders
    );
    let mut q = sqlx::query_as::<_, SyncHistory>(&sql);
    for t in sync_types {
        q = q.bind(t);
    }
    q = q.bind(limit);
    let items = q.fetch_all(pool).await?;
    Ok(items)
}

/// 获取最后一次成功的同步记录
pub async fn get_last_successful(
    pool: &SqlitePool,
    sync_type: &str,
) -> CoreResult<Option<SyncHistory>> {
    let item = sqlx::query_as::<_, SyncHistory>(
        "SELECT id, sync_type, status, started_at, finished_at,
                pulled_count, pushed_count, conflict_count, error_message
         FROM sync_history
         WHERE sync_type = ? AND status = 'success'
         ORDER BY started_at DESC LIMIT 1",
    )
    .bind(sync_type)
    .fetch_optional(pool)
    .await?;
    Ok(item)
}

/// 删除指定天数前的历史记录，返回删除条数
pub async fn delete_old(pool: &SqlitePool, before_timestamp: i64) -> CoreResult<i64> {
    let result = sqlx::query("DELETE FROM sync_history WHERE started_at < ?")
        .bind(before_timestamp)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() as i64)
}

/// 按类型保留最新 N 条，删除更旧的历史（增量同步各类型防无限增长）
///
/// 全量备份类型（cloud_full_backup/local_full_backup）由偏好
/// history_keep_count 独立清理，本函数只服务增量类型；返回删除条数。
pub async fn prune_by_type(pool: &SqlitePool, sync_type: &str, keep: i64) -> CoreResult<i64> {
    let result = sqlx::query(
        "DELETE FROM sync_history
         WHERE sync_type = ? AND id NOT IN (
             SELECT id FROM sync_history WHERE sync_type = ?
             ORDER BY started_at DESC, id DESC LIMIT ?
         )",
    )
    .bind(sync_type)
    .bind(sync_type)
    .bind(keep)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() as i64)
}

/// 按类型计数（历史卡头部摘要）
pub async fn count_by_type(pool: &SqlitePool, sync_type: &str) -> CoreResult<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM sync_history WHERE sync_type = ?")
        .bind(sync_type)
        .fetch_one(pool)
        .await?;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn memory_pool() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn seed(pool: &SqlitePool) {
        for (i, (ty, st)) in [
            ("incremental", "success"),
            ("incremental", "failed"),
            ("push_only", "success"),
            ("cloud_full_backup", "success"),
        ]
        .into_iter()
        .enumerate()
        {
            let id = insert(pool, ty, st, 1000 + i as i64).await.unwrap();
            update_status(pool, id, st, 1000 + i as i64, 1, 2, 0, None)
                .await
                .unwrap();
        }
    }

    /// 按类型保留最新 N 条：incremental 仅保留最新 1 条（id=2 被删，其余类型不受影响）
    #[tokio::test]
    async fn prune_by_type_keeps_latest_per_type_only() {
        let pool = memory_pool().await;
        seed(&pool).await;
        // 再插一条更晚的 incremental，使该类型共 3 条
        let id = insert(&pool, "incremental", "success", 2000).await.unwrap();
        update_status(&pool, id, "success", 2000, 0, 0, 0, None)
            .await
            .unwrap();

        let deleted = prune_by_type(&pool, "incremental", 1).await.unwrap();
        assert_eq!(deleted, 2);

        let recent = get_recent_by_types(&pool, &["incremental"], 10)
            .await
            .unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].started_at, 2000);
        // 其他类型不受影响
        assert_eq!(count_by_type(&pool, "push_only").await.unwrap(), 1);
        assert_eq!(count_by_type(&pool, "cloud_full_backup").await.unwrap(), 1);
    }

    /// get_recent_by_types 空类型集合返回空且不炸
    #[tokio::test]
    async fn get_recent_by_types_empty_is_noop() {
        let pool = memory_pool().await;
        seed(&pool).await;
        assert!(
            get_recent_by_types(&pool, &[], 10)
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            get_recent_by_types(&pool, &["incremental"], 10)
                .await
                .unwrap()
                .len(),
            2
        );
    }
}
