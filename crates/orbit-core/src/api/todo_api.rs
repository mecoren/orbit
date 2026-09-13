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

/// 子任务转独立任务（单事务；MS To Do Steps→Task 同款语义）：
/// 软删原子任务行 + 克隆建新任务承接父任务上下文（project_id/priority/
/// due_date——子任务长大了要独立跟踪的 GTD 高频场景，用户少补字段）。
/// percent_done 随软删重算；新任务 position 取父任务列表尾部（不复用
/// 子任务 position 域，避免与任务排序键混淆）。
pub async fn promote_todo_subtask(pool: &SqlitePool, subtask_id: i64) -> CoreResult<TodoTask> {
    let sub: TodoSubtask = generic_repo::get_by_id(pool, "todo_subtasks", subtask_id).await?;
    if sub.is_deleted == 1 {
        return Err(CoreError::Other(format!(
            "子任务 id={subtask_id} 已在回收站，无法转换"
        )));
    }
    let parent: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", sub.task_id).await?;
    let now = chrono::Utc::now().timestamp_millis();

    let mut tx = pool.begin().await?;
    // 1. 软删子任务行
    sqlx::query(
        "UPDATE todo_subtasks SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1 WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(subtask_id)
    .execute(&mut *tx)
    .await?;

    // 2. 尾位 position（同列表项目/批量移动同口径：最大值 + 1，空表兜底 0）
    let max_pos: f64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(position), -1.0) FROM todo_tasks \
         WHERE project_id IS ? AND is_deleted = 0",
    )
    .bind(parent.project_id)
    .fetch_one(&mut *tx)
    .await?;

    // 3. 克隆建新任务：承接父任务的 project/priority/due；完成态子任务
    //    转出后 done=1 保留完成事实（与 done_at 一并迁移）
    let new_uuid = uuid::Uuid::new_v4().to_string();
    let created: TodoTask = sqlx::query_as(
        "INSERT INTO todo_tasks (
            uuid, title, description, project_id, priority, status, done, done_at,
            due_date, start_date, repeat_after, repeat_mode,
            percent_done, position, is_favorite, my_day_date,
            is_deleted, created_at, updated_at, version
        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, 0, NULL, 0, ?, ?, 1)
         RETURNING *",
    )
    .bind(&new_uuid)
    .bind(&sub.title)
    .bind(parent.project_id)
    .bind(parent.priority)
    .bind(if sub.done == 1 { "done" } else { "pending" })
    .bind(sub.done)
    .bind(sub.done_at)
    .bind(parent.due_date)
    .bind(parent.start_date)
    .bind(max_pos + 1.0)
    .bind(now)
    .bind(now)
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;

    // 4. 事件（提交后发）：子任务 Delete + 父任务 Update（percent_done 变化）
    //    + 新任务 Insert
    let device_id = generic_repo::current_device_id();
    emit_todo_event(
        "todo_subtasks",
        sub.id,
        &sub.uuid,
        DbOp::Delete,
        now,
        &device_id,
    );
    emit_todo_event(
        "todo_tasks",
        parent.id,
        &parent.uuid,
        DbOp::Update,
        now,
        &device_id,
    );
    emit_todo_event(
        "todo_tasks",
        created.id,
        &created.uuid,
        DbOp::Insert,
        now,
        &device_id,
    );

    // 5. 父任务 percent_done 重算（软删行不进分母）
    recalc_task_percent_done(pool, parent.id).await?;

    // 活动日志（F6 同款埋点：显式语义动作）
    let _ = crate::api::activity_log_api::log_activity(
        pool,
        created.id,
        &created.title,
        "create",
        &format!(r#"{{"from":"subtask","parent_id":{}}}"#, parent.id),
    )
    .await;

    Ok(created)
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

/// 结束条件类型（todo_tasks.repeat_end_type 列语义一致）
pub const REPEAT_END_NEVER: i32 = 0;
pub const REPEAT_END_ON_DATE: i32 = 1;
pub const REPEAT_END_AFTER_COUNT: i32 = 2;

/// 星期几位掩码：bit0=周一 … bit6=周日（chrono weekday() 周一=0）
pub fn weekday_bit(d: &chrono::DateTime<chrono::Local>) -> u32 {
    1u32 << (d.weekday().num_days_from_monday())
}

/// base 的下一次发生时间（> from）；无规则或快进超限（>5000 步）返回 None。
/// 天/周为固定毫秒跨度；月/年走日历语义（见 advance_calendar_months）。
/// 快进上限按天约 13 年，防异常数据死循环（与桌面端 nextRepeatAt 一致）。
pub fn next_repeat_at(base_ms: i64, mode: i32, after: i64, from_ms: i64) -> Option<i64> {
    next_repeat_at_ex(base_ms, mode, after, 0, from_ms)
}

/// next_repeat_at 扩展版（#34 重复规则升级）：
///
/// `weekdays` 位掩码（bit0=周一…bit6=周日，仅 WEEKLY 且非 0 生效）：
/// 多选星期几时序列语义变为"在掩码内的星期几之间推进"——每次从当前点
/// 前进到下一个命中掩码的日期（跨周自然回绕；间隔 N 周 = 掩码命中的
/// 跨度按 7 天滚动，与 Tasks.org/MS To Do 的 weekly+daysOfWeek 对齐）。
/// 0 = 未指定，回落旧语义（每 N 周的同一星期几）。
///
/// 快进上限语义不变：掩码空转（如掩码=0 的防御）在 5000 步内必命中或返回 None。
pub fn next_repeat_at_ex(
    base_ms: i64,
    mode: i32,
    after: i64,
    weekdays: i32,
    from_ms: i64,
) -> Option<i64> {
    if mode == REPEAT_MODE_NONE {
        return None;
    }
    if mode == REPEAT_MODE_WEEKLY && weekdays != 0 {
        // 掩码序列语义（对齐 Tasks.org/MS Graph weekly+daysOfWeek）：
        // 候选日 D 满足 ①weekday(D) ∈ 掩码 ②周序号(D) ≡ 周序号(锚点) (mod N)。
        // 周序号 = floor(本地日序号 / 7)，锚定自然周对齐；N=1 时即"每周的这几个天"。
        // 逐日扫描最坏 7N 天/步，5000 步上限内覆盖正常间隔。
        let mask = weekdays as u32;
        let n = after.max(1) as i64;
        let mut next = chrono::Local.timestamp_millis_opt(base_ms).single()?;
        let anchor_week = (next.num_days_from_ce() / 7) as i64;
        for _ in 0..5000i64 * n {
            if next.timestamp_millis() > from_ms
                && (mask & weekday_bit(&next)) != 0
                && (((next.num_days_from_ce() / 7) as i64) - anchor_week) % n == 0
            {
                return Some(next.timestamp_millis());
            }
            next += chrono::Duration::days(1);
        }
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

    // 结束条件判定（#34）：到期日已越过结束日 → 序列终结，不再生成下一实例；
    // 按次数：param 存剩余次数，本次完成后剩余 0 → 终结（次数语义 = param 减在
    // 每次推进中，count-1=1 时本次是最后一次）。
    if task.repeat_end_type == REPEAT_END_ON_DATE {
        let end_at = task.repeat_end_param;
        if next_candidate_would_exceed(due, end_at) {
            return None;
        }
    } else if task.repeat_end_type == REPEAT_END_AFTER_COUNT {
        // param=1 表示本次完成后序列终结（剩余最后一次）；0/负值防御性终结
        if task.repeat_end_param <= 1 {
            return None;
        }
    }

    // when done 语义（#34）：from_done=1 时序列锚点从原 due 平移到完成时刻
    // （理发式：迟到三周完成，下次仍在完成后一个完整间隔）；
    // 默认 0 锚定原 due——提前完成不改节奏、逾期快进越过 now（旧语义不变）
    let anchor = if task.repeat_from_done != 0 {
        now_ms
    } else {
        due
    };
    let next_due = if task.repeat_from_done != 0 {
        // 完成日锚定：从 now 起推进一个完整步长（掩码星期几在 now 之后命中的
        // 下一个符合周序号对齐的候选），不复用快进（快进会吞掉"完整间隔"）
        next_full_step_from(
            anchor,
            task.repeat_mode,
            task.repeat_after,
            task.repeat_weekdays,
        )
    } else {
        next_repeat_at_ex(
            due,
            task.repeat_mode,
            task.repeat_after,
            task.repeat_weekdays,
            now_ms,
        )
    }?;
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
            // 重复规则扩展字段随克隆（同一序列语义延续）
            repeat_weekdays: Some(task.repeat_weekdays),
            repeat_end_type: Some(task.repeat_end_type),
            // 次数型：下一实例剩余次数 -1（本次已消耗一次）
            repeat_end_param: Some(if task.repeat_end_type == REPEAT_END_AFTER_COUNT {
                task.repeat_end_param - 1
            } else {
                task.repeat_end_param
            }),
            repeat_from_done: Some(task.repeat_from_done),
            position: None,
            is_favorite: Some(task.is_favorite),
            my_day_date: None,
        },
        delta_ms,
    })
}

