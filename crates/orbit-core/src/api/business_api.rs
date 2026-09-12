//! business_api — 业务编排层（Orbit MVP：todo 段 + cfg 必需段 + 备份辅助）
//!
//! 平移自 wait-home wait_core（02 文档 §四 A/B 类）。
//! 白名单常量统一收口到 db::sync_registry（03 文档 §六），本文件经 pub use 转发。

pub use crate::db::sync_registry::FULL_BACKUP_TABLES;

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
        "SELECT * FROM todo_projects WHERE is_deleted = 0{} \
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
    // 活动日志（F6）：记录实际发生变化的字段集（比较前后行——
    // 前端部分更新的 Option 语义下未命中字段的 UPDATE 不产生 diff）
    let fields = changed_task_fields(&before, &t);
    if !fields.is_empty() {
        let detail = serde_json::json!({ "fields": fields }).to_string();
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

/// 比较任务前后行，返回发生变化的字段名集（活动日志 detail 用；
/// 顺序与 TodoTask 字段声明序一致，测试锁定）
fn changed_task_fields(before: &TodoTask, after: &TodoTask) -> Vec<&'static str> {
    let mut fields = Vec::new();
    if before.title != after.title {
        fields.push("title");
    }
    if before.description != after.description {
        fields.push("description");
    }
    if before.project_id != after.project_id {
        fields.push("project_id");
    }
    if before.priority != after.priority {
        fields.push("priority");
    }
    if before.status != after.status {
        fields.push("status");
    }
    if before.done != after.done {
        fields.push("done");
    }
    if before.done_at != after.done_at {
        fields.push("done_at");
    }
    if before.due_date != after.due_date {
        fields.push("due_date");
    }
    if before.start_date != after.start_date {
        fields.push("start_date");
    }
    if before.percent_done != after.percent_done {
        fields.push("percent_done");
    }
    if before.position != after.position {
        fields.push("position");
    }
    if before.is_favorite != after.is_favorite {
        fields.push("is_favorite");
    }
    if before.my_day_date != after.my_day_date {
        fields.push("my_day_date");
    }
    fields
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
    generic_repo::create_todo_subtask(pool, input).await
}
pub async fn update_todo_subtask(
    pool: &SqlitePool,
    id: i64,
    input: &TodoSubtaskUpdateInput,
) -> CoreResult<TodoSubtask> {
    generic_repo::update_todo_subtask(pool, id, input).await
}
pub async fn delete_todo_subtask(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoSubtask = generic_repo::get_by_id(pool, "todo_subtasks", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_subtasks", id, &t.uuid).await
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
    generic_repo::create_todo_task_label(pool, input).await
}
pub async fn delete_todo_task_label(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let row = generic_repo::get_by_id::<TodoTaskLabel>(pool, "todo_task_labels", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_task_labels", id, &row.uuid).await
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
    generic_repo::create_todo_comment(pool, input).await
}
pub async fn delete_todo_comment(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoComment = generic_repo::get_by_id(pool, "todo_comments", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_comments", id, &t.uuid).await
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
    generic_repo::create_todo_task_relation(pool, input).await
}
pub async fn delete_todo_task_relation(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let row = generic_repo::get_by_id::<TodoTaskRelation>(pool, "todo_task_relations", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_task_relations", id, &row.uuid).await
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
    generic_repo::create_todo_reminder(pool, input).await
}
pub async fn delete_todo_reminder(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoReminder = generic_repo::get_by_id(pool, "todo_reminders", id).await?;
    generic_repo::soft_delete_by_id(pool, "todo_reminders", id, &t.uuid).await
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

/// 全局搜索：复用 generic_repo 同款 %kw% LIKE 口径，各表限 top limit 条。
/// 评论经 JOIN todo_tasks 带出任务标题；任务按 updated_at DESC、
/// 项目按 sort_order ASC（与各自列表页排序一致，保证命中顺序符合直觉）。
pub async fn search_all(
    pool: &SqlitePool,
    keyword: &str,
    limit: i32,
) -> CoreResult<GlobalSearchResult> {
    let kw = keyword.trim();
    if kw.is_empty() {
        return Ok(GlobalSearchResult::default());
    }
    let pattern = format!("%{}%", kw);
    let limit = if limit <= 0 { 20 } else { limit };

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
