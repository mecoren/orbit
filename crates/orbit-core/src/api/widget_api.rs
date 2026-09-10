//! widget_api — Android 桌面小组件数据口（#3 存在感链条）
//!
//! 小组件不进 app 勾任务的两条通道：
//! - **查询**：`widget_todo_query` 拉今日口径（今天截止或已逾期未完成）
//!   前 N 条，Dart 快照写入 home_widget 数据面（RemoteViews 渲染）；
//!   口径与 B6 角标 `dueTodayOrOverdueCount` 一致（today+overdue）。
//! - **勾选**：原生勾选广播（无 Dart isolate，`HomeWidgetPlugin` 数据面
//!   不可用）经桥进 `widget_todo_toggle`——完成复用 `complete_todo_task`
//!   全语义（重复任务推进下一实例 + 提醒行平移 + 事件）；取消完成是
//!   完成后的反悔场景：重复任务下一实例已克隆，取消本实例静默不动
//!   （否则把「完成→误触取消」放大成克隆连锁）；普通任务裸 UPDATE
//!   复位 done/status/done_at 并发事件（缓存失效链依赖）。
//!
//! 只读查询不 emit 事件；勾选必然 emit（双端壳 db-change 消费）。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::TodoTask;

use super::todo_api::complete_todo_task;

/// 小组件列表容量上限（RemoteViews 行数有限；查询参数 clamp 到该值）
pub const WIDGET_MAX_ITEMS: i64 = 10;

/// 今日口径任务快照行（RemoteViews 渲染所需的最小字段集）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WidgetTodoItem {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub priority: i32,
    pub done: i32,
}

/// 拉小组件快照：今天截止或已逾期的未完成任务（优先级降序、截止升序、id 兜底）
///
/// 与 B6 角标口径一致：`due_date < 今日零点 + 24h`（含逾期与今日截止）。
/// limit 由调用方传（原生层 5~10 行），超过 [WIDGET_MAX_ITEMS] 截断。
pub async fn widget_todo_query(pool: &SqlitePool, limit: i64) -> CoreResult<Vec<WidgetTodoItem>> {
    let n = limit.clamp(1, WIDGET_MAX_ITEMS);
    let rows: Vec<TodoTask> = sqlx::query_as(
        "SELECT * FROM todo_tasks
         WHERE is_deleted = 0 AND done = 0 AND due_date IS NOT NULL AND due_date < ?
         ORDER BY priority DESC, due_date ASC, id ASC
         LIMIT ?",
    )
    .bind(chrono::Local::now().timestamp_millis() + 24 * 3600 * 1000)
    .bind(n)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|t| WidgetTodoItem {
            id: t.id,
            uuid: t.uuid,
            title: t.title,
            priority: t.priority,
            done: t.done,
        })
        .collect())
}