/// 结束日判定：due 当天未越过结束日即仍可推进一次（下次 due 可能仍 ≤ 结束日）
/// 下次推进后再由下一次完成时的本判定收口
fn next_candidate_would_exceed(due_ms: i64, end_ms: i64) -> bool {
    due_ms > end_ms
}

/// when done 语义的完整步长推进：从 from 起推进一个完整间隔（不快进）
///
/// 无掩码：DAILY/WEEKLY/MONTHLY/YEARLY 按日历语义加一个步长；
/// 掩码星期几：从 from 起逐日扫描下一个命中掩码且周序号对齐的日期
/// （首候选即可——完整间隔语义下 from 本身不计入）。
fn next_full_step_from(from_ms: i64, mode: i32, after: i64, weekdays: i32) -> Option<i64> {
    if mode == REPEAT_MODE_WEEKLY && weekdays != 0 {
        let mask = weekdays as u32;
        let n = after.max(1) as i64;
        let mut next = chrono::Local.timestamp_millis_opt(from_ms).single()?;
        let anchor_week = (next.num_days_from_ce() / 7) as i64;
        for _ in 0..5000i64 * n {
            next += chrono::Duration::days(1);
            if (mask & weekday_bit(&next)) != 0
                && (((next.num_days_from_ce() / 7) as i64) - anchor_week) % n == 0
            {
                return Some(next.timestamp_millis());
            }
        }
        return None;
    }
    let step = after.max(1) as u32;
    let mut next = chrono::Local.timestamp_millis_opt(from_ms).single()?;
    match mode {
        REPEAT_MODE_DAILY => next += chrono::Duration::days(step as i64),
        REPEAT_MODE_WEEKLY => next += chrono::Duration::days(7 * step as i64),
        REPEAT_MODE_MONTHLY => advance_calendar_months(&mut next, step as i32),
        REPEAT_MODE_YEARLY => advance_calendar_months(&mut next, 12 * step as i32),
        _ => return None,
    }
    Some(next.timestamp_millis())
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

    // 本实例的存活提醒行：完成实例不再提醒（P1#10）——软删原行，
    // 重复任务的行平移 delta 后克隆到下一实例（系列提醒随实例延续，
    // 「不复制提醒」的旧口径废除）。事件在事务提交后统一发射（下方）。
    let old_reminders: Vec<TodoReminder> =
        sqlx::query_as("SELECT * FROM todo_reminders WHERE task_id = ? AND is_deleted = 0")
            .bind(id)
            .fetch_all(pool)
            .await?;
    let new_reminder_ats: Vec<i64> = match &plan {
        None => Vec::new(),
        Some(plan) => old_reminders
            .iter()
            .map(|r| r.remind_at + plan.delta_ms)
            .collect(),
    };
    // 事务内写、提交后发的事件队列（todo_reminders 增删为本命令新增发射点）
    let mut pending_events: Vec<(String, i64, String, DbOp)> = Vec::new();

    let mut tx = pool.begin().await?;
    let mut next_instance: Option<TodoTask> = None;
    if let Some(plan) = &plan {
        let new_uuid = uuid::Uuid::new_v4().to_string();
        let i = &plan.input;
        let created: TodoTask = sqlx::query_as(
            "INSERT INTO todo_tasks (
                uuid, title, description, project_id, priority, status, done, done_at,
                due_date, start_date, repeat_after, repeat_mode,
                repeat_weekdays, repeat_end_type, repeat_end_param, repeat_from_done,
                percent_done, position, is_favorite, my_day_date,
                is_deleted, created_at, updated_at, version
            ) VALUES (?, ?, ?, ?, ?, 'pending', 0, NULL, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, 0, ?, ?, 1)
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
        .bind(i.repeat_weekdays.unwrap_or(0))
        .bind(i.repeat_end_type.unwrap_or(0))
        .bind(i.repeat_end_param.unwrap_or(0))
        .bind(i.repeat_from_done.unwrap_or(0))
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
        // 提醒行平移克隆到下一实例（与 due/start 同 delta；锚点口径一致）。
        // 事件先收集，事务提交后统一发射（提交前发射会让消费者读到未提交数据）
        for remind_at in &new_reminder_ats {
            let rem_uuid = uuid::Uuid::new_v4().to_string();
            let created_reminder: TodoReminder = sqlx::query_as(
                "INSERT INTO todo_reminders (uuid, task_id, remind_at, is_deleted, created_at, updated_at, version)
                 VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
            )
            .bind(&rem_uuid)
            .bind(created.id)
            .bind(*remind_at)
            .bind(now)
            .bind(now)
            .fetch_one(&mut *tx)
            .await?;
            pending_events.push((
                "todo_reminders".to_string(),
                created_reminder.id,
                created_reminder.uuid.clone(),
                DbOp::Insert,
            ));
        }
        next_instance = Some(created);
    }

    // 完成实例的存活提醒行软删（同事务；事件同样延后到提交后）
    for r in &old_reminders {
        sqlx::query(
            "UPDATE todo_reminders SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1 WHERE id = ?",
        )
        .bind(now)
        .bind(now)
        .bind(r.id)
        .execute(&mut *tx)
        .await?;
        pending_events.push((
            "todo_reminders".to_string(),
            r.id,
            r.uuid.clone(),
            DbOp::Delete,
        ));
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
    for (table, record_id, record_uuid, op) in pending_events {
        emit_todo_event(&table, record_id, &record_uuid, op, now, &device_id);
    }

    // 活动日志（F6）：完成动作独立于 update 埋点（complete 是显式语义）；
    // 幂等完成（已 done 再点）不重复记
    if task.done != 1 {
        let _ = crate::api::activity_log_api::log_activity(
            pool,
            done_task.id,
            &done_task.title,
            "complete",
            "{}",
        )
        .await;
    }

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

/// 子任务转独立任务（promote_todo_subtask）引擎测试
#[cfg(test)]
mod promote_subtask_tests {
    use super::*;
    use crate::api::business_api::{create_todo_subtask, create_todo_task, list_todo_tasks};
    use crate::models::business::{ListFilter, TodoSubtaskCreateInput, TodoTaskCreateInput};

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    fn all_filter() -> ListFilter {
        ListFilter {
            page_size: 10_000,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn promote_creates_task_with_parent_context() {
        let pool = setup_db().await;
        let parent = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "父任务".into(),
                project_id: Some(1),
                priority: Some(3),
                due_date: Some(1_700_000_000_000),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: parent.id,
                title: "独立成长的子任务".into(),
                position: None,
            },
        )
        .await
        .unwrap();

        let created = promote_todo_subtask(&pool, sub.id).await.unwrap();
        assert_eq!(created.title, "独立成长的子任务");
        assert_eq!(created.project_id, Some(1));
        assert_eq!(created.priority, 3);
        assert_eq!(created.due_date, Some(1_700_000_000_000));
        assert_eq!(created.done, 0);
        assert_eq!(created.status, "pending");

        // 子任务行已软删（is_deleted=1）且不再出现在父任务子任务列表
        let sub_after: TodoSubtask = generic_repo::get_by_id(&pool, "todo_subtasks", sub.id)
            .await
            .unwrap();
        assert_eq!(sub_after.is_deleted, 1);
    }

    #[tokio::test]
    async fn promote_done_subtask_keeps_done_state() {
        let pool = setup_db().await;
        let parent = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "父".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: parent.id,
                title: "已完成的子任务".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        toggle_todo_subtask_done(&pool, sub.id, true).await.unwrap();

        let created = promote_todo_subtask(&pool, sub.id).await.unwrap();
        assert_eq!(created.done, 1);
        assert_eq!(created.status, "done");
        assert!(created.done_at.is_some());
    }

    #[tokio::test]
    async fn promote_recalls_parent_percent() {
        let pool = setup_db().await;
        let parent = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "进度父".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let s1 = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: parent.id,
                title: "甲".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        let _s2 = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: parent.id,
                title: "乙".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        toggle_todo_subtask_done(&pool, s1.id, true).await.unwrap();

        let parent_before: TodoTask = generic_repo::get_by_id(&pool, "todo_tasks", parent.id)
            .await
            .unwrap();
        assert_eq!(parent_before.percent_done, 50.0);

        // 转走「甲」后只剩「乙」，percent 重算为 0
        let _ = promote_todo_subtask(&pool, s1.id).await.unwrap();
        let parent_after: TodoTask = generic_repo::get_by_id(&pool, "todo_tasks", parent.id)
            .await
            .unwrap();
        assert_eq!(parent_after.percent_done, 0.0);
    }

    #[tokio::test]
    async fn promote_appends_tail_position() {
        let pool = setup_db().await;
        let t1 = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "现有任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let parent = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "父".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: parent.id,
                title: "尾位验证".into(),
                position: None,
            },
        )
        .await
        .unwrap();

        let created = promote_todo_subtask(&pool, sub.id).await.unwrap();
        assert!(created.position > t1.position);
        // 新任务出现在默认聚合里
        let all = list_todo_tasks(&pool, &all_filter()).await.unwrap();
        assert!(all.iter().any(|t| t.id == created.id));
    }
}

