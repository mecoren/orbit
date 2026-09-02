//! 待办模块复杂查询 API（Vikunja 化重构）
//!
//! 提供：
//! - 任务详情（含子任务/标签/评论/关系/提醒）
//! - 子任务完成切换 + 父任务进度自动重算
//! - 任务排序位置更新（拖拽）
//! - 看板视图数据（按项目分组）

use crate::db::repository::generic_repo;
use crate::error::CoreResult;
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::*;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};

/// 任务详情中的标签，附带 task_label 关联记录 id，便于移除
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskLabelWithId {
    #[serde(flatten)]
    pub label: TodoLabel,
    pub task_label_id: i64,
}

impl<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> for TaskLabelWithId {
    fn from_row(row: &'r sqlx::sqlite::SqliteRow) -> Result<Self, sqlx::Error> {
        let label = TodoLabel::from_row(row)?;
        let task_label_id = row.try_get("task_label_id")?;
        Ok(Self {
            label,
            task_label_id,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskDetail {
    #[serde(flatten)]
    pub task: TodoTask,
    pub subtasks: Vec<TodoSubtask>,
    pub labels: Vec<TaskLabelWithId>,
    pub comments: Vec<TodoComment>,
    pub relations: Vec<TodoTaskRelation>,
    pub reminders: Vec<TodoReminder>,
}

/// 查询任务详情（含子任务/标签/评论/关系/提醒）
pub async fn get_todo_task_detail(pool: &SqlitePool, id: i64) -> CoreResult<TodoTaskDetail> {
    let task: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;

    let subtasks: Vec<TodoSubtask> = sqlx::query_as(
        "SELECT * FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0 ORDER BY position, id",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;

    let labels: Vec<TaskLabelWithId> = sqlx::query_as(
        "SELECT l.*, tl.id as task_label_id FROM todo_labels l
         INNER JOIN todo_task_labels tl ON l.id = tl.label_id
         WHERE tl.task_id = ? AND tl.is_deleted = 0 AND l.is_deleted = 0
         ORDER BY l.title",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;

    let comments: Vec<TodoComment> = sqlx::query_as(
        "SELECT * FROM todo_comments WHERE task_id = ? AND is_deleted = 0 ORDER BY created_at, id",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;

    let relations: Vec<TodoTaskRelation> =
        sqlx::query_as("SELECT * FROM todo_task_relations WHERE task_id = ? AND is_deleted = 0")
            .bind(id)
            .fetch_all(pool)
            .await?;

    let reminders: Vec<TodoReminder> = sqlx::query_as(
        "SELECT * FROM todo_reminders WHERE task_id = ? AND is_deleted = 0 ORDER BY remind_at, id",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;

    Ok(TodoTaskDetail {
        task,
        subtasks,
        labels,
        comments,
        relations,
        reminders,
    })
}

/// 子任务完成状态切换 + 自动重算父任务 percent_done
pub async fn toggle_todo_subtask_done(
    pool: &SqlitePool,
    subtask_id: i64,
    done: bool,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let done_val: i32 = if done { 1 } else { 0 };
    let done_at: Option<i64> = if done { Some(now) } else { None };

    // 1. 更新子任务
    sqlx::query(
        "UPDATE todo_subtasks SET done = ?, done_at = ?, updated_at = ?, version = version + 1 WHERE id = ?"
    )
    .bind(done_val)
    .bind(done_at)
    .bind(now)
    .bind(subtask_id)
    .execute(pool).await?;

    // 2. 查询父任务 id
    let task_id: i64 = sqlx::query_scalar("SELECT task_id FROM todo_subtasks WHERE id = ?")
        .bind(subtask_id)
        .fetch_one(pool)
        .await?;

    // 3. 重算父任务 percent_done
    recalc_task_percent_done(pool, task_id).await?;

    Ok(())
}

/// 重算任务进度（已完成子任务数 / 总子任务数 * 100）
pub async fn recalc_task_percent_done(pool: &SqlitePool, task_id: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let total: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0",
    )
    .bind(task_id)
    .fetch_one(pool)
    .await?;

    let done_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0 AND done = 1",
    )
    .bind(task_id)
    .fetch_one(pool)
    .await?;

    let percent = if total == 0 {
        0.0
    } else {
        (done_count as f64 / total as f64) * 100.0
    };

    sqlx::query("UPDATE todo_tasks SET percent_done = ?, updated_at = ?, version = version + 1 WHERE id = ?")
        .bind(percent).bind(now).bind(task_id)
        .execute(pool).await?;

    Ok(())
}

/// 更新任务排序位置（拖拽排序）
pub async fn update_todo_task_position(
    pool: &SqlitePool,
    id: i64,
    position: f64,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "UPDATE todo_tasks SET position = ?, updated_at = ?, version = version + 1 WHERE id = ?",
    )
    .bind(position)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    // 发出更新事件（同步引擎需要）
    let task: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    EVENT_BUS.emit(DbEvent {
        table: "todo_tasks".into(),
        op: DbOp::Update,
        record_id: task.id,
        record_uuid: task.uuid.clone(),
        payload: serde_json::to_value(&task).ok(),
        device_id: crate::db::repository::generic_repo::current_device_id(),
        timestamp: now,
    });

    Ok(())
}

/// 更新项目排序位置（拖拽排序）
pub async fn update_todo_project_sort_order(
    pool: &SqlitePool,
    id: i64,
    sort_order: f64,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query("UPDATE todo_projects SET sort_order = ?, updated_at = ?, version = version + 1 WHERE id = ?")
        .bind(sort_order).bind(now).bind(id)
        .execute(pool).await?;

    let project: TodoProject = generic_repo::get_by_id(pool, "todo_projects", id).await?;
    EVENT_BUS.emit(DbEvent {
        table: "todo_projects".into(),
        op: DbOp::Update,
        record_id: project.id,
        record_uuid: project.uuid.clone(),
        payload: serde_json::to_value(&project).ok(),
        device_id: crate::db::repository::generic_repo::current_device_id(),
        timestamp: now,
    });

    Ok(())
}

/// 看板分组载荷：projectId（None=未分组）→ 组内任务列表
pub type KanbanGroup = (Option<i64>, Vec<TodoTask>);

/// 看板视图数据（按项目分组）
pub async fn get_todo_tasks_kanban_by_project(pool: &SqlitePool) -> CoreResult<Vec<KanbanGroup>> {
    let tasks: Vec<TodoTask> =
        sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0 ORDER BY position, id")
            .fetch_all(pool)
            .await?;

    // 按 project_id 分组（None 表示未分组）
    let mut map: std::collections::HashMap<Option<i64>, Vec<TodoTask>> =
        std::collections::HashMap::new();
    for t in tasks {
        map.entry(t.project_id).or_default().push(t);
    }
    // 按 project_id 排序（None 排最后）
    let mut result: Vec<KanbanGroup> = map.into_iter().collect();
    result.sort_by(|a, b| match (a.0, b.0) {
        (Some(a_id), Some(b_id)) => a_id.cmp(&b_id),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    Ok(result)
}

/// 看板视图数据（按状态分组）
pub async fn get_todo_tasks_kanban_by_status(
    pool: &SqlitePool,
) -> CoreResult<Vec<(String, Vec<TodoTask>)>> {
    let tasks: Vec<TodoTask> =
        sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0 ORDER BY position, id")
            .fetch_all(pool)
            .await?;

    // 按 status 分组
    let mut map: std::collections::HashMap<String, Vec<TodoTask>> =
        std::collections::HashMap::new();
    for t in tasks {
        map.entry(t.status.clone()).or_default().push(t);
    }
    // 按 pending → doing → done 顺序排列
    let order = ["pending", "doing", "done"];
    let mut result: Vec<(String, Vec<TodoTask>)> = Vec::new();
    for s in &order {
        if let Some(tasks) = map.remove(*s) {
            result.push((s.to_string(), tasks));
        }
    }
    // 其他状态追加到末尾
    for (status, tasks) in map {
        result.push((status, tasks));
    }
    Ok(result)
}
