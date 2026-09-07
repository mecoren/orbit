//! 待办模块复杂查询 API（Vikunja 化重构）
//!
//! 提供：
//! - 任务详情（含子任务/标签/评论/关系/提醒）
//! - 子任务完成切换 + 父任务进度自动重算
//! - 任务排序位置更新（拖拽）
//! - 看板视图数据（按项目分组）

use crate::db::repository::generic_repo;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::*;
use chrono::{Datelike, TimeZone};
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

// ============================================================================
// 重复任务推进引擎（三端统一，07 报告 §五-P1#10 引擎下沉）
// ============================================================================

/// 重复规则取值（与 todo_tasks.repeat_mode 列语义一致）
pub const REPEAT_MODE_NONE: i32 = 0;
pub const REPEAT_MODE_DAILY: i32 = 1;
pub const REPEAT_MODE_WEEKLY: i32 = 2;
pub const REPEAT_MODE_MONTHLY: i32 = 3;
pub const REPEAT_MODE_YEARLY: i32 = 4;

/// 月/年推进的日历语义：日号超过目标月天数时截断到月末（1/31 → 2/28），
/// 避免溢出滚入下下月。截断后锚点随链式推进永久退化为短月日号
/// （1/31 → 2/28 → 3/28，与桌面端 repeat.ts 评审 M3 口径一致）。
fn advance_calendar_months(d: &mut chrono::DateTime<chrono::Local>, months: i32) {
    let time = d.time();
    let (year, month) = (d.year(), d.month() as i32);
    // 月号从 0 基换算：先转到目标月的 1 号，再截断日号
    let (ty, tm0) = (
        (year * 12 + month - 1 + months) / 12,
        (month - 1 + months).rem_euclid(12),
    );
    let days_in_target = last_day_of_month(ty, tm0 as u32 + 1);
    let day = d.day().min(days_in_target);
    let naive = chrono::NaiveDate::from_ymd_opt(ty, tm0 as u32 + 1, day)
        .expect("month advance always yields a valid date")
        .and_time(time);
    if let Some(local) = chrono::Local.from_local_datetime(&naive).single() {
        *d = local;
    }
}

/// 目标年月的天数（12 月 → 次年 1 月倒推；2 月闰年 29）
fn last_day_of_month(year: i32, month: u32) -> u32 {
    let (y, m) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    chrono::NaiveDate::from_ymd_opt(y, m, 1)
        .unwrap()
        .pred_opt()
        .unwrap()
        .day()
}

/// base 的下一次发生时间（> from）；无规则或快进超限（>5000 步）返回 None。
/// 天/周为固定毫秒跨度；月/年走日历语义（见 advance_calendar_months）。
/// 快进上限按天约 13 年，防异常数据死循环（与桌面端 nextRepeatAt 一致）。
pub fn next_repeat_at(base_ms: i64, mode: i32, after: i64, from_ms: i64) -> Option<i64> {
    if mode == REPEAT_MODE_NONE {
        return None;
    }
    let step = after.max(1) as u32;
    let mut next = chrono::Local.timestamp_millis_opt(base_ms).single()?;
    for _ in 0..5000 {
        match mode {
            REPEAT_MODE_DAILY => next += chrono::Duration::days(step as i64),
            REPEAT_MODE_WEEKLY => next += chrono::Duration::days(7 * step as i64),
            REPEAT_MODE_MONTHLY => advance_calendar_months(&mut next, step as i32),
            REPEAT_MODE_YEARLY => advance_calendar_months(&mut next, 12 * step as i32),
            _ => return None,
        }
        if next.timestamp_millis() > from_ms {
            return Some(next.timestamp_millis());
        }
    }
    None
}

/// 下一重复实例的规划结果（与桌面端 NextInstancePlan 同构）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NextInstancePlan {
    pub input: TodoTaskCreateInput,
    /// 下一 due 与原 due 的差值(ms)，start 等派生时间用它对齐
    pub delta_ms: i64,
}