#[cfg(test)]
mod repeat_tests {
    use super::*;
    use crate::api::business_api::{create_todo_subtask, create_todo_task};
    use crate::db::repository::generic_repo::create_todo_reminder;
    use crate::models::business::TodoReminderCreateInput;
    use crate::models::business::TodoTaskCreateInput;

    const DAY: i64 = 86_400_000;
    const HOUR: i64 = 3_600_000;

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

    /// 近端锚点：今天本地零点往前 N 天。complete_* 集成用例的 due 锚点
    /// 必须相对真实时间取（固定历史日期会在真实时间越过序列点后触发
    /// 逾期快进翻倍步进，期望值随日历漂移——测试炸弹）
    fn local_midnight_days_ago(days_ago: i64) -> i64 {
        let now = chrono::Local::now();
        let midnight = chrono::Local
            .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
            .single()
            .unwrap();
        midnight.timestamp_millis() - days_ago * DAY
    }

    // ---------- #34 重复规则扩展：星期几掩码 / when done / 结束条件 ----------

    fn weekday_of(ms: i64) -> &'static str {
        let d = chrono::Local.timestamp_millis_opt(ms).single().unwrap();
        match d.weekday() {
            chrono::Weekday::Mon => "一",
            chrono::Weekday::Tue => "二",
            chrono::Weekday::Wed => "三",
            chrono::Weekday::Thu => "四",
            chrono::Weekday::Fri => "五",
            chrono::Weekday::Sat => "六",
            chrono::Weekday::Sun => "日",
        }
    }

    #[test]
    fn weekdays_mask_monday_wednesday_friday() {
        // 2026-08-27 是周四；掩码 bit0|bit2|bit4 = 一/三/五（0b10101 = 21）
        let base = date_2026_08_27();
        // 旧语义（无掩码）：每周 → 9/3（周四）
        let plain = next_repeat_at(base, REPEAT_MODE_WEEKLY, 1, base).unwrap();
        assert_eq!(weekday_of(plain), "四");
        // 掩码语义：下一个命中 一/三/五 的日期（从周四起 → 周五 8/28）
        let masked = next_repeat_at_ex(base, REPEAT_MODE_WEEKLY, 1, 0b10101, base).unwrap();
        assert_eq!(weekday_of(masked), "五");
        // 快进口径：now=9/7（周一，掩码内）但序列点须严格 > now →
        // 跳过当天，命中下一个掩码日周三 9/9（与无掩码版本的 > from 语义一致）
        let now_late = base + DAY * 11; // 9/7 周一
        let late = next_repeat_at_ex(base, REPEAT_MODE_WEEKLY, 1, 0b10101, now_late).unwrap();
        assert_eq!(weekday_of(late), "三");
        // now 落在掩码外（9/8 周二）→ 同样命中周三 9/9
        let late2 =
            next_repeat_at_ex(base, REPEAT_MODE_WEEKLY, 1, 0b10101, now_late + DAY).unwrap();
        assert_eq!(weekday_of(late2), "三");
    }

    #[test]
    fn weekdays_mask_every_two_weeks_alignment() {
        // 每两周 + 周三（bit2=4）：周序号 ≡ 锚点周 (mod 2)——
        // 中间那周的周三必须跳过
        let base = date_2026_08_27(); // 周四
        let n = next_repeat_at_ex(base, REPEAT_MODE_WEEKLY, 2, 0b100, base).unwrap();
        assert_eq!(weekday_of(n), "三");
        // 下一个候选：+14 天的周三（8/27 所在周的下一个周三 = 9/2，
        // 但 +2 周对齐要隔一周 → 9/9？逐日扫描：8/26 的周三（锚点周内、<=from 跳过），
        // 9/2 周三（周序号差 1，非 2 的倍数 → 不命中），9/9 周三（差 2 → 命中）
        let n2 = next_repeat_at_ex(n, REPEAT_MODE_WEEKLY, 2, 0b100, n).unwrap();
        let gap_days = (n2 - n) / DAY;
        assert_eq!(gap_days, 14, "每两周掩码推进必须整两周");
        assert_eq!(weekday_of(n2), "三");
    }

    #[test]
    fn when_done_anchors_full_step_from_completion() {
        // 理发式：每周任务迟到 20 天完成 → 下一实例 = 完成日 + 7 天（非快进口径）
        let due = date_2026_08_27();
        let task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "理发".into(),
            description: None,
            project_id: None,
            priority: 0,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: Some(due),
            start_date: None,
            repeat_after: 1,
            repeat_mode: REPEAT_MODE_WEEKLY,
            repeat_weekdays: 0,
            repeat_end_type: 0,
            repeat_end_param: 0,
            repeat_from_done: 1,
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
        let now = due + DAY * 20;
        let plan = plan_next_recurring_instance(&task, now).unwrap();
        // when done：完整一步 = 完成日 + 7 天（旧语义快进会到 now 之后最近的周四，
        // 即 now+6；两口径同为未来但 when done 不吃快进）
        assert_eq!(plan.input.due_date, Some(now + DAY * 7));
        // 规则扩展字段随克隆
        assert_eq!(plan.input.repeat_from_done, Some(1));
    }

    #[test]
    fn when_done_weekdays_mask_next_masked_day_after_completion() {
        // when done + 掩码：完成日起下一个掩码内的星期几
        let due = date_2026_08_27(); // 周四
        let mut task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "健身".into(),
            description: None,
            project_id: None,
            priority: 0,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: Some(due),
            start_date: None,
            repeat_after: 1,
            repeat_mode: REPEAT_MODE_WEEKLY,
            repeat_weekdays: 0b10101, // 一/三/五
            repeat_end_type: 0,
            repeat_end_param: 0,
            repeat_from_done: 1,
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
        // 周六完成（8/29 是周六）→ 下一个一是 8/31
        let now = due + DAY * 2;
        let plan = plan_next_recurring_instance(&task, now).unwrap();
        assert_eq!(weekday_of(plan.input.due_date.unwrap()), "一");
        // 掩码随克隆
        assert_eq!(plan.input.repeat_weekdays, Some(0b10101));
        let _ = &mut task;
    }

    #[test]
    fn end_on_date_terminates_sequence() {
        let due = date_2026_08_27();
        // 结束日 = due + 3 天：due 未越过 → 可再推进一次；下一实例 due（+7 天）
        // 已超结束日 → 下次完成时终结
        let task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "短期".into(),
            description: None,
            project_id: None,
            priority: 0,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: Some(due),
            start_date: None,
            repeat_after: 1,
            repeat_mode: REPEAT_MODE_DAILY,
            repeat_weekdays: 0,
            repeat_end_type: REPEAT_END_ON_DATE,
            repeat_end_param: due + DAY * 3,
            repeat_from_done: 0,
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
        let plan = plan_next_recurring_instance(&task, due).unwrap();
        assert_eq!(plan.input.due_date, Some(due + DAY));
        // 已越过结束日 → 终结
        let mut overdue = task.clone();
        overdue.due_date = Some(due + DAY * 10);
        assert!(plan_next_recurring_instance(&overdue, due + DAY * 10).is_none());
    }

    #[test]
    fn end_after_count_decrements_and_terminates() {
        let due = date_2026_08_27();
        let task = TodoTask {
            id: 1,
            uuid: "u".into(),
            title: "三次".into(),
            description: None,
            project_id: None,
            priority: 0,
            status: "pending".into(),
            done: 0,
            done_at: None,
            due_date: Some(due),
            start_date: None,
            repeat_after: 1,
            repeat_mode: REPEAT_MODE_DAILY,
            repeat_weekdays: 0,
            repeat_end_type: REPEAT_END_AFTER_COUNT,
            repeat_end_param: 3,
            repeat_from_done: 0,
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
        // 3 → 2（还有下一实例）
        let p1 = plan_next_recurring_instance(&task, due).unwrap();
        assert_eq!(p1.input.repeat_end_param, Some(2));
        // param=1：本次完成后终结
        let mut last = task.clone();
        last.repeat_end_param = 1;
        assert!(plan_next_recurring_instance(&last, due).is_none());
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
            repeat_weekdays: 0,
            repeat_end_type: 0,
            repeat_end_param: 0,
            repeat_from_done: 0,
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
            repeat_weekdays: 0,
            repeat_end_type: 0,
            repeat_end_param: 0,
            repeat_from_done: 0,
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
        let due = local_midnight_days_ago(1) + 7 * DAY;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "每周任务".into(),
                due_date: Some(due),
                repeat_mode: Some(REPEAT_MODE_WEEKLY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
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
                due_date: Some(local_midnight_days_ago(1)),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
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

    // ---------- 完成时提醒行处置（P1#10 修复：完成实例不再提醒） ----------

    /// 本实例的存活提醒行（详情/克隆共用口径：is_deleted=0）
    async fn live_reminders(pool: &SqlitePool, task_id: i64) -> Vec<TodoReminder> {
        sqlx::query_as(
            "SELECT * FROM todo_reminders WHERE task_id = ? AND is_deleted = 0 ORDER BY remind_at, id",
        )
        .bind(task_id)
        .fetch_all(pool)
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn complete_plain_task_soft_deletes_live_reminders() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "带提醒的普通任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: chrono::Utc::now().timestamp_millis() + HOUR,
            },
        )
        .await
        .unwrap();

        let result = complete_todo_task(&pool, t.id).await.unwrap();
        assert_eq!(result.task.done, 1);
        // 完成实例不再提醒：行软删（保留可审计，恢复任务不会复活已过期提醒）
        assert!(
            live_reminders(&pool, t.id).await.is_empty(),
            "完成实例的存活提醒行应被软删"
        );
        let soft_deleted: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM todo_reminders WHERE task_id = ? AND is_deleted = 1",
        )
        .bind(t.id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(soft_deleted, 1, "行应软删而非物理删除");
    }

    #[tokio::test]
    async fn complete_recurring_shifts_reminders_to_next_instance_by_delta() {
        let pool = setup_db().await;
        // 昨天零点 due：真实时间未越过序列点，delta 恒 = 一个步长（7 天）
        let due = local_midnight_days_ago(1);
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "每周任务".into(),
                due_date: Some(due),
                repeat_mode: Some(REPEAT_MODE_WEEKLY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        // due 前一天的 9 点提醒（提醒时间先于 due 的常态场景）
        let remind_at = due - DAY + 9 * HOUR;
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at,
            },
        )
        .await
        .unwrap();

        let result = complete_todo_task(&pool, t.id).await.unwrap();
        let next = result.next_instance.expect("应生成下一实例");
        // 本实例行软删；下一实例按 delta 平移得到新行（系列提醒延续）
        assert!(
            live_reminders(&pool, t.id).await.is_empty(),
            "完成实例的提醒行应软删"
        );
        let next_rows = live_reminders(&pool, next.id).await;
        assert_eq!(next_rows.len(), 1, "下一实例应有一条平移后的提醒行");
        assert_eq!(next_rows[0].remind_at, remind_at + 7 * DAY);
    }

    #[tokio::test]
    async fn complete_idempotent_second_run_keeps_next_instance_reminders() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "重复任务".into(),
                due_date: Some(local_midnight_days_ago(1)),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: local_midnight_days_ago(1) - HOUR,
            },
        )
        .await
        .unwrap();

        let first = complete_todo_task(&pool, t.id).await.unwrap();
        let next = first.next_instance.unwrap();
        // 已完成任务的重复完成：幂等，不重复推进——下一实例的提醒行不被二次复制
        let _ = complete_todo_task(&pool, t.id).await.unwrap();
        assert_eq!(
            live_reminders(&pool, next.id).await.len(),
            1,
            "幂等完成不应再复制提醒行"
        );
    }

    #[test]
    fn todo_task_create_input_has_default() {
        // TodoTaskCreateInput 需实现 Default 供测试 ..Default::default() 使用
        let input: TodoTaskCreateInput = Default::default();
        assert_eq!(input.title, "");
    }
}

