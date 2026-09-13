//! activity_log_api — 任务操作活动日志（2026-09-12 F6）
//!
//! 对标 Todoist Activity log（免费版仅 1 周、Pro 完整——本地免费提供是差异化）
//! 与 Things 3 任务历史。落地本地只读轨迹：
//! - **记录**：[log_activity]——写路径埋点（create/update/complete/
//!   uncomplete/delete/restore），update 记变更字段集进 detail JSON；
//!   高频写**不 emit db-change**（口径同 notification_log）；
//! - **查询**：[list_task_activity]（单任务倒序，详情抽屉「历史」区块）。
//!
//! 白名单口径：todo_activity_log 是**本地操作轨迹**（各端各自记录，
//! 跨设备合并无意义——同步要的是结果态而非过程），不进 SYNCABLE_TABLES
//! （口径同 notification_log/统计表）。

use sqlx::SqlitePool;

use crate::error::CoreResult;

/// 活动日志行（查询视图）
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct ActivityLogRow {
    pub id: i64,
    pub task_id: Option<i64>,
    /// 任务标题快照（任务删除后仍可读）
    pub task_title: String,
    /// create / update / complete / uncomplete / delete / restore
    pub action: String,
    /// 附加 JSON：{"fields":["变更字段名",…]}（update）/ {}（其他）
    pub detail: String,
    /// 记录时间（ms）
    pub created_at: i64,
}

/// 记录一条任务操作轨迹（写路径埋点统一入口；高频写不 emit 事件）
pub async fn log_activity(
    pool: &SqlitePool,
    task_id: i64,
    task_title: &str,
    action: &str,
    detail_json: &str,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "INSERT INTO todo_activity_log (task_id, task_title, action, detail, created_at)
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(task_id)
    .bind(task_title)
    .bind(action)
    .bind(detail_json)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

/// 查询单任务活动历史（created_at 倒序；limit 默认 30 上限 100——
/// 详情抽屉区块展示量级，超长历史滚动加载不进首屏）
pub async fn list_task_activity(
    pool: &SqlitePool,
    task_id: i64,
    limit: Option<i64>,
) -> CoreResult<Vec<ActivityLogRow>> {
    let n = limit.unwrap_or(30).clamp(1, 100);
    let rows: Vec<ActivityLogRow> = sqlx::query_as(
        "SELECT * FROM todo_activity_log WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
    )
    .bind(task_id)
    .bind(n)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// TTL 清理（物理 DELETE——本表无软删语义；预留给 db_maintenance 接线）
pub async fn prune_old(pool: &SqlitePool, keep_days: i64) -> CoreResult<u64> {
    let cutoff = chrono::Utc::now().timestamp_millis() - keep_days * 86_400_000;
    let res = sqlx::query("DELETE FROM todo_activity_log WHERE created_at < ?")
        .bind(cutoff)
        .execute(pool)
        .await?;
    Ok(res.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 埋点写入 + 倒序查询 + detail JSON 透传
    #[tokio::test]
    async fn log_and_list_roundtrip() {
        let pool = setup_db().await;
        log_activity(&pool, 1, "任务甲", "create", "{}")
            .await
            .unwrap();
        log_activity(&pool, 1, "任务甲", "update", r#"{"fields":["priority"]}"#)
            .await
            .unwrap();
        log_activity(&pool, 2, "任务乙", "create", "{}")
            .await
            .unwrap();

        let rows = list_task_activity(&pool, 1, None).await.unwrap();
        assert_eq!(rows.len(), 2);
        // 倒序：update 在前
        assert_eq!(rows[0].action, "update");
        assert!(rows[0].detail.contains("priority"));
        assert_eq!(rows[1].action, "create");

        // 任务隔离：乙的轨迹不在甲的查询里
        let other = list_task_activity(&pool, 2, None).await.unwrap();
        assert_eq!(other.len(), 1);
    }

    /// TTL 清理：过期轨迹物理删除
    #[tokio::test]
    async fn prune_removes_old_rows() {
        let pool = setup_db().await;
        log_activity(&pool, 1, "旧任务", "create", "{}")
            .await
            .unwrap();
        // 手写一条 40 天前的过期行
        let old = chrono::Utc::now().timestamp_millis() - 40 * 86_400_000;
        sqlx::query(
            "INSERT INTO todo_activity_log (task_id, task_title, action, detail, created_at)
             VALUES (1, '旧任务', 'update', '{}', ?)",
        )
        .bind(old)
        .execute(&pool)
        .await
        .unwrap();
        let removed = prune_old(&pool, 30).await.unwrap();
        assert_eq!(removed, 1);
        let left = list_task_activity(&pool, 1, None).await.unwrap();
        assert_eq!(left.len(), 1);
    }
}