/// 计算下一实例；无规则、无 due 或快进超限返回 None
///
/// 语义（与桌面端 repeat-task.ts 逐字对齐）：
/// - due 序列锚定**原 due_date** 推进，提前完成不改变节奏，
///   长期逾期快进到未来最近的序列点；
/// - start 平移与 due 相同的 delta；子任务仅复制标题与顺序；
/// - 克隆字段：标题/描述/项目/优先级/收藏/重复规则；不复制提醒。
pub fn plan_next_recurring_instance(task: &TodoTask, now_ms: i64) -> Option<NextInstancePlan> {
    if task.repeat_mode == REPEAT_MODE_NONE || task.due_date.is_none() {
        return None;
    }
    let due = task.due_date.unwrap();
    let next_due = next_repeat_at(due, task.repeat_mode, task.repeat_after, now_ms)?;
    let delta_ms = next_due - due;
    let shift = |ms: Option<i64>| ms.map(|v| v + delta_ms);
    Some(NextInstancePlan {
        input: TodoTaskCreateInput {
            title: task.title.clone(),
            description: task.description.clone(),
            project_id: task.project_id,
            priority: Some(task.priority),
            status: Some("pending".into()),
            done: Some(0),
            done_at: None,
            due_date: Some(next_due),
            start_date: shift(task.start_date),
            repeat_after: Some(task.repeat_after),
            repeat_mode: Some(task.repeat_mode),
            position: None,
            is_favorite: Some(task.is_favorite),
            my_day_date: None,
        },
        delta_ms,
    })
}