// ============================================================================
// 任务一键复制（#37 小而美批次；Vikunja Duplicate / SP+Focalboard Ctrl+D 同款）
// ============================================================================

/// 复制任务：克隆标题/描述/项目/优先级/状态/截止/开始/收藏/重复规则/子任务（标题+顺序，完成态重置）；
/// 不复制提醒/标签/评论/关联/My Day（新实例是独立内容，社交性字段不带走）。
/// 新 position 追加到原任务之后（同项目内紧邻原任务的复制体可感知）。
pub async fn duplicate_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<TodoTask> {
    let src: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    let subtasks: Vec<TodoSubtask> = sqlx::query_as(
        "SELECT * FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0 ORDER BY position, id",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;

    let now = chrono::Utc::now().timestamp_millis();
    let new_uuid = uuid::Uuid::new_v4().to_string();
    // position 落在原任务后 +1（列表手动排序下复制体紧邻原任务）
    let new_position = src.position + 1.0;

    let mut tx = pool.begin().await?;
    let created: TodoTask = sqlx::query_as(
        "INSERT INTO todo_tasks (
            uuid, title, description, project_id, priority, status, done, done_at,
            due_date, start_date, repeat_after, repeat_mode,
            repeat_weekdays, repeat_end_type, repeat_end_param, repeat_from_done,
            percent_done, position, is_favorite, my_day_date,
            is_deleted, created_at, updated_at, version
        ) VALUES (?, ?, ?, ?, ?, 'pending', 0, NULL, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, 0, ?, ?, 1)
        RETURNING *",
    )
    .bind(&new_uuid)
    .bind(format!("{}（副本）", src.title))
    .bind(src.description.as_deref())
    .bind(src.project_id)
    .bind(src.priority)
    .bind(src.due_date)
    .bind(src.start_date)
    .bind(src.repeat_after)
    .bind(src.repeat_mode)
    .bind(src.repeat_weekdays)
    .bind(src.repeat_end_type)
    .bind(src.repeat_end_param)
    .bind(src.repeat_from_done)
    .bind(new_position)
    .bind(src.is_favorite)
    .bind(now)
    .bind(now)
    .fetch_one(&mut *tx)
    .await?;
    for s in &subtasks {
        let sub_uuid = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO todo_subtasks (uuid, task_id, title, done, done_at, position, is_deleted, created_at, updated_at, version)
             VALUES (?, ?, ?, 0, NULL, ?, 0, ?, ?, 1)",
        )
        .bind(&sub_uuid)
        .bind(created.id)
        .bind(&s.title)
        .bind(s.position)
        .bind(now)
        .bind(now)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;

    emit_todo_event(
        "todo_tasks",
        created.id,
        &created.uuid,
        DbOp::Insert,
        now,
        "",
    );
    Ok(created)
}

