//! business_api — 业务编排层（Orbit MVP：todo 段 + cfg 必需段 + 备份辅助）
//!
//! 平移自 wait-home wait_core（02 文档 §四 A/B 类）。
//! 白名单常量统一收口到 db::sync_registry（03 文档 §六），本文件经 pub use 转发。

pub use crate::db::sync_registry::FULL_BACKUP_TABLES;

use chrono::TimeZone;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::api::activity_log_api;
use crate::db::repository::generic_repo;
use crate::db::repository::import_type_validator::normalize_import_fields;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::*;

// =============================================================================
// todo_projects / todo_tasks / todo_subtasks / todo_labels / todo_task_labels
// todo_comments / todo_task_relations / todo_reminders（Vikunja 化重构，8 张表）
// =============================================================================

// =============================================================================
// todo_projects / todo_tasks / todo_subtasks / todo_labels / todo_task_labels
// todo_comments / todo_task_relations / todo_reminders
// （Vikunja 化重构，8 张表）
// =============================================================================

// ---------- todo_projects ----------
/// 列出用户的 todo 项目，按 sort_order 升序（同序则按 id 升序作为稳定排序）。
///
/// 不走 generic_repo::list（统一按 updated_at DESC），因为项目列表的展示顺序
/// 由用户拖拽结果决定（sort_order 字段），updated_at 排序会让新建/重排后的项目跳到最前。
/// 默认排除已归档项目（is_archived=1）——归档区入口走 list_archived_todo_projects。
pub async fn list_todo_projects(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoProject>> {
    let page_size = if filter.page_size == 0 {
        20
    } else {
        filter.page_size
    } as i32;
    let offset = filter
        .page
        .saturating_sub(1)
        .saturating_mul(filter.page_size) as i32;

    // 关键词过滤：与 generic_repo::list 保持一致（按 title/description LIKE）
    let keyword_clause = if let Some(kw) = filter.keyword.as_deref() {
        if !kw.is_empty() {
            " AND (title LIKE ? OR description LIKE ?)".to_string()
        } else {
            String::new()
        }
    } else {
        String::new()
    };

    let sql = format!(
        "SELECT * FROM todo_projects WHERE is_deleted = 0 AND is_archived = 0{} \
         ORDER BY sort_order ASC, id ASC LIMIT ? OFFSET ?",
        keyword_clause
    );

    let mut q = sqlx::query_as::<_, TodoProject>(&sql);
    if let Some(kw) = filter.keyword.as_deref()
        && !kw.is_empty()
    {
        let pattern = format!("%{}%", kw);
        q = q.bind(pattern.clone()).bind(pattern);
    }
    q = q.bind(page_size).bind(offset);

    Ok(q.fetch_all(pool).await?)
}

/// 归档项目列表（is_archived=1，按归档时间倒序——最近归档在前）。
/// 侧栏「已归档」折叠区数据源；任务本身仍可经搜索/详情直达。
pub async fn list_archived_todo_projects(pool: &SqlitePool) -> CoreResult<Vec<TodoProject>> {
    let rows = sqlx::query_as::<_, TodoProject>(
        "SELECT * FROM todo_projects WHERE is_deleted = 0 AND is_archived = 1 \
         ORDER BY updated_at DESC, id DESC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}
pub async fn get_todo_project(pool: &SqlitePool, id: i64) -> CoreResult<TodoProject> {
    generic_repo::get_by_id(pool, "todo_projects", id).await
}
pub async fn create_todo_project(
    pool: &SqlitePool,
    input: &TodoProjectCreateInput,
) -> CoreResult<TodoProject> {
    generic_repo::create_todo_project(pool, input).await
}
pub async fn update_todo_project(
    pool: &SqlitePool,
    id: i64,
    input: &TodoProjectUpdateInput,
) -> CoreResult<TodoProject> {
    generic_repo::update_todo_project(pool, id, input).await
}
pub async fn delete_todo_project(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoProject = generic_repo::get_by_id(pool, "todo_projects", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_projects", id, &t.uuid).await
}

// ---------- todo_tasks ----------
pub async fn list_todo_tasks(pool: &SqlitePool, filter: &ListFilter) -> CoreResult<Vec<TodoTask>> {
    generic_repo::list(pool, "todo_tasks", filter).await
}
pub async fn get_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<TodoTask> {
    generic_repo::get_by_id(pool, "todo_tasks", id).await
}
pub async fn create_todo_task(
    pool: &SqlitePool,
    input: &TodoTaskCreateInput,
) -> CoreResult<TodoTask> {
    let t = generic_repo::create_todo_task(pool, input).await?;
    // 活动日志（F6）：失败不阻断主流程（轨迹缺失可接受，写路径必须成功）
    let _ = activity_log_api::log_activity(pool, t.id, &t.title, "create", "{}").await;
    Ok(t)
}
pub async fn update_todo_task(
    pool: &SqlitePool,
    id: i64,
    input: &TodoTaskUpdateInput,
) -> CoreResult<TodoTask> {
    let before: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    let t = generic_repo::update_todo_task(pool, id, input).await?;
    // 活动日志（F6）：记录实际发生变化的字段集 + 前后值快照（比较前后行——
    // 前端部分更新的 Option 语义下未命中字段的 UPDATE 不产生 diff）
    let changes = changed_task_values(pool, &before, &t).await;
    if !changes.is_empty() {
        let detail = serde_json::json!({
            "fields": changes.iter().map(|(f, ..)| *f).collect::<Vec<_>>(),
            "changes": changes
                .iter()
                .map(|(f, from, to)| serde_json::json!({ "field": f, "from": from, "to": to }))
                .collect::<Vec<_>>(),
        })
        .to_string();
        let _ = activity_log_api::log_activity(pool, t.id, &t.title, "update", &detail).await;
    }
    Ok(t)
}
pub async fn delete_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_tasks", id, &t.uuid).await?;
    let _ = activity_log_api::log_activity(pool, t.id, &t.title, "delete", "{}").await;
    Ok(())
}

/// 长文本快照截断（历史行可读口径；全文仍在业务表，60 字外折叠为 …）
fn snapshot_text(s: &str) -> String {
    let mut it = s.chars();
    let head: String = it.by_ref().take(60).collect();
    if it.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}

/// ms 时间戳 → 本地 yyyy-MM-dd 可读串（NULL → null；按本地日界口径换算）
fn snapshot_day(ms: Option<i64>) -> serde_json::Value {
    ms.and_then(|t| chrono::Local.timestamp_millis_opt(t).single())
        .map(|d| serde_json::Value::String(d.format("%Y-%m-%d").to_string()))
        .unwrap_or(serde_json::Value::Null)
}

/// ms 时间戳 → 本地 yyyy-MM-dd HH:mm（完成时刻等带时分的场景）
pub(crate) fn snapshot_dt(ms: Option<i64>) -> serde_json::Value {
    ms.and_then(|t| chrono::Local.timestamp_millis_opt(t).single())
        .map(|d| serde_json::Value::String(d.format("%Y-%m-%d %H:%M").to_string()))
        .unwrap_or(serde_json::Value::Null)
}

/// 项目名快照（写入端解析——项目后续改名/删除历史仍可读；查不到落 null）
async fn snapshot_project(pool: &SqlitePool, id: Option<i64>) -> serde_json::Value {
    let Some(i) = id else {
        return serde_json::Value::Null;
    };
    sqlx::query_scalar::<_, String>("SELECT title FROM todo_projects WHERE id = ?")
        .bind(i)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten()
        .map(serde_json::Value::String)
        .unwrap_or(serde_json::Value::Null)
}

/// 重复规则六字段整体快照（repeat_rule 伪字段的 from/to 值；前端按
/// repeatLabel 口径渲染，字段名与 TodoTask 列对应）
fn repeat_snapshot(t: &TodoTask) -> serde_json::Value {
    serde_json::json!({
        "mode": t.repeat_mode,
        "after": t.repeat_after,
        "weekdays": t.repeat_weekdays,
        "end_type": t.repeat_end_type,
        "end_param": t.repeat_end_param,
        "from_done": t.repeat_from_done,
    })
}

/// 比较任务前后行，产出变更集 (字段名, 前值, 后值)；顺序与 TodoTask 字段
/// 声明序一致（测试锁定）。值预格式化为可读快照：日期→本地日串、项目→名称、
/// 长文本截断；枚举/数值保留原值由前端按共享常量口径格式化（单口径原则）
async fn changed_task_values(
    pool: &SqlitePool,
    before: &TodoTask,
    after: &TodoTask,
) -> Vec<(&'static str, serde_json::Value, serde_json::Value)> {
    let mut out: Vec<(&'static str, serde_json::Value, serde_json::Value)> = Vec::new();
    if before.title != after.title {
        out.push((
            "title",
            serde_json::Value::String(snapshot_text(&before.title)),
            serde_json::Value::String(snapshot_text(&after.title)),
        ));
    }
    if before.description != after.description {
        out.push((
            "description",
            before
                .description
                .as_deref()
                .map(|s| serde_json::Value::String(snapshot_text(s)))
                .unwrap_or(serde_json::Value::Null),
            after
                .description
                .as_deref()
                .map(|s| serde_json::Value::String(snapshot_text(s)))
                .unwrap_or(serde_json::Value::Null),
        ));
    }
    if before.project_id != after.project_id {
        out.push((
            "project_id",
            snapshot_project(pool, before.project_id).await,
            snapshot_project(pool, after.project_id).await,
        ));
    }
    if before.priority != after.priority {
        out.push((
            "priority",
            serde_json::json!(before.priority),
            serde_json::json!(after.priority),
        ));
    }
    if before.status != after.status {
        out.push((
            "status",
            serde_json::json!(&before.status),
            serde_json::json!(&after.status),
        ));
    }
    if before.done != after.done {
        out.push((
            "done",
            serde_json::json!(before.done),
            serde_json::json!(after.done),
        ));
    }
    if before.done_at != after.done_at {
        out.push((
            "done_at",
            snapshot_dt(before.done_at),
            snapshot_dt(after.done_at),
        ));
    }
    if before.due_date != after.due_date {
        out.push((
            "due_date",
            snapshot_dt(before.due_date),
            snapshot_dt(after.due_date),
        ));
    }
    if before.start_date != after.start_date {
        out.push((
            "start_date",
            snapshot_day(before.start_date),
            snapshot_day(after.start_date),
        ));
    }
    if before.repeat_mode != after.repeat_mode
        || before.repeat_after != after.repeat_after
        || before.repeat_weekdays != after.repeat_weekdays
        || before.repeat_end_type != after.repeat_end_type
        || before.repeat_end_param != after.repeat_end_param
        || before.repeat_from_done != after.repeat_from_done
    {
        // 六字段合并为一条伪字段变更（单改 repeat_after 不配 mode 无意义）；
        // 值快照为对象，前端 repeatLabel 单口径渲染完整规则串
        out.push((
            "repeat_rule",
            repeat_snapshot(before),
            repeat_snapshot(after),
        ));
    }
    if before.percent_done != after.percent_done {
        out.push((
            "percent_done",
            serde_json::json!(before.percent_done),
            serde_json::json!(after.percent_done),
        ));
    }
    if before.position != after.position {
        out.push((
            "position",
            serde_json::json!(before.position),
            serde_json::json!(after.position),
        ));
    }
    if before.is_favorite != after.is_favorite {
        out.push((
            "is_favorite",
            serde_json::json!(before.is_favorite),
            serde_json::json!(after.is_favorite),
        ));
    }
    if before.my_day_date != after.my_day_date {
        out.push((
            "my_day_date",
            snapshot_day(before.my_day_date),
            snapshot_day(after.my_day_date),
        ));
    }
    out
}

// ---------- todo_subtasks ----------
pub async fn list_todo_subtasks(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoSubtask>> {
    generic_repo::list(pool, "todo_subtasks", filter).await
}
pub async fn get_todo_subtask(pool: &SqlitePool, id: i64) -> CoreResult<TodoSubtask> {
    generic_repo::get_by_id(pool, "todo_subtasks", id).await
}
pub async fn create_todo_subtask(
    pool: &SqlitePool,
    input: &TodoSubtaskCreateInput,
) -> CoreResult<TodoSubtask> {
    let row = generic_repo::create_todo_subtask(pool, input).await?;
    log_target_activity(pool, row.task_id, "subtask_add", &row.title).await;
    Ok(row)
}
pub async fn update_todo_subtask(
    pool: &SqlitePool,
    id: i64,
    input: &TodoSubtaskUpdateInput,
) -> CoreResult<TodoSubtask> {
    let before: TodoSubtask = generic_repo::get_by_id(pool, "todo_subtasks", id).await?;
    let after = generic_repo::update_todo_subtask(pool, id, input).await?;
    if before.title != after.title {
        // 改名轨迹：target 直接给「旧 → 新」对照串
        let target = format!(
            "{} → {}",
            snapshot_text(&before.title),
            snapshot_text(&after.title)
        );
        log_target_activity(pool, after.task_id, "subtask_rename", &target).await;
    }
    Ok(after)
}
pub async fn delete_todo_subtask(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoSubtask = generic_repo::get_by_id(pool, "todo_subtasks", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_subtasks", id, &t.uuid).await?;
    log_target_activity(pool, t.task_id, "subtask_delete", &t.title).await;
    Ok(())
}

// ---------- todo_labels ----------
pub async fn list_todo_labels(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoLabel>> {
    generic_repo::list(pool, "todo_labels", filter).await
}
pub async fn get_todo_label(pool: &SqlitePool, id: i64) -> CoreResult<TodoLabel> {
    generic_repo::get_by_id(pool, "todo_labels", id).await
}
pub async fn create_todo_label(
    pool: &SqlitePool,
    input: &TodoLabelCreateInput,
) -> CoreResult<TodoLabel> {
    generic_repo::create_todo_label(pool, input).await
}
pub async fn update_todo_label(
    pool: &SqlitePool,
    id: i64,
    input: &TodoLabelUpdateInput,
) -> CoreResult<TodoLabel> {
    generic_repo::update_todo_label(pool, id, input).await
}
pub async fn delete_todo_label(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoLabel = generic_repo::get_by_id(pool, "todo_labels", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_labels", id, &t.uuid).await
}

// ---------- todo_task_labels ----------
pub async fn list_todo_task_labels(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoTaskLabel>> {
    generic_repo::list(pool, "todo_task_labels", filter).await
}
pub async fn get_todo_task_label(pool: &SqlitePool, id: i64) -> CoreResult<TodoTaskLabel> {
    generic_repo::get_by_id(pool, "todo_task_labels", id).await
}
pub async fn create_todo_task_label(
    pool: &SqlitePool,
    input: &TodoTaskLabelCreateInput,
) -> CoreResult<TodoTaskLabel> {
    let row = generic_repo::create_todo_task_label(pool, input).await?;
    log_label_change(pool, row.task_id, row.label_id, "label_add").await;
    Ok(row)
}
pub async fn delete_todo_task_label(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let row = generic_repo::get_by_id::<TodoTaskLabel>(pool, "todo_task_labels", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_task_labels", id, &row.uuid).await?;
    log_label_change(pool, row.task_id, row.label_id, "label_remove").await;
    Ok(())
}

/// 任务标题查询（历史埋点用；软删行也可查，墓碑期轨迹仍归属该任务）
pub(crate) async fn task_title_of(pool: &SqlitePool, task_id: i64) -> Option<String> {
    sqlx::query_scalar::<_, String>("SELECT title FROM todo_tasks WHERE id = ?")
        .bind(task_id)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten()
}

/// 通用从属对象历史埋点（子任务/评论/关联/提醒）：detail 统一
/// `{"target": 可读名}`；任务行查不到则跳过（轨迹缺失可接受，不阻断主流程）
pub(crate) async fn log_target_activity(
    pool: &SqlitePool,
    task_id: i64,
    action: &str,
    target: &str,
) {
    if let Some(tt) = task_title_of(pool, task_id).await {
        let detail = serde_json::json!({ "target": target }).to_string();
        let _ = activity_log_api::log_activity(pool, task_id, &tt, action, &detail).await;
    }
}

/// 标签挂/摘历史轨迹（label_add / label_remove）：任务标题 + 标签名写入端
/// 快照；任务或标签行查不到则跳过（轨迹缺失可接受，不阻断主流程）
async fn log_label_change(pool: &SqlitePool, task_id: i64, label_id: i64, action: &str) {
    let label_title = sqlx::query_scalar::<_, String>("SELECT title FROM todo_labels WHERE id = ?")
        .bind(label_id)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();
    if let Some(lt) = label_title {
        let detail = serde_json::json!({ "label": lt }).to_string();
        if let Some(tt) = task_title_of(pool, task_id).await {
            let _ = activity_log_api::log_activity(pool, task_id, &tt, action, &detail).await;
        }
    }
}

// ---------- todo_comments ----------
pub async fn list_todo_comments(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoComment>> {
    generic_repo::list(pool, "todo_comments", filter).await
}
pub async fn get_todo_comment(pool: &SqlitePool, id: i64) -> CoreResult<TodoComment> {
    generic_repo::get_by_id(pool, "todo_comments", id).await
}
pub async fn create_todo_comment(
    pool: &SqlitePool,
    input: &TodoCommentCreateInput,
) -> CoreResult<TodoComment> {
    let row = generic_repo::create_todo_comment(pool, input).await?;
    log_target_activity(
        pool,
        row.task_id,
        "comment_add",
        &snapshot_text(&row.content),
    )
    .await;
    Ok(row)
}
pub async fn delete_todo_comment(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoComment = generic_repo::get_by_id(pool, "todo_comments", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_comments", id, &t.uuid).await?;
    log_target_activity(
        pool,
        t.task_id,
        "comment_delete",
        &snapshot_text(&t.content),
    )
    .await;
    Ok(())
}

// ---------- todo_task_relations ----------
pub async fn list_todo_task_relations(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoTaskRelation>> {
    generic_repo::list(pool, "todo_task_relations", filter).await
}
pub async fn get_todo_task_relation(pool: &SqlitePool, id: i64) -> CoreResult<TodoTaskRelation> {
    generic_repo::get_by_id(pool, "todo_task_relations", id).await
}
pub async fn create_todo_task_relation(
    pool: &SqlitePool,
    input: &TodoTaskRelationCreateInput,
) -> CoreResult<TodoTaskRelation> {
    let row = generic_repo::create_todo_task_relation(pool, input).await?;
    log_relation_change(pool, row.task_id, row.other_task_id, "link_add").await;
    Ok(row)
}
pub async fn delete_todo_task_relation(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let row = generic_repo::get_by_id::<TodoTaskRelation>(pool, "todo_task_relations", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_task_relations", id, &row.uuid).await?;
    log_relation_change(pool, row.task_id, row.other_task_id, "link_remove").await;
    Ok(())
}

/// 关联挂/摘历史轨迹（link_add / link_remove）：关联在双方任务抽屉都可见，
/// 故双向各记一条（target=对方标题）；任一方查不到则整体跳过
async fn log_relation_change(pool: &SqlitePool, task_id: i64, other_id: i64, action: &str) {
    let title_a = task_title_of(pool, task_id).await;
    let title_b = task_title_of(pool, other_id).await;
    if let (Some(ta), Some(tb)) = (title_a, title_b) {
        log_target_activity(pool, task_id, action, &tb).await;
        log_target_activity(pool, other_id, action, &ta).await;
    }
}

// ---------- todo_reminders ----------
pub async fn list_todo_reminders(
    pool: &SqlitePool,
    filter: &ListFilter,
) -> CoreResult<Vec<TodoReminder>> {
    generic_repo::list(pool, "todo_reminders", filter).await
}
pub async fn get_todo_reminder(pool: &SqlitePool, id: i64) -> CoreResult<TodoReminder> {
    generic_repo::get_by_id(pool, "todo_reminders", id).await
}
pub async fn create_todo_reminder(
    pool: &SqlitePool,
    input: &TodoReminderCreateInput,
) -> CoreResult<TodoReminder> {
    let row = generic_repo::create_todo_reminder(pool, input).await?;
    let when = snapshot_dt(Some(row.remind_at));
    log_target_activity(
        pool,
        row.task_id,
        "reminder_add",
        when.as_str().unwrap_or("已设置"),
    )
    .await;
    Ok(row)
}
pub async fn delete_todo_reminder(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoReminder = generic_repo::get_by_id(pool, "todo_reminders", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_reminders", id, &t.uuid).await?;
    let when = snapshot_dt(Some(t.remind_at));
    log_target_activity(
        pool,
        t.task_id,
        "reminder_delete",
        when.as_str().unwrap_or("已设置"),
    )
    .await;
    Ok(())
}

// =============================================================================
// Phase 7C: A 组 21 张表 create/update（泛型 JSON + 事件 emit）
// =============================================================================

/// 宏：为 A 组表批量生成 create + update 函数
/// 自动补充元数据字段，emit DbEvent（Insert/Update）
macro_rules! impl_crud_json {
    ($create_fn:ident, $update_fn:ident, $table:expr, $type:ty) => {
        pub async fn $create_fn(
            pool: &SqlitePool,
            fields: &serde_json::Value,
        ) -> CoreResult<$type> {
            let map = fields
                .as_object()
                .ok_or_else(|| CoreError::Other("fields must be a JSON object".into()))?;
            let record: $type = generic_repo::create_record_by_json(pool, $table, map).await?;
            let now = chrono::Utc::now().timestamp_millis();
            let payload = serde_json::to_value(&record).ok();
            EVENT_BUS.emit(DbEvent {
                table: $table.into(),
                op: DbOp::Insert,
                record_id: record.id,
                record_uuid: record.uuid.clone(),
                payload,
                device_id: generic_repo::current_device_id(),
                timestamp: now,
            });
            Ok(record)
        }

        pub async fn $update_fn(
            pool: &SqlitePool,
            id: i64,
            fields: &serde_json::Value,
        ) -> CoreResult<$type> {
            let map = fields
                .as_object()
                .ok_or_else(|| CoreError::Other("fields must be a JSON object".into()))?;
            let record: $type = generic_repo::update_record_by_json(pool, $table, id, map).await?;
            let now = chrono::Utc::now().timestamp_millis();
            let payload = serde_json::to_value(&record).ok();
            EVENT_BUS.emit(DbEvent {
                table: $table.into(),
                op: DbOp::Update,
                record_id: record.id,
                record_uuid: record.uuid.clone(),
                payload,
                device_id: generic_repo::current_device_id(),
                timestamp: now,
            });
            Ok(record)
        }
    };
}

impl_crud_json!(
    create_todo_project_by_json,
    update_todo_project_by_json,
    "todo_projects",
    TodoProject
);
impl_crud_json!(
    create_todo_task_by_json,
    update_todo_task_by_json,
    "todo_tasks",
    TodoTask
);

/// 宏：为 A 组表生成 get_by_uuid 函数
macro_rules! impl_get_by_uuid {
    ($fn_name:ident, $table:expr, $type:ty) => {
        pub async fn $fn_name(pool: &SqlitePool, uuid: &str) -> CoreResult<Option<$type>> {
            generic_repo::get_by_uuid(pool, $table, uuid).await
        }
    };
}

impl_get_by_uuid!(get_todo_project_by_uuid, "todo_projects", TodoProject);
impl_get_by_uuid!(get_todo_task_by_uuid, "todo_tasks", TodoTask);

// =============================================================================
// 全量备份/导出辅助（白名单统一收口 db::sync_registry，03 文档 §六）
// =============================================================================

/// 通用查询：按表名拉取未删除记录的 JSON 字符串（导出用）
///
/// 表名经白名单校验后拼入 SQL（防注入），其余参数走 sqlx bind。
/// 返回 JSON 数组字符串，如 `[{"id":1,"title":"..."},...]`。
pub async fn list_records_as_json(pool: &SqlitePool, table: &str) -> CoreResult<String> {
    if !FULL_BACKUP_TABLES.contains(&table) {
        return Err(CoreError::Other(format!(
            "table '{}' is not allowed for export/import",
            table
        )));
    }
    // 白名单已校验，安全拼接表名
    let sql = format!("SELECT * FROM \"{}\" WHERE is_deleted = 0", table);
    let rows = sqlx::query(&sql).fetch_all(pool).await?;
    let arr: Vec<serde_json::Value> = rows.iter().map(sqlite_row_to_json).collect();
    serde_json::to_string(&arr).map_err(CoreError::from)
}

/// 通用创建（无返回值）：逐条导入时使用，单条失败不阻塞整体流程
///
/// 内部调用 generic_repo::create_record_by_json_void，自动补充
/// uuid/timestamps/version（v1 全量同步直读业务表）。
pub async fn create_record_void(
    pool: &SqlitePool,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<()> {
    // 按目标表列声明类型规范化字段值，防止字符串写入 INTEGER 列等类型不匹配问题
    let normalized = normalize_import_fields(pool, table, fields, true).await?;
    crate::db::repository::generic_repo::create_record_by_json_void(pool, table, &normalized).await
}

/// 将 sqlx SqliteRow 转为 serde_json::Value（Object）
///
/// SQLite 动态类型，按列声明类型（type_info）分派解码：
/// INTEGER → i64, REAL → f64, TEXT → String, 其他 → 依次尝试 i64/f64/String
fn sqlite_row_to_json(row: &sqlx::sqlite::SqliteRow) -> serde_json::Value {
    use sqlx::{Column, Row, TypeInfo};
    let mut obj = serde_json::Map::new();
    for (i, col) in row.columns().iter().enumerate() {
        let name = col.name().to_string();
        let type_name = col.type_info().name();
        let val = match type_name {
            "INTEGER" | "INT" | "INTEGER8" => {
                let v: Option<i64> = row.try_get(i).unwrap_or(None);
                serde_json::Value::from(v)
            }
            "REAL" | "FLOAT" | "DOUBLE" | "REAL8" => {
                let v: Option<f64> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            "TEXT" | "VARCHAR" | "CHAR" => {
                let v: Option<String> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            _ => {
                // 未知类型：依次尝试 i64 → f64 → String → null
                if let Ok(v) = row.try_get::<Option<i64>, _>(i) {
                    serde_json::Value::from(v)
                } else if let Ok(v) = row.try_get::<Option<f64>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else if let Ok(v) = row.try_get::<Option<String>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else {
                    serde_json::Value::Null
                }
            }
        };
        obj.insert(name, val);
    }
    serde_json::Value::Object(obj)
}

/// 通用业务表记录数查询（列表页计数角标；仅适用于有 is_deleted 列的表）
pub async fn business_count(pool: &SqlitePool, table: &str) -> CoreResult<i64> {
    crate::db::repository::generic_repo::count_all(pool, table).await
}

// ---------- global search ----------
/// 全局搜索单条评论命中（附带所属任务标题，避免前端二次查询）
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CommentSearchHit {
    pub comment_id: i64,
    pub task_id: i64,
    pub task_title: String,
    pub content: String,
    pub created_at: i64,
}

/// 跨表聚合搜索结果（tasks/projects/comments 三路 LIKE，07 报告 §五-P1#9）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GlobalSearchResult {
    pub tasks: Vec<TodoTask>,
    pub projects: Vec<TodoProject>,
    pub comments: Vec<CommentSearchHit>,
}

/// 全局搜索（2026-09-12 批7 FTS 升级）：
/// - 主路径：查询词 ≥3 字符（trigram 最小语素）走 FTS5 MATCH——索引检索
///   替代 LIKE 全表扫；结果按 kind 分流 join 回源表（软删行已被触发器
///   摘除索引，join 侧再带 is_deleted = 0 双保险）。子任务命中归并到
///   主任务（task_id 列已在索引里）。
/// - 兜底：短词（1-2 字符，trigram 不可用）或 FTS 查询异常（如引号语法）
///   回退原三路 LIKE——中文两字词（如「评审」）是高频查询，兜底必须保。
pub async fn search_all(
    pool: &SqlitePool,
    keyword: &str,
    limit: i32,
) -> CoreResult<GlobalSearchResult> {
    let kw = keyword.trim();
    if kw.is_empty() {
        return Ok(GlobalSearchResult::default());
    }
    let limit = if limit <= 0 { 20 } else { limit };

    // trigram 最小 3 字符（ASCII 字母数按 char_indices 计——中文 1 字 = 1 字符）
    let use_fts = kw.chars().count() >= 3;

    if use_fts {
        if let Ok(r) = search_all_fts(pool, kw, limit).await {
            return Ok(r);
        }
        // FTS 异常（语法字符/索引损坏）静默降级 LIKE——搜索永不因索引失败而不可用
    }

    search_all_like(pool, kw, limit).await
}

/// FTS 主路径：MATCH 命中 → 按 kind 分流回源表。
/// MATCH 词做引号包裹的短语查询（精确子串语义，避免 OR 分词噪声）。
async fn search_all_fts(pool: &SqlitePool, kw: &str, limit: i32) -> CoreResult<GlobalSearchResult> {
    // 短语转义：查询词内的双引号移除（trigram 短语语法的合法输入）
    let phrase = format!("\"{}\"", kw.replace('"', ""));

    // kind ∈ {task, subtask, comment, project} 的命中行（外部内容表无 rowid 稳定序，
    // bm25() 排序取相关度）
    let hits: Vec<(String, i64)> = sqlx::query_as(
        "SELECT kind, ref_id FROM fts_todo WHERE fts_todo MATCH ? ORDER BY bm25(fts_todo) LIMIT ?",
    )
    .bind(&phrase)
    .bind(limit * 4) // 四源分摊上限（每路 limit 条的理论上限内截断）
    .fetch_all(pool)
    .await?;

    let mut task_ids: Vec<i64> = Vec::new();
    let mut project_ids: Vec<i64> = Vec::new();
    let mut comment_ids: Vec<i64> = Vec::new();
    for (kind, ref_id) in &hits {
        match kind.as_str() {
            "task" => task_ids.push(*ref_id),
            "subtask" => {
                // 子任务命中归并主任务：task_id 在索引行上（ref_id 是子任务行 id）
                let tid: Option<i64> = sqlx::query_scalar(
                    "SELECT task_id FROM fts_todo WHERE kind = 'subtask' AND ref_id = ?",
                )
                .bind(ref_id)
                .fetch_optional(pool)
                .await?;
                if let Some(tid) = tid {
                    task_ids.push(tid);
                }
            }
            "comment" => comment_ids.push(*ref_id),
            "project" => project_ids.push(*ref_id),
            _ => {}
        }
    }
    task_ids.dedup();
    project_ids.dedup();
    comment_ids.dedup();
    task_ids.truncate(limit as usize);
    project_ids.truncate(limit as usize);
    comment_ids.truncate(limit as usize);

    let tasks = if task_ids.is_empty() {
        Vec::new()
    } else {
        let placeholders = vec!["?"; task_ids.len()].join(",");
        let sql = format!(
            "SELECT * FROM todo_tasks WHERE is_deleted = 0 AND id IN ({placeholders}) \
             ORDER BY updated_at DESC"
        );
        let mut q = sqlx::query_as::<_, TodoTask>(&sql);
        for id in &task_ids {
            q = q.bind(id);
        }
        q.fetch_all(pool).await?
    };

    let projects = if project_ids.is_empty() {
        Vec::new()
    } else {
        let placeholders = vec!["?"; project_ids.len()].join(",");
        let sql = format!(
            "SELECT * FROM todo_projects WHERE is_deleted = 0 AND id IN ({placeholders}) \
             ORDER BY sort_order ASC, id ASC"
        );
        let mut q = sqlx::query_as::<_, TodoProject>(&sql);
        for id in &project_ids {
            q = q.bind(id);
        }
        q.fetch_all(pool).await?
    };

    let comments = if comment_ids.is_empty() {
        Vec::new()
    } else {
        let placeholders = vec!["?"; comment_ids.len()].join(",");
        let sql = format!(
            "SELECT c.id AS comment_id, c.task_id AS task_id, \
                    t.title AS task_title, c.content AS content, c.created_at AS created_at \
             FROM todo_comments c \
             JOIN todo_tasks t ON t.id = c.task_id AND t.is_deleted = 0 \
             WHERE c.is_deleted = 0 AND c.id IN ({placeholders}) \
             ORDER BY c.created_at DESC"
        );
        let mut q = sqlx::query_as::<_, CommentSearchHit>(&sql);
        for id in &comment_ids {
            q = q.bind(id);
        }
        q.fetch_all(pool).await?
    };

    Ok(GlobalSearchResult {
        tasks,
        projects,
        comments,
    })
}

/// LIKE 兜底路径（原三路实现原样保留——短词与 FTS 异常的最终保障）
async fn search_all_like(
    pool: &SqlitePool,
    kw: &str,
    limit: i32,
) -> CoreResult<GlobalSearchResult> {
    let pattern = format!("%{}%", kw);

    let tasks = sqlx::query_as::<_, TodoTask>(
        "SELECT * FROM todo_tasks \
         WHERE is_deleted = 0 AND (title LIKE ? OR description LIKE ?) \
         ORDER BY updated_at DESC LIMIT ?",
    )
    .bind(&pattern)
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let projects = sqlx::query_as::<_, TodoProject>(
        "SELECT * FROM todo_projects \
         WHERE is_deleted = 0 AND (title LIKE ? OR description LIKE ?) \
         ORDER BY sort_order ASC, id ASC LIMIT ?",
    )
    .bind(&pattern)
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let comments = sqlx::query_as::<_, CommentSearchHit>(
        "SELECT c.id AS comment_id, c.task_id AS task_id, \
                t.title AS task_title, c.content AS content, c.created_at AS created_at \
         FROM todo_comments c \
         JOIN todo_tasks t ON t.id = c.task_id AND t.is_deleted = 0 \
         WHERE c.is_deleted = 0 AND c.content LIKE ? \
         ORDER BY c.created_at DESC LIMIT ?",
    )
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(GlobalSearchResult {
        tasks,
        projects,
        comments,
    })
}

#[cfg(test)]
mod global_search_tests {
    use super::*;

    // ---------- FTS5 升级集成测试（2026-09-12 批7）----------

    async fn fts_setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 中文短语（≥3 字）走 FTS MATCH 命中任务标题
    #[tokio::test]
    async fn fts_chinese_phrase_hits_task_title() {
        let pool = fts_setup_db().await;
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "完成移动端重构方案评审".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "无关任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let r = search_all(&pool, "移动端重构", 20).await.unwrap();
        assert_eq!(r.tasks.len(), 1);
        assert_eq!(r.tasks[0].title, "完成移动端重构方案评审");
    }

    /// 短词（<3 字符）回退 LIKE：中文两字词仍可搜
    #[tokio::test]
    async fn short_keyword_falls_back_to_like() {
        let pool = fts_setup_db().await;
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "评审会议纪要".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let r = search_all(&pool, "评审", 20).await.unwrap();
        assert_eq!(r.tasks.len(), 1);
    }

    /// 子任务命中归并到主任务
    #[tokio::test]
    async fn subtask_hit_merges_into_main_task() {
        let pool = fts_setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "主任务标题不含关键词".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let s = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: t.id,
                title: "整理移动端重构清单".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        let _ = s;

        let r = search_all(&pool, "移动端重构清单", 20).await.unwrap();
        assert!(
            r.tasks.iter().any(|x| x.id == t.id),
            "子任务命中应归并主任务"
        );
    }

    /// 软删任务从索引摘除（回收站行不参与搜索）
    #[tokio::test]
    async fn soft_deleted_task_dropped_from_index() {
        let pool = fts_setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "待删除的移动端重构任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        delete_todo_task(&pool, t.id).await.unwrap();
        let r = search_all(&pool, "移动端重构", 20).await.unwrap();
        assert!(r.tasks.is_empty());
    }

    /// 描述正文 FTS 命中 + 评论正文命中
    #[tokio::test]
    async fn description_and_comment_hits() {
        let pool = fts_setup_db().await;
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "普通标题".into(),
                description: Some("正文包含采购露营物资细节".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let r = search_all(&pool, "露营物资细节", 20).await.unwrap();
        assert_eq!(r.tasks.len(), 1);
    }

    /// serde 往返：字段保持 snake_case（前端 typed invoke 依赖该形状）
    #[test]
    fn global_search_result_serializes_snake_case() {
        let r = GlobalSearchResult {
            tasks: vec![],
            projects: vec![],
            comments: vec![CommentSearchHit {
                comment_id: 1,
                task_id: 2,
                task_title: "写周报".into(),
                content: "记得带数据".into(),
                created_at: 3,
            }],
        };
        let v = serde_json::to_value(&r).unwrap();
        assert!(v["tasks"].is_array());
        assert!(v["projects"].is_array());
        assert_eq!(v["comments"][0]["comment_id"], 1);
        assert_eq!(v["comments"][0]["task_title"], "写周报");
        assert_eq!(v["comments"][0]["created_at"], 3);
    }
}

/// 项目归档三端口径回归（2026-09-13）：归档=从默认列表收起（非软删）——
/// 项目列表/默认任务聚合排除；项目视图（project_id 谓词）放行可读；
/// 归档列表独立入口；恢复归零。
#[cfg(test)]
mod project_archive_tests {
    use super::*;
    use crate::db::repository::generic_repo;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    fn all_tasks_filter() -> ListFilter {
        ListFilter {
            page_size: 10_000,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn archived_project_excluded_from_default_list() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "旧项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();

        // 归档前在列
        let before = list_todo_projects(&pool, &all_tasks_filter())
            .await
            .unwrap();
        assert!(before.iter().any(|x| x.id == p.id));

        update_todo_project(
            &pool,
            p.id,
            &TodoProjectUpdateInput {
                title: None,
                description: None,
                hex_color: None,
                sort_order: None,
                is_archived: Some(1),
            },
        )
        .await
        .unwrap();

        // 归档后退出默认列表 + 进归档列表
        let after = list_todo_projects(&pool, &all_tasks_filter())
            .await
            .unwrap();
        assert!(!after.iter().any(|x| x.id == p.id));
        let archived = list_archived_todo_projects(&pool).await.unwrap();
        assert!(archived.iter().any(|x| x.id == p.id && x.is_archived == 1));
    }

    #[tokio::test]
    async fn archived_project_tasks_hidden_from_aggregate_but_readable_in_project_view() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "归档项".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        let in_archived = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "归档项目内的任务".into(),
                project_id: Some(p.id),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let ungrouped = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "未分组任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        update_todo_project(
            &pool,
            p.id,
            &TodoProjectUpdateInput {
                title: None,
                description: None,
                hex_color: None,
                sort_order: None,
                is_archived: Some(1),
            },
        )
        .await
        .unwrap();

        // 默认聚合：归档项目任务排除，未分组保留
        let agg = list_todo_tasks(&pool, &all_tasks_filter()).await.unwrap();
        assert!(!agg.iter().any(|t| t.id == in_archived.id));
        assert!(agg.iter().any(|t| t.id == ungrouped.id));

        // 项目视图（project_id 谓词）：放行——归档区点进项目仍可读任务
        let mut view_filter = all_tasks_filter();
        view_filter.project_id = Some(p.id);
        let view = list_todo_tasks(&pool, &view_filter).await.unwrap();
        assert!(view.iter().any(|t| t.id == in_archived.id));
    }

    #[tokio::test]
    async fn unarchive_restores_project_to_default_list() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "再启用的项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        update_todo_project(
            &pool,
            p.id,
            &TodoProjectUpdateInput {
                title: None,
                description: None,
                hex_color: None,
                sort_order: None,
                is_archived: Some(1),
            },
        )
        .await
        .unwrap();
        update_todo_project(
            &pool,
            p.id,
            &TodoProjectUpdateInput {
                title: None,
                description: None,
                hex_color: None,
                sort_order: None,
                is_archived: Some(0),
            },
        )
        .await
        .unwrap();

        let list = list_todo_projects(&pool, &all_tasks_filter())
            .await
            .unwrap();
        assert!(list.iter().any(|x| x.id == p.id && x.is_archived == 0));
        let archived = list_archived_todo_projects(&pool).await.unwrap();
        assert!(archived.is_empty());
    }

    /// 归档与软删独立互不干扰：归档项目走软删后，归档列表也不显示（墓碑优先）
    #[tokio::test]
    async fn soft_delete_wins_over_archive() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "归档后又删除".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        update_todo_project(
            &pool,
            p.id,
            &TodoProjectUpdateInput {
                title: None,
                description: None,
                hex_color: None,
                sort_order: None,
                is_archived: Some(1),
            },
        )
        .await
        .unwrap();
        delete_todo_project(&pool, p.id).await.unwrap();

        let archived = list_archived_todo_projects(&pool).await.unwrap();
        assert!(archived.is_empty());
        let _ = generic_repo::get_by_id::<TodoProject>(&pool, "todo_projects", p.id)
            .await
            .is_err();
    }
}

#[cfg(test)]
mod activity_detail_tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 部分更新输入经 serde 构造（Option<Option<T>> 字段带 serde(default)）
    fn update_input(json: &str) -> TodoTaskUpdateInput {
        serde_json::from_str(json).unwrap()
    }

    /// update 轨迹带前后值快照：项目→名称、日期→本地日串、优先级→原值；
    /// fields 顺序与 TodoTask 字段声明序一致
    #[tokio::test]
    async fn update_detail_carries_value_snapshot() {
        let pool = setup_db().await;
        let proj = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "发布准备".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "任务甲".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let due = 1_759_000_000_000i64;
        update_todo_task(
            &pool,
            t.id,
            &update_input(&format!(
                r#"{{"priority":4,"due_date":{},"project_id":{}}}"#,
                due, proj.id
            )),
        )
        .await
        .unwrap();

        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        let upd = rows
            .iter()
            .find(|r| r.action == "update")
            .expect("应有 update 轨迹");
        let v: serde_json::Value = serde_json::from_str(&upd.detail).unwrap();
        assert_eq!(
            v["fields"],
            serde_json::json!(["project_id", "priority", "due_date"])
        );
        assert_eq!(v["changes"][0]["from"], serde_json::Value::Null);
        assert_eq!(v["changes"][0]["to"], "发布准备");
        assert_eq!(v["changes"][1]["to"], 4);
        // due_date 带时分割面（截止是时刻级字段，与抽屉属性行 yyyy-MM-dd HH:mm 同口径）
        let expect_due = chrono::Local
            .timestamp_millis_opt(due)
            .single()
            .unwrap()
            .format("%Y-%m-%d %H:%M")
            .to_string();
        assert_eq!(v["changes"][2]["to"], expect_due);
    }

    /// 标签挂/摘各记一条轨迹，detail 带标签名快照
    #[tokio::test]
    async fn label_attach_detach_logged_with_name() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "带标签任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let l = create_todo_label(
            &pool,
            &TodoLabelCreateInput {
                title: "工作".into(),
                hex_color: None,
            },
        )
        .await
        .unwrap();
        let tl = create_todo_task_label(
            &pool,
            &TodoTaskLabelCreateInput {
                task_id: t.id,
                label_id: l.id,
            },
        )
        .await
        .unwrap();

        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        let add = rows
            .iter()
            .find(|r| r.action == "label_add")
            .expect("挂标签应有轨迹");
        assert_eq!(add.task_title, "带标签任务");
        let v: serde_json::Value = serde_json::from_str(&add.detail).unwrap();
        assert_eq!(v["label"], "工作");

        delete_todo_task_label(&pool, tl.id).await.unwrap();
        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        assert!(rows.iter().any(|r| r.action == "label_remove"));
    }

    /// 子任务/评论/关联/提醒写路径各留一条轨迹（detail 带 target 快照）；
    /// 关联双向各记一条（双方任务抽屉都可见该关联）
    #[tokio::test]
    async fn attached_entities_logged_with_target() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "主任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let other = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "对方任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: t.id,
                title: "子任务甲".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        crate::api::todo_api::toggle_todo_subtask_done(&pool, sub.id, true)
            .await
            .unwrap();
        let c = create_todo_comment(
            &pool,
            &TodoCommentCreateInput {
                task_id: t.id,
                content: "评论乙".into(),
            },
        )
        .await
        .unwrap();
        let rel = create_todo_task_relation(
            &pool,
            &TodoTaskRelationCreateInput {
                task_id: t.id,
                other_task_id: other.id,
                relation_type: "related".into(),
            },
        )
        .await
        .unwrap();
        let remind_at = 1_759_000_000_000i64;
        let rem = create_todo_reminder(
            &pool,
            &TodoReminderCreateInput {
                task_id: t.id,
                remind_at,
            },
        )
        .await
        .unwrap();

        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        let find = |a: &str| rows.iter().find(|r| r.action == a);
        assert_eq!(
            find("subtask_add").unwrap().detail,
            r#"{"target":"子任务甲"}"#
        );
        assert!(find("subtask_done").is_some());
        assert!(find("comment_add").is_some());
        assert!(find("link_add").is_some());
        let expect_when = chrono::Local
            .timestamp_millis_opt(remind_at)
            .single()
            .unwrap()
            .format("%Y-%m-%d %H:%M")
            .to_string();
        assert_eq!(
            find("reminder_add").unwrap().detail,
            format!(r#"{{"target":"{expect_when}"}}"#)
        );

        // 对方任务侧也记一条 link_add（target=主任务标题）
        let other_rows = activity_log_api::list_task_activity(&pool, other.id, None)
            .await
            .unwrap();
        let link = other_rows
            .iter()
            .find(|r| r.action == "link_add")
            .expect("对方任务应有 link_add 轨迹");
        let v: serde_json::Value = serde_json::from_str(&link.detail).unwrap();
        assert_eq!(v["target"], "主任务");

        // 删除侧各记一条移除轨迹
        delete_todo_subtask(&pool, sub.id).await.unwrap();
        delete_todo_comment(&pool, c.id).await.unwrap();
        delete_todo_task_relation(&pool, rel.id).await.unwrap();
        delete_todo_reminder(&pool, rem.id).await.unwrap();
        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        for a in [
            "subtask_delete",
            "comment_delete",
            "link_remove",
            "reminder_delete",
        ] {
            assert!(rows.iter().any(|r| r.action == a), "缺 {a} 轨迹");
        }
        let other_rows = activity_log_api::list_task_activity(&pool, other.id, None)
            .await
            .unwrap();
        assert!(other_rows.iter().any(|r| r.action == "link_remove"));
    }

    /// 重复规则任一子字段变更 → 合并为一条 repeat_rule 伪字段（值为六字段对象
    /// 快照）；子任务改名记 subtask_rename（target=「旧 → 新」对照串）
    #[tokio::test]
    async fn repeat_rule_merged_and_subtask_rename_logged() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "重复规则任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        update_todo_task(
            &pool,
            t.id,
            &update_input(r#"{"repeat_mode":2,"repeat_after":2,"repeat_weekdays":2}"#),
        )
        .await
        .unwrap();
        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        let upd = rows
            .iter()
            .find(|r| r.action == "update")
            .expect("应有 update 轨迹");
        let v: serde_json::Value = serde_json::from_str(&upd.detail).unwrap();
        assert_eq!(v["fields"], serde_json::json!(["repeat_rule"]));
        assert_eq!(v["changes"][0]["field"], "repeat_rule");
        assert_eq!(v["changes"][0]["from"]["mode"], 0);
        assert_eq!(v["changes"][0]["to"]["mode"], 2);
        assert_eq!(v["changes"][0]["to"]["after"], 2);
        assert_eq!(v["changes"][0]["to"]["weekdays"], 2);

        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: t.id,
                title: "旧名".into(),
                position: None,
            },
        )
        .await
        .unwrap();
        update_todo_subtask(
            &pool,
            sub.id,
            &TodoSubtaskUpdateInput {
                title: Some("新名".into()),
                done: None,
                done_at: None,
                position: None,
            },
        )
        .await
        .unwrap();
        let rows = activity_log_api::list_task_activity(&pool, t.id, None)
            .await
            .unwrap();
        let ren = rows
            .iter()
            .find(|r| r.action == "subtask_rename")
            .expect("改名应有轨迹");
        let v: serde_json::Value = serde_json::from_str(&ren.detail).unwrap();
        assert_eq!(v["target"], "旧名 → 新名");
    }
}