/// 待克隆到新实例的子任务：过滤软删、position 升序、完成态不带走
pub fn subtasks_to_clone(subtasks: &[TodoSubtask]) -> Vec<(String, f64)> {
    let mut live: Vec<&TodoSubtask> = subtasks.iter().filter(|s| s.is_deleted == 0).collect();
    live.sort_by(|a, b| {
        a.position
            .partial_cmp(&b.position)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    live.into_iter()
        .map(|s| (s.title.clone(), s.position))
        .collect()
}

/// 统一完成命令的结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompleteTaskResult {
    /// 完成后的任务（done=1 / status="done" / done_at=now）
    pub task: TodoTask,
    /// 重复任务推进生成的下一实例（普通任务为 None）
    pub next_instance: Option<TodoTask>,
}

/// 统一完成任务（三端唯一入口）：
/// - 普通任务：标记 done=1 + done_at=now + status="done"；
/// - 重复任务（repeat_mode>0 且有 due_date）：**单事务内**「创建下一实例
///   （含克隆子任务标题）+ 标记本实例完成」，替代桌面端旧的两步 IPC 编排
///   （先建再标，中间崩溃会丢推进；事务保证原子性）；
/// - 不复制提醒（口径同桌面引擎）。
///
/// 事件在事务提交后发出（Insert todo_tasks ×2 / Insert todo_subtasks ×N /
/// Update todo_tasks），同步引擎与双端缓存照常消费。
pub async fn complete_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<CompleteTaskResult> {
    let task: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    if task.is_deleted == 1 {
        return Err(CoreError::Other(format!(
            "任务 id={id} 已在回收站，无法完成"
        )));
    }
    let now = chrono::Utc::now().timestamp_millis();

    let plan = if task.done == 1 {
        None // 已完成任务的重复完成是幂等动作（评审 I2），不再推进
    } else {
        plan_next_recurring_instance(&task, now)
    };
    let subtasks_to_copy: Vec<(String, f64)> = match &plan {
        None => Vec::new(),
        Some(_) => {
            let rows: Vec<TodoSubtask> =
                sqlx::query_as("SELECT * FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0")
                    .bind(id)
                    .fetch_all(pool)
                    .await?;
            subtasks_to_clone(&rows)
        }
    };

    let mut tx = pool.begin().await?;
    let mut next_instance: Option<TodoTask> = None;
    if let Some(plan) = &plan {
        let new_uuid = uuid::Uuid::new_v4().to_string();
        let i = &plan.input;
        let created: TodoTask = sqlx::query_as(
            "INSERT INTO todo_tasks (
                uuid, title, description, project_id, priority, status, done, done_at,
                due_date, start_date, repeat_after, repeat_mode,
                percent_done, position, is_favorite, my_day_date,
                is_deleted, created_at, updated_at, version
            ) VALUES (?, ?, ?, ?, ?, 'pending', 0, NULL, ?, ?, ?, ?, 0, 0, ?, ?, 0, ?, ?, 1)
            RETURNING *",
        )
        .bind(&new_uuid)
        .bind(&i.title)
        .bind(i.description.as_deref())
        .bind(i.project_id)
        .bind(i.priority.unwrap_or(0))
        .bind(i.due_date)
        .bind(i.start_date)
        .bind(i.repeat_after.unwrap_or(0))
        .bind(i.repeat_mode.unwrap_or(0))
        .bind(i.is_favorite.unwrap_or(0))
        .bind(i.my_day_date)
        .bind(now)
        .bind(now)
        .fetch_one(&mut *tx)
        .await?;
        for (title, position) in &subtasks_to_copy {
            let sub_uuid = uuid::Uuid::new_v4().to_string();
            sqlx::query(
                "INSERT INTO todo_subtasks (uuid, task_id, title, done, done_at, position, is_deleted, created_at, updated_at, version)
                 VALUES (?, ?, ?, 0, NULL, ?, 0, ?, ?, 1)",
            )
            .bind(&sub_uuid)
            .bind(created.id)
            .bind(title)
            .bind(*position)
            .bind(now)
            .bind(now)
            .execute(&mut *tx)
            .await?;
        }
        next_instance = Some(created);
    }

    let done_task: TodoTask = sqlx::query_as(
        "UPDATE todo_tasks SET done = 1, done_at = ?, status = 'done', updated_at = ?, version = version + 1
         WHERE id = ? RETURNING *",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;

    // 事件在提交后发出（提交前发出会让消费者读到未提交数据）
    let device_id = generic_repo::current_device_id();
    if let Some(next) = &next_instance {
        emit_todo_event(
            "todo_tasks",
            next.id,
            &next.uuid,
            DbOp::Insert,
            now,
            &device_id,
        );
        let sub_rows: Vec<(i64, String)> = sqlx::query_as(
            "SELECT id, uuid FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0 ORDER BY position, id",
        )
        .bind(next.id)
        .fetch_all(pool)
        .await?;
        for (sid, suuid) in &sub_rows {
            emit_todo_event("todo_subtasks", *sid, suuid, DbOp::Insert, now, &device_id);
        }
    }
    emit_todo_event(
        "todo_tasks",
        done_task.id,
        &done_task.uuid,
        DbOp::Update,
        now,
        &device_id,
    );

    Ok(CompleteTaskResult {
        task: done_task,
        next_instance,
    })
}

/// emit DbEvent 辅助（todo_api 本模块；与 generic_repo::emit_event 同构但 pub(crate) 不可跨模块用）
fn emit_todo_event(table: &str, id: i64, uuid: &str, op: DbOp, timestamp: i64, device_id: &str) {
    EVENT_BUS.emit(DbEvent {
        table: table.into(),
        op,
        record_id: id,
        record_uuid: uuid.to_string(),
        payload: None,
        device_id: device_id.to_string(),
        timestamp,
    });
}

// ============================================================================
// 单元测试（引擎纯函数 + complete_todo_task 事务语义；桌面端 repeat-task.test.ts 语义随迁）
// ============================================================================

#[cfg(test)]
mod repeat_tests {
    use super::*;
    use crate::api::business_api::{create_todo_subtask, create_todo_task};
    use crate::models::business::TodoTaskCreateInput;

    const DAY: i64 = 86_400_000;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 2026-08-27 本地零点（与桌面用例同一锚点日期）
    fn date_2026_08_27() -> i64 {
        chrono::Local
            .with_ymd_and_hms(2026, 8, 27, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis()
    }

    // ---------- next_repeat_at / plan_next_recurring_instance 纯函数 ----------

    #[test]
    fn daily_advances_one_day() {
        let due = date_2026_08_27();
        let next = next_repeat_at(due, REPEAT_MODE_DAILY, 1, due - DAY).unwrap();
        assert_eq!(next, due + DAY);
    }

    #[test]
    fn weekly_early_completion_keeps_cadence() {
        // 提前完成（from 在 due 之前）：第一步仍按原排程推进
        let due = date_2026_08_27() + 5 * DAY;
        let next = next_repeat_at(due, REPEAT_MODE_WEEKLY, 1, date_2026_08_27()).unwrap();
        assert_eq!(next, due + 7 * DAY);
    }

    #[test]
    fn daily_overdue_fast_forwards_past_now() {
        // 已逾期 16 天：快进到 now 之后最近的一次
        let due = date_2026_08_27() - 16 * DAY;
        let now = date_2026_08_27();
        let next = next_repeat_at(due, REPEAT_MODE_DAILY, 1, now).unwrap();
        assert_eq!(next, now + DAY);
    }

    #[test]
    fn monthly_month_end_clamps_to_short_month() {
        // 1/31 → 2/28（日号超过目标月天数时截断到月末）
        let jan31 = chrono::Local
            .with_ymd_and_hms(2026, 1, 31, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let next = next_repeat_at(jan31, REPEAT_MODE_MONTHLY, 1, jan31).unwrap();
        let d = chrono::Local.timestamp_millis_opt(next).single().unwrap();
        assert_eq!((d.month(), d.day()), (2, 28));
    }

    #[test]
    fn monthly_clamped_chain_does_not_bounce_back() {
        // 截断后链式推进不回弹：1/31 → 2/28 → 3/28
        let jan31 = chrono::Local
            .with_ymd_and_hms(2026, 1, 31, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let feb = next_repeat_at(jan31, REPEAT_MODE_MONTHLY, 1, jan31).unwrap();
        let mar = next_repeat_at(feb, REPEAT_MODE_MONTHLY, 1, feb).unwrap();
        let d = chrono::Local.timestamp_millis_opt(mar).single().unwrap();
        assert_eq!((d.month(), d.day()), (3, 28));
    }

    #[test]
    fn yearly_leap_day_clamps_to_feb_28() {
        // 闰日 2024-02-29 推进一年 → 2025-02-28（而非滚到 03-01）
        let leap = chrono::Local
            .with_ymd_and_hms(2024, 2, 29, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let next = next_repeat_at(
            leap,
            REPEAT_MODE_YEARLY,
            1,
            chrono::Local
                .with_ymd_and_hms(2024, 6, 1, 0, 0, 0)
                .single()
                .unwrap()
                .timestamp_millis(),
        )
        .unwrap();
        let d = chrono::Local.timestamp_millis_opt(next).single().unwrap();
        assert_eq!((d.year(), d.month(), d.day()), (2025, 2, 28));
    }

    #[test]
    fn plan_none_for_no_rule_or_no_due() {
        let task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "任务".into(),
            description: None,
            project_id: None,
            priority: 0,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: None,
            start_date: None,
            repeat_after: 1,
            repeat_mode: 0,
            percent_done: 0.0,
            position: 0.0,
            is_favorite: 0,
            my_day_date: None,
            is_deleted: 0,
            created_at: 0,
            updated_at: 0,
            deleted_at: None,
            version: 1,
        };
        assert!(plan_next_recurring_instance(&task, 0).is_none());
        let mut t2 = task.clone();
        t2.repeat_mode = REPEAT_MODE_DAILY;
        assert!(plan_next_recurring_instance(&t2, 0).is_none());
    }

    #[test]
    fn plan_clones_fields_resets_done_and_shifts_start() {
        let due = date_2026_08_27();
        let task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "晨会".into(),
            description: Some("站会".into()),
            project_id: Some(5),
            priority: 2,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: Some(due),
            start_date: Some(due - DAY),
            repeat_after: 1,
            repeat_mode: REPEAT_MODE_DAILY,
            percent_done: 0.0,
            position: 0.0,
            is_favorite: 1,
            my_day_date: None,
            is_deleted: 0,
            created_at: 0,
            updated_at: 0,
            deleted_at: None,
            version: 1,
        };
        let now = due - DAY;
        let plan = plan_next_recurring_instance(&task, now).unwrap();
        assert_eq!(plan.input.due_date, Some(due + DAY));
        assert_eq!(plan.delta_ms, DAY);
        assert_eq!(plan.input.start_date, Some(due));
        assert_eq!(plan.input.status.as_deref(), Some("pending"));
        assert_eq!(plan.input.done, Some(0));
        assert_eq!(plan.input.done_at, None);
        assert_eq!(plan.input.title, "晨会");
        assert_eq!(plan.input.description.as_deref(), Some("站会"));
        assert_eq!(plan.input.project_id, Some(5));
        assert_eq!(plan.input.priority, Some(2));
        assert_eq!(plan.input.is_favorite, Some(1));
        assert_eq!(plan.input.repeat_mode, Some(REPEAT_MODE_DAILY));
        // my_day_date 不带入下一实例（新实例不属于任何一天的我的一天）
        assert_eq!(plan.input.my_day_date, None);
    }

    #[test]
    fn subtasks_to_clone_filters_soft_deleted_and_sorts() {
        let rows = vec![
            subtask_row(3, "丙", 2.0, 0),
            subtask_row(1, "甲", 0.0, 0),
            subtask_row(2, "乙", 1.0, 1),
        ];
        let cloned = subtasks_to_clone(&rows);
        assert_eq!(
            cloned,
            vec![("甲".to_string(), 0.0), ("丙".to_string(), 2.0)]
        );
    }

    fn subtask_row(id: i64, title: &str, position: f64, is_deleted: i32) -> TodoSubtask {
        TodoSubtask {
            id,
            uuid: format!("s{id}"),
            task_id: 1,
            title: title.into(),
            done: 0,
            done_at: None,
            position,
            is_deleted,
            created_at: 0,
            updated_at: 0,
            deleted_at: None,
            version: 1,
        }
    }

    // ---------- complete_todo_task 事务语义（内存库集成） ----------

    #[tokio::test]
    async fn complete_plain_task_marks_done_without_next_instance() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "普通任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let result = complete_todo_task(&pool, t.id).await.unwrap();
        assert!(result.next_instance.is_none());
        assert_eq!(result.task.done, 1);
        assert_eq!(result.task.status, "done");
        assert!(result.task.done_at.is_some());
    }

    #[tokio::test]
    async fn complete_recurring_creates_next_instance_with_cloned_subtasks() {
        let pool = setup_db().await;
        let due = date_2026_08_27() + 7 * DAY;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "每周任务".into(),
                due_date: Some(due),
                repeat_mode: Some(REPEAT_MODE_WEEKLY),
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_subtask(
            &pool,
            &crate::models::business::TodoSubtaskCreateInput {
                task_id: t.id,
                title: "子任务甲".into(),
                position: Some(0.0),
            },
        )
        .await
        .unwrap();
        create_todo_subtask(
            &pool,
            &crate::models::business::TodoSubtaskCreateInput {
                task_id: t.id,
                title: "子任务乙".into(),
                position: Some(1.0),
            },
        )
        .await
        .unwrap();

        let result = complete_todo_task(&pool, t.id).await.unwrap();
        let next = result.next_instance.expect("应生成下一实例");
        assert_eq!(next.title, "每周任务");
        assert_eq!(next.due_date, Some(due + 7 * DAY));
        assert_eq!(next.done, 0);
        assert_eq!(next.status, "pending");

        // 本实例已标记完成
        assert_eq!(result.task.done, 1);
        assert_eq!(result.task.status, "done");

        // 子任务标题克隆到新实例，完成态重置
        let subs: Vec<TodoSubtask> = sqlx::query_as(
            "SELECT * FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0 ORDER BY position",
        )
        .bind(next.id)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(subs.len(), 2);
        assert_eq!(subs[0].title, "子任务甲");
        assert_eq!(subs[1].title, "子任务乙");
        assert!(subs.iter().all(|s| s.done == 0));
    }

    #[tokio::test]
    async fn complete_idempotent_on_done_task_does_not_advance() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "重复任务".into(),
                due_date: Some(date_2026_08_27()),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let first = complete_todo_task(&pool, t.id).await.unwrap();
        assert!(first.next_instance.is_some());
        // 对已完成任务再完成：幂等，不重复推进
        let second = complete_todo_task(&pool, t.id).await.unwrap();
        assert!(second.next_instance.is_none());

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 2, "两次完成后应有且只有 1 个下一实例");
    }

    #[tokio::test]
    async fn complete_trashed_task_is_rejected() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "回收站任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1 WHERE id = ?")
            .bind(t.id)
            .execute(&pool)
            .await
            .unwrap();
        assert!(complete_todo_task(&pool, t.id).await.is_err());
    }

    #[test]
    fn todo_task_create_input_has_default() {
        // TodoTaskCreateInput 需实现 Default 供测试 ..Default::default() 使用
        let input: TodoTaskCreateInput = Default::default();
        assert_eq!(input.title, "");
    }
}