#[cfg(test)]
mod duplicate_tests {
    use super::*;
    use crate::api::business_api::{create_todo_subtask, create_todo_task};
    use crate::models::business::{TodoSubtaskCreateInput, TodoTaskCreateInput};

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[tokio::test]
    async fn duplicate_clones_fields_and_subtasks_resets_done() {
        let pool = setup_db().await;
        let src = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "周报".into(),
                description: Some("模板内容".into()),
                project_id: None,
                priority: Some(3),
                status: None,
                done: None,
                done_at: None,
                due_date: Some(1_800_000_000_000),
                start_date: None,
                repeat_after: Some(1),
                repeat_mode: Some(1),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                position: None,
                is_favorite: Some(1),
                my_day_date: None,
            },
        )
        .await
        .unwrap();
        create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: src.id,
                title: "步骤一".into(),
                position: None,
            },
        )
        .await
        .unwrap();

        let copy = duplicate_todo_task(&pool, src.id).await.unwrap();
        // 标题加副本后缀；其余内容字段克隆
        assert_eq!(copy.title, "周报（副本）");
        assert_eq!(copy.description.as_deref(), Some("模板内容"));
        assert_eq!(copy.priority, 3);
        assert_eq!(copy.due_date, src.due_date);
        assert_eq!(copy.repeat_mode, 1);
        assert_eq!(copy.is_favorite, 1);
        // 新实例未完成、独立 uuid、position 紧邻原任务
        assert_eq!(copy.done, 0);
        assert_ne!(copy.uuid, src.uuid);
        assert!((copy.position - src.position - 1.0).abs() < 1e-9);

        // 子任务复制标题（完成态重置；新 task_id）
        let subs: Vec<TodoSubtask> =
            sqlx::query_as("SELECT * FROM todo_subtasks WHERE task_id = ? AND is_deleted = 0")
                .bind(copy.id)
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].title, "步骤一");
        assert_eq!(subs[0].done, 0);
    }
}