/// 小组件勾选切换：done=0 → 完成全语义；done=1 → 取消复位
pub async fn widget_todo_toggle(pool: &SqlitePool, id: i64, done: i32) -> CoreResult<()> {
    let task: TodoTask = sqlx::query_as("SELECT * FROM todo_tasks WHERE id = ? AND is_deleted = 0")
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("task id={id}")))?;

    if done == 1 {
        if task.done == 1 {
            return Ok(()); // 幂等：重复勾选静默
        }
        // 完成复用完整语义（重复推进/提醒平移/事件全在事务内编排）
        complete_todo_task(pool, id).await?;
        return Ok(());
    }

    if task.done == 0 {
        return Ok(()); // 幂等：重复取消静默
    }
    // 取消完成：仅普通任务复位；重复任务静默不动（完成时下一实例已克隆，
    // 取消本实例不撤回克隆——避免勾选抖动放大成克隆连锁）
    if task.repeat_mode != 0 {
        return Ok(());
    }
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "UPDATE todo_tasks SET done = 0, done_at = NULL, status = 'pending', updated_at = ?, version = version + 1
         WHERE id = ?",
    )
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;
    EVENT_BUS.emit(DbEvent {
        table: "todo_tasks".into(),
        op: DbOp::Update,
        record_id: task.id,
        record_uuid: task.uuid,
        payload: None,
        device_id: crate::db::repository::generic_repo::current_device_id(),
        timestamp: now,
    });
    Ok(())
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

    /// 直插一条任务（绕过 create 输入面，精准控制 due/priority；due=None 存 NULL）
    async fn seed(pool: &SqlitePool, title: &str, due: Option<i64>, priority: i32) -> i64 {
        let now = chrono::Utc::now().timestamp_millis();
        let row: TodoTask = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, priority, status, done, due_date, repeat_mode, is_deleted, created_at, updated_at, version)
             VALUES (?, ?, ?, 'pending', 0, ?, 0, 0, ?, ?, 1) RETURNING *",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(title)
        .bind(priority)
        .bind(due)
        .bind(now)
        .bind(now)
        .fetch_one(pool)
        .await
        .unwrap();
        row.id
    }

    #[tokio::test]
    async fn query_returns_today_and_overdue_only() {
        let pool = setup_db().await;
        let now = chrono::Local::now().timestamp_millis();
        let overdue = seed(&pool, "逾期", Some(now - 3 * 24 * 3600 * 1000), 1).await;
        let today = seed(&pool, "今天", Some(now + 3600 * 1000), 2).await;
        let future = seed(&pool, "三天后", Some(now + 3 * 24 * 3600 * 1000), 3).await;
        let none = seed(&pool, "无截止", None, 4).await;
        let _ = future;

        let items = widget_todo_query(&pool, 10).await.unwrap();
        let ids: Vec<i64> = items.iter().map(|i| i.id).collect();
        assert!(ids.contains(&overdue) && ids.contains(&today));
        assert!(!ids.contains(&future));
        // 无截止任务不应出现在 widget（due_date IS NOT NULL 过滤）
        assert!(!ids.contains(&none));
        // 优先级降序：今天(2) 在 逾期(1) 前
        assert_eq!(items[0].id, today);
    }

    #[tokio::test]
    async fn query_limit_clamped() {
        let pool = setup_db().await;
        let now = chrono::Local::now().timestamp_millis();
        for i in 0..15 {
            seed(&pool, &format!("任务{i}"), Some(now - 1000), (i % 6) as i32).await;
        }
        let items = widget_todo_query(&pool, 999).await.unwrap();
        assert_eq!(items.len(), WIDGET_MAX_ITEMS as usize);
    }

    #[tokio::test]
    async fn toggle_complete_and_undo() {
        let pool = setup_db().await;
        let now = chrono::Local::now().timestamp_millis();
        let id = seed(&pool, "普通任务", Some(now + 3600 * 1000), 2).await;

        // 勾选完成：done=1/status=done/done_at 落值
        widget_todo_toggle(&pool, id, 1).await.unwrap();
        let t: TodoTask = sqlx::query_as("SELECT * FROM todo_tasks WHERE id = ?")
            .bind(id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(t.done, 1);
        assert_eq!(t.status, "done");
        assert!(t.done_at.is_some());

        // 取消完成：复位三件套
        widget_todo_toggle(&pool, id, 0).await.unwrap();
        let t: TodoTask = sqlx::query_as("SELECT * FROM todo_tasks WHERE id = ?")
            .bind(id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(t.done, 0);
        assert_eq!(t.status, "pending");
        assert!(t.done_at.is_none());
    }

    #[tokio::test]
    async fn toggle_repeat_task_undo_is_noop() {
        let pool = setup_db().await;
        let now = chrono::Local::now().timestamp_millis();
        // 每日重复任务（repeat_mode=1 = 每天）
        let row: TodoTask = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, priority, status, done, due_date, repeat_mode, repeat_after, is_deleted, created_at, updated_at, version)
             VALUES (?, '重复任务', 2, 'pending', 0, ?, 1, 1, 0, ?, ?, 1) RETURNING *",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(now + 3600 * 1000)
        .bind(now)
        .bind(now)
        .fetch_one(&pool)
        .await
        .unwrap();

        // 完成：克隆出下一实例
        widget_todo_toggle(&pool, row.id, 1).await.unwrap();
        let all: Vec<TodoTask> = sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0")
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(all.len(), 2, "完成重复任务应克隆下一实例");

        // 取消完成：静默不动（下一实例保留、本实例保持已完成）
        widget_todo_toggle(&pool, row.id, 0).await.unwrap();
        let after: Vec<TodoTask> = sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0")
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(after.len(), 2, "取消重复任务不撤回克隆");
        let me = after.iter().find(|t| t.id == row.id).unwrap();
        assert_eq!(me.done, 1, "本实例保持已完成态");
    }

    #[tokio::test]
    async fn toggle_idempotent_and_missing() {
        let pool = setup_db().await;
        let now = chrono::Local::now().timestamp_millis();
        let id = seed(&pool, "任务", Some(now + 3600 * 1000), 1).await;

        // 重复取消未完成任务：静默
        widget_todo_toggle(&pool, id, 0).await.unwrap();
        // 完成两次：第二次静默（不克隆重复任务、不炸）
        widget_todo_toggle(&pool, id, 1).await.unwrap();
        widget_todo_toggle(&pool, id, 1).await.unwrap();
        // 不存在的任务：NotFound
        assert!(widget_todo_toggle(&pool, 99999, 1).await.is_err());
    }
}
