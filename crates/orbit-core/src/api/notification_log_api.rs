//! notification_log_api — 通知历史中心（#5 高价值缺口）
//!
//! 桌面 Windows Toast、退出前注册系统调度，一旦错过或清掉就无处回看；
//! Todoist 有专门通知页。本 API 落地只读本地日志：
//! - **记录**：[log_notification]（提醒到期呈现 / 通知 action 处置）——
//!   写路径**不 emit db-change**（日志高频且用户无订阅面；查询侧刷新
//!   由 UI 主动 refetch 触发）；
//! - **查询**：[list_notification_log]（倒序分页 + kind 过滤）；
//! - **清理**：[clear_notification_log]（物理 DELETE——本表无软删语义，
//!   用户主动清空；TTL 自动清理走 [prune_old] 30 天）。
//!
//! 白名单口径：notification_log 是**本地呈现轨迹**（各端各自记录），
//! 不进 SYNCABLE_TABLES（口径同统计/holiday 缓存表）。

use sqlx::SqlitePool;

use crate::error::CoreResult;

/// 通知日志行（查询视图）
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct NotificationLogRow {
    pub id: i64,
    /// reminder_due / snooze / complete / boot_skip
    pub kind: String,
    pub task_id: Option<i64>,
    /// 任务标题快照（任务后续被删仍可读）
    pub task_title: String,
    pub reminder_id: Option<i64>,
    /// 附加 JSON：{remind_at, snooze_until, source}
    pub payload: String,
    pub created_at: i64,
}

/// 记录一条通知轨迹（kind 见行注释；高频写不 emit 事件）
pub async fn log_notification(
    pool: &SqlitePool,
    kind: &str,
    task_id: Option<i64>,
    task_title: &str,
    reminder_id: Option<i64>,
    payload: &str,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "INSERT INTO notification_log (kind, task_id, task_title, reminder_id, payload, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(kind)
    .bind(task_id)
    .bind(task_title)
    .bind(reminder_id)
    .bind(payload)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

/// 查询通知历史（created_at 倒序；limit 默认 50 上限 200；kind 可选过滤）
pub async fn list_notification_log(
    pool: &SqlitePool,
    kind: Option<String>,
    limit: Option<i64>,
) -> CoreResult<Vec<NotificationLogRow>> {
    let n = limit.unwrap_or(50).clamp(1, 200);
    let rows: Vec<NotificationLogRow> = if let Some(k) = kind {
        sqlx::query_as(
            "SELECT * FROM notification_log WHERE kind = ? ORDER BY created_at DESC, id DESC LIMIT ?",
        )
        .bind(k)
        .bind(n)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query_as("SELECT * FROM notification_log ORDER BY created_at DESC, id DESC LIMIT ?")
            .bind(n)
            .fetch_all(pool)
            .await?
    };
    Ok(rows)
}

/// 清空通知历史（物理 DELETE；用户主动操作）
pub async fn clear_notification_log(pool: &SqlitePool) -> CoreResult<u64> {
    let r = sqlx::query("DELETE FROM notification_log")
        .execute(pool)
        .await?;
    Ok(r.rows_affected())
}

/// TTL 清理：删除超过 N 天的日志（30 天口径；boot/低频调用均可）
pub async fn prune_old(pool: &SqlitePool, keep_days: i64) -> CoreResult<u64> {
    let cutoff = chrono::Utc::now().timestamp_millis() - keep_days * 24 * 3600 * 1000;
    let r = sqlx::query("DELETE FROM notification_log WHERE created_at < ?")
        .bind(cutoff)
        .execute(pool)
        .await?;
    Ok(r.rows_affected())
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

    #[tokio::test]
    async fn log_list_clear_roundtrip() {
        let pool = setup_db().await;
        log_notification(
            &pool,
            "reminder_due",
            Some(7),
            "买牛奶",
            Some(1),
            r#"{"remind_at":123}"#,
        )
        .await
        .unwrap();
        log_notification(
            &pool,
            "snooze",
            Some(7),
            "买牛奶",
            Some(1),
            r#"{"snooze_until":456}"#,
        )
        .await
        .unwrap();
        log_notification(
            &pool,
            "complete",
            Some(8),
            "周报",
            None,
            r#"{"source":"notification"}"#,
        )
        .await
        .unwrap();

        // 全量倒序：最后写入的在前
        let all = list_notification_log(&pool, None, None).await.unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].kind, "complete");
        assert_eq!(all[2].kind, "reminder_due");
        assert_eq!(all[1].task_title, "买牛奶");

        // kind 过滤
        let dues = list_notification_log(&pool, Some("reminder_due".into()), None)
            .await
            .unwrap();
        assert_eq!(dues.len(), 1);

        // 清空
        let n = clear_notification_log(&pool).await.unwrap();
        assert_eq!(n, 3);
        assert!(
            list_notification_log(&pool, None, None)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn prune_by_age() {
        let pool = setup_db().await;
        // 直插两行：30+ 天前与现在
        let old = chrono::Utc::now().timestamp_millis() - 31 * 24 * 3600 * 1000;
        sqlx::query("INSERT INTO notification_log (kind, task_title, payload, created_at) VALUES ('reminder_due', '旧', '{}', ?)")
            .bind(old).execute(&pool).await.unwrap();
        log_notification(&pool, "reminder_due", None, "新", None, "{}")
            .await
            .unwrap();

        let pruned = prune_old(&pool, 30).await.unwrap();
        assert_eq!(pruned, 1);
        let rest = list_notification_log(&pool, None, None).await.unwrap();
        assert_eq!(rest.len(), 1);
        assert_eq!(rest[0].task_title, "新");
    }

    #[tokio::test]
    async fn limit_clamped() {
        let pool = setup_db().await;
        for i in 0..60 {
            log_notification(&pool, "reminder_due", Some(i), &format!("t{i}"), None, "{}")
                .await
                .unwrap();
        }
        // 默认 50
        assert_eq!(
            list_notification_log(&pool, None, None)
                .await
                .unwrap()
                .len(),
            50
        );
        // 上限 200 不越
        assert_eq!(
            list_notification_log(&pool, None, Some(999))
                .await
                .unwrap()
                .len(),
            60
        );
    }
}