// ============================================================================
// 提醒轮询共享口径（桌面 notification_scheduler + 移动 events 双端复用）
// ============================================================================

/// 到期提醒行（轮询扫描口径统一提取）：
/// `is_deleted=0 AND remind_at <= now AND now - remind_at <= 24h`，
/// 且**任务未完成、未进回收站**（P1#10 修复：已完成实例不再提醒——
/// 完成命令已软删其提醒行，此处过滤兜住历史遗留与云同步落库的僵尸行）。
///
/// limit 传批次上限（防陈旧堆积一次性轰炸，调用方各自常量）。
pub async fn list_due_reminders(
    pool: &SqlitePool,
    now_ms: i64,
    window_ms: i64,
    limit: i64,
) -> CoreResult<Vec<DueReminderRow>> {
    let rows = sqlx::query_as::<_, DueReminderRow>(
        "SELECT r.id, r.task_id, t.title, r.remind_at \
         FROM todo_reminders r \
         JOIN todo_tasks t ON t.id = r.task_id \
         WHERE r.is_deleted = 0 AND t.is_deleted = 0 AND t.done = 0 \
           AND r.remind_at <= ?1 AND ?1 - r.remind_at <= ?2 \
         ORDER BY r.remind_at ASC LIMIT ?3",
    )
    .bind(now_ms)
    .bind(window_ms)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 到期提醒行（id/标题/时刻——两壳通知通道的最小载荷）
#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct DueReminderRow {
    pub id: i64,
    pub task_id: i64,
    pub title: String,
    pub remind_at: i64,
}

/// 到期后的提醒处置（原桌面端前端 JS 续排逻辑下沉引擎，窗口隐藏也照常）：
///
/// - 重复任务：删旧建新排下一次（锚点 = 原 remind_at 快进越过 now，不漂移）；
/// - 防雪球守卫：任务已存在**其他**未来提醒（推迟产物或用户手排）时只清理
///   不克隆，避免「原系列 + 推迟系列」平行滚动；
/// - 非重复任务 / 已删任务：只清理不续排；
/// - 全部软删/新建语义与前端 snooze 相同（todo_reminders 无 update 路径）。
///
/// 返回值仅供调试/日志，失败由调用方决定是否静默。
pub async fn advance_fired_reminder(
    pool: &SqlitePool,
    reminder: &DueReminderRow,
) -> CoreResult<bool> {
    let now = chrono::Utc::now().timestamp_millis();

    // 行已消失（并发清理/用户手删）：软删幂等跳过（软删 UPDATE 无行不报错）
    let task: Option<TodoTask> = sqlx::query_as("SELECT * FROM todo_tasks WHERE id = ?")
        .bind(reminder.task_id)
        .fetch_optional(pool)
        .await?;
    let Some(task) = task else {
        return Ok(false);
    };

    // 续排判定：任务存活且未完成、带重复规则、能算出下一次
    let next = if task.is_deleted == 0 && task.done == 0 {
        next_repeat_at_ex(
            reminder.remind_at,
            task.repeat_mode,
            task.repeat_after,
            task.repeat_weekdays,
            now,
        )
    } else {
        None
    };

    // 软删原行（删旧；行不存在时 UPDATE 静默无操作——调用方轮询幂等重扫）
    let row: Option<TodoReminder> =
        sqlx::query_as("SELECT * FROM todo_reminders WHERE id = ? AND is_deleted = 0")
            .bind(reminder.id)
            .fetch_optional(pool)
            .await?;
    if let Some(row) = row {
        soft_delete_reminder_row(pool, &row, now).await?;
    }

    let Some(next) = next else {
        return Ok(false); // 非重复/已完成/已删：只清理不续排
    };

    // 防雪球：本行不再是唯一排程时只清理不克隆
    let has_other_future: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM todo_reminders \
         WHERE task_id = ? AND is_deleted = 0 AND remind_at > ? AND id != ?",
    )
    .bind(reminder.task_id)
    .bind(now)
    .bind(reminder.id)
    .fetch_one(pool)
    .await?;
    if has_other_future > 0 {
        return Ok(false);
    }

    generic_repo::create_todo_reminder(
        pool,
        &TodoReminderCreateInput {
            task_id: reminder.task_id,
            remind_at: next,
        },
    )
    .await?;
    Ok(true)
}

/// 软删单条提醒行 + Delete 事件（todo_api 本模块内联写法；与
/// generic_repo::soft_delete_by_id 同构——该函数按表名拼接 SQL，
/// 这里直接绑定免 format）
async fn soft_delete_reminder_row(
    pool: &SqlitePool,
    row: &TodoReminder,
    now_ms: i64,
) -> CoreResult<()> {
    sqlx::query(
        "UPDATE todo_reminders SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1 WHERE id = ?",
    )
    .bind(now_ms)
    .bind(now_ms)
    .bind(row.id)
    .execute(pool)
    .await?;
    let device_id = generic_repo::current_device_id();
    EVENT_BUS.emit(DbEvent::delete(
        "todo_reminders",
        row.id,
        &row.uuid,
        &device_id,
    ));
    Ok(())
}

#[cfg(test)]
mod reminder_poll_tests {
    use super::*;
    use crate::api::business_api::create_todo_task;
    use crate::db::repository::generic_repo::create_todo_reminder;
    use crate::models::business::{TodoReminderCreateInput, TodoTaskCreateInput};

    const DAY: i64 = 86_400_000;
    const HOUR: i64 = 3_600_000;
    const DAY_WINDOW: i64 = DAY;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn live_reminders(pool: &SqlitePool, task_id: i64) -> Vec<TodoReminder> {
        sqlx::query_as(
            "SELECT * FROM todo_reminders WHERE task_id = ? AND is_deleted = 0 ORDER BY remind_at, id",
        )
        .bind(task_id)
        .fetch_all(pool)
        .await
        .unwrap()
    }

    async fn due_rows(pool: &SqlitePool, now: i64) -> Vec<DueReminderRow> {
        list_due_reminders(pool, now, DAY_WINDOW, 100)
            .await
            .unwrap()
    }

    // ---------- list_due_reminders：过滤口径 ----------

    #[tokio::test]
    async fn due_query_excludes_done_and_trashed_tasks() {
        let pool = setup_db().await;
        let now = chrono::Utc::now().timestamp_millis();

        let live = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "正常".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let done = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "已完成".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let trashed = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "回收站".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        for t in [&live, &done, &trashed] {
            create_todo_reminder(
                &pool,
                &TodoReminderCreateInput {
                    task_id: t.id,
                    remind_at: now - HOUR,
                },
            )
            .await
            .unwrap();
        }
        sqlx::query("UPDATE todo_tasks SET done = 1 WHERE id = ?")
            .bind(done.id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1 WHERE id = ?")
            .bind(trashed.id)
            .execute(&pool)
            .await
            .unwrap();

        let rows = due_rows(&pool, now).await;
        let ids: Vec<i64> = rows.iter().map(|r| r.task_id).collect();
        assert_eq!(ids, vec![live.id], "已完成/回收站任务的提醒不应到期触发");
    }

    #[tokio::test]
    async fn due_query_respects_window_and_future_rows() {
        let pool = setup_db().await;
        let now = chrono::Utc::now().timestamp_millis();

        let past_window = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "超24h".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let future = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "未来".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let due = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "到期".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: past_window.id,
                remind_at: now - DAY - HOUR,
            },
        )
        .await
        .unwrap();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: future.id,
                remind_at: now + HOUR,
            },
        )
        .await
        .unwrap();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: due.id,
                remind_at: now - HOUR,
            },
        )
        .await
        .unwrap();

        let rows = due_rows(&pool, now).await;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].task_id, due.id);
    }

    // ---------- advance_fired_reminder：续排/清理语义 ----------

    fn due_row_of(r: &TodoReminder, title: &str) -> DueReminderRow {
        DueReminderRow {
            id: r.id,
            task_id: r.task_id,
            title: title.into(),
            remind_at: r.remind_at,
        }
    }

    #[tokio::test]
    async fn advance_recurring_task_rolls_next_in_series() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "每日任务".into(),
                due_date: Some(chrono::Utc::now().timestamp_millis()),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: now - HOUR,
            },
        )
        .await
        .unwrap();
        let fired = live_reminders(&pool, t.id).await.remove(0);

        let rolled = advance_fired_reminder(&pool, &due_row_of(&fired, "每日任务"))
            .await
            .unwrap();
        assert!(rolled, "重复任务到期应续排");
        let rows = live_reminders(&pool, t.id).await;
        assert_eq!(rows.len(), 1, "删旧建新：仍只有一条存活行");
        assert!(rows[0].remind_at > now, "新行应在未来");
        assert_eq!(
            rows[0].remind_at,
            fired.remind_at + DAY,
            "锚点=原 remind_at 推进一档"
        );
    }

    #[tokio::test]
    async fn advance_plain_task_only_cleans() {
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
        let now = chrono::Utc::now().timestamp_millis();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: now - HOUR,
            },
        )
        .await
        .unwrap();
        let fired = live_reminders(&pool, t.id).await.remove(0);

        let rolled = advance_fired_reminder(&pool, &due_row_of(&fired, "普通任务"))
            .await
            .unwrap();
        assert!(!rolled, "非重复任务只清理不续排");
        assert!(live_reminders(&pool, t.id).await.is_empty(), "原行应软删");
    }

    #[tokio::test]
    async fn advance_skips_clone_when_other_future_exists() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "重复任务".into(),
                due_date: Some(chrono::Utc::now().timestamp_millis()),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: now - HOUR,
            },
        )
        .await
        .unwrap();
        // 用户手排的另一条未来提醒（推迟产物同型）
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: now + 2 * HOUR,
            },
        )
        .await
        .unwrap();
        let fired = live_reminders(&pool, t.id).await.remove(0);

        let rolled = advance_fired_reminder(&pool, &due_row_of(&fired, "重复任务"))
            .await
            .unwrap();
        assert!(!rolled, "防雪球：存在其他未来提醒时只清理不克隆");
        let rows = live_reminders(&pool, t.id).await;
        assert_eq!(rows.len(), 1, "只剩用户手排的未来行");
        assert_eq!(rows[0].remind_at, now + 2 * HOUR);
    }

    #[tokio::test]
    async fn advance_done_task_only_cleans() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "已完成重复任务".into(),
                due_date: Some(chrono::Utc::now().timestamp_millis()),
                repeat_mode: Some(REPEAT_MODE_DAILY),
                repeat_weekdays: None,
                repeat_end_type: None,
                repeat_end_param: None,
                repeat_from_done: None,
                repeat_after: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at: now - HOUR,
            },
        )
        .await
        .unwrap();
        sqlx::query("UPDATE todo_tasks SET done = 1 WHERE id = ?")
            .bind(t.id)
            .execute(&pool)
            .await
            .unwrap();
        let fired = live_reminders(&pool, t.id).await.remove(0);

        let rolled = advance_fired_reminder(&pool, &due_row_of(&fired, "已完成重复任务"))
            .await
            .unwrap();
        assert!(!rolled, "已完成任务不续排（P1#10）");
        assert!(live_reminders(&pool, t.id).await.is_empty(), "僵尸行清理");
    }
}

// ============================================================================
// 谓词下推 SQL 集成测试（2026-09-12 F5：ListFilter 六键 → list_todo_tasks）
// ============================================================================

#[cfg(test)]
mod predicate_pushdown_tests {
    use super::*;
    use crate::api::business_api::{create_todo_project, create_todo_task, list_todo_tasks};
    use crate::models::business::TodoTaskCreateInput;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 建一条任务（快捷参数）；返回 id
    async fn mk(pool: &SqlitePool, title: &str, f: impl FnOnce(&mut TodoTaskCreateInput)) -> i64 {
        let mut input = TodoTaskCreateInput {
            title: title.into(),
            ..Default::default()
        };
        f(&mut input);
        create_todo_task(pool, &input).await.unwrap().id
    }

    #[tokio::test]
    async fn done_predicate_filters_sql_side() {
        let pool = setup_db().await;
        let a = mk(&pool, "未完成甲", |_| {}).await;
        mk(&pool, "已完成乙", |i| {
            i.done = Some(1);
            i.status = Some("done".into());
        })
        .await;

        // done=false：SQL 侧只返未完成
        let undone = list_todo_tasks(
            &pool,
            &ListFilter {
                done: Some(false),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(undone.len(), 1);
        assert_eq!(undone[0].id, a);

        // done=true：只返已完成
        let done = list_todo_tasks(
            &pool,
            &ListFilter {
                done: Some(true),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(done.len(), 1);
        assert_eq!(done[0].title, "已完成乙");

        // 无谓词：全量
        let all = list_todo_tasks(
            &pool,
            &ListFilter {
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(all.len(), 2);
    }

    #[tokio::test]
    async fn status_priority_project_predicates() {
        let pool = setup_db().await;
        let _ = mk(&pool, "低优", |i| i.priority = Some(1)).await;
        let _ = mk(&pool, "高优进行中", |i| {
            i.priority = Some(4);
            i.status = Some("doing".into());
        })
        .await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "项目甲".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        let in_proj = mk(&pool, "项目内高优", |i| {
            i.project_id = Some(p.id);
            i.priority = Some(3);
        })
        .await;

        // status=doing + priority_min=3 → 只剩「高优进行中」
        let both = list_todo_tasks(
            &pool,
            &ListFilter {
                status: Some("doing".into()),
                priority_min: Some(3),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(both.len(), 1);
        assert_eq!(both[0].title, "高优进行中");

        // project_id → 只剩项目内任务
        let by_proj = list_todo_tasks(
            &pool,
            &ListFilter {
                project_id: Some(p.id),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(by_proj.len(), 1);
        assert_eq!(by_proj[0].id, in_proj);
    }

    #[tokio::test]
    async fn favorite_and_my_day_predicates() {
        let pool = setup_db().await;
        let fav = mk(&pool, "星标任务", |i| i.is_favorite = Some(1)).await;
        let zero = 1_789_142_400_000_i64; // 任意零点（调用方算好传入）
        let my_day = mk(&pool, "我的一天任务", |i| i.my_day_date = Some(zero)).await;
        mk(&pool, "普通任务", |_| {}).await;

        let favs = list_todo_tasks(
            &pool,
            &ListFilter {
                favorite_only: Some(true),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(favs.len(), 1);
        assert_eq!(favs[0].id, fav);

        let today = list_todo_tasks(
            &pool,
            &ListFilter {
                my_day_today: Some(zero),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(today.len(), 1);
        assert_eq!(today[0].id, my_day);

        // 我的一天窗口外零点不命中（视图语义：昨天加入自动退出）
        let none = list_todo_tasks(
            &pool,
            &ListFilter {
                my_day_today: Some(zero + 86_400_000),
                page_size: 100,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert!(none.is_empty());
    }
}
