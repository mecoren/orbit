//! generic_repo — 泛型仓储辅助
//!
//! 为 28 张业务表提供模式统一的 list/get/soft_delete 实现，避免每表重复代码（tags/tag_relations 已移除）。
//! create/update 因字段差异大，rec_books 提供完整 typed 示范，其余表后续按需补全。
//!
//! 设计依据：rec_movies 范式（repository 写操作后 emit DbEvent）。
//! 泛型函数同样在写操作后 emit 事件，保证响应式数据流一致。

use sqlx::SqlitePool;

use crate::context;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{EVENT_BUS, events::{DbEvent, DbOp}};
use crate::models::business::{
    ListFilter,
    TodoProject, TodoProjectCreateInput, TodoProjectUpdateInput,
    TodoTask, TodoTaskCreateInput, TodoTaskUpdateInput,
    TodoSubtask, TodoSubtaskCreateInput, TodoSubtaskUpdateInput,
    TodoLabel, TodoLabelCreateInput, TodoLabelUpdateInput,
    TodoTaskLabel, TodoTaskLabelCreateInput,
    TodoComment, TodoCommentCreateInput,
    TodoTaskRelation, TodoTaskRelationCreateInput,
    TodoReminder, TodoReminderCreateInput,
};

// =============================================================================
// 上下文辅助：安全读取 device_id（未设置时回退，不阻断业务写操作）
// =============================================================================

/// 读取当前 device_id；未设置返回空串（兼容早期未调用 set_device_id 的场景）
pub(crate) fn current_device_id() -> String {
    context::get_device_id().unwrap_or_default().to_string()
}

// =============================================================================
// 泛型 list/get/soft_delete（适用于所有有 is_deleted + id 的表）
// =============================================================================

/// 泛型分页列表查询：SELECT * FROM {table} WHERE is_deleted=0
///     [AND (field1 LIKE ? OR field2 LIKE ? ...)]
///     ORDER BY updated_at DESC LIMIT ? OFFSET ?
///
/// 当 filter.keyword 非空时，按 [searchable_fields] 返回的字段白名单拼接 LIKE OR 子句。
/// 调用方需保证 T: sqlx::FromRow 且表结构匹配。
pub async fn list<T>(
    pool: &SqlitePool,
    table: &str,
    filter: &ListFilter,
) -> CoreResult<Vec<T>>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let page_size = if filter.page_size == 0 {
        20
    } else {
        filter.page_size
    } as i32;
    let offset = (filter.page.saturating_sub(1)).saturating_mul(filter.page_size) as i32;

    // 拼接 keyword 过滤子句：仅在 keyword 非空且表有可搜索字段时生效
    let keyword_clause = build_keyword_clause(table, filter.keyword.as_deref());

    let sql = format!(
        "SELECT * FROM {} WHERE is_deleted = 0{} ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        table, keyword_clause.clause,
    );

    let mut q = sqlx::query_as::<_, T>(&sql);
    // 绑定 keyword 参数（每个可搜索字段绑定一次 %keyword%）
    for value in keyword_clause.bindings {
        q = q.bind(value);
    }
    q = q.bind(page_size);
    q = q.bind(offset);

    let items = q.fetch_all(pool).await?;
    Ok(items)
}

/// 关键词过滤子句构造结果
struct KeywordClause {
    /// SQL 子句文本（如 " AND (title LIKE ? OR author LIKE ?)"），无 keyword 时为空串
    clause: String,
    /// 绑定参数值列表（每个字段一个 "%keyword%" 字符串）
    bindings: Vec<String>,
}

/// 返回指定业务表的可搜索字符串字段白名单
///
/// 白名单集中维护，遗漏字段只是搜索不到，不会崩溃。
/// 未在白名单中的表返回空切片（不支持 keyword 搜索）。
fn searchable_fields(table: &str) -> &'static [&'static str] {
    match table {
        "rec_books" => &[
            "title",
            "original_title",
            "authors",
            "subtitle",
            "translators",
            "publisher",
            "isbn",
            "series",
            "genre",
            "region",
            "language",
            "description",
            "review",
        ],
        "rec_games" => &[
            "title",
            "original_title",
            "developer",
            "publisher",
            "genre",
            "platform",
            "region",
            "description",
            "review",
        ],
        "rec_devices" => &["name", "category", "model", "spec_desc"],
        "rec_outings" => &["name", "location", "description", "remark"],
        "important_events" => &["title", "description", "category", "location"],
        "rec_gift_cards" => &[
            "name",
            "brand",
            "card_number",
            "store",
            "denomination",
            "description",
        ],
        "todo_tasks" => &["title", "description"],
        "todo_projects" => &["title", "description"],
        "todo_subtasks" => &["title"],
        "todo_labels" => &["title"],
        "todo_comments" => &["content"],
        "career_projects" => &["name", "description", "status", "priority"],
        "career_experiences" => &["company", "position", "description", "location"],
        "career_salaries" => &["company", "position", "pay_period", "description"],
        "career_companies" => &["name", "industry", "description", "address"],
        "phone_numbers" => &[
            "name",
            "brand",
            "model",
            "serial_number",
            "carrier",
            "description",
        ],
        "women_periods" => &["note", "symptom_json", "mood"],
        "women_pregnancies" => &["title", "note"],
        "women_health_logs" => &["note", "symptom_type", "symptom_value"],
        // 未列入白名单的表不支持 keyword 搜索
        _ => &[],
    }
}

/// 根据 keyword 和表名构造 LIKE OR 子句
///
/// - keyword 为空或表无搜索字段时返回空子句
/// - 字段名经 [validate_column_name] 校验后拼入 SQL（防注入）
/// - 每个字段绑定一个 "%keyword%" 参数
fn build_keyword_clause(table: &str, keyword: Option<&str>) -> KeywordClause {
    let trimmed = keyword.map(|s| s.trim()).unwrap_or("");
    if trimmed.is_empty() {
        return KeywordClause {
            clause: String::new(),
            bindings: Vec::new(),
        };
    }

    let fields = searchable_fields(table);
    if fields.is_empty() {
        return KeywordClause {
            clause: String::new(),
            bindings: Vec::new(),
        };
    }

    // 构造 " AND (field1 LIKE ? OR field2 LIKE ? ...)" 子句
    // 字段名经校验后安全拼接
    let mut conditions: Vec<String> = Vec::with_capacity(fields.len());
    let pattern = format!("%{}%", trimmed);
    let mut bindings = Vec::with_capacity(fields.len());

    for field in fields {
        // 防御性校验：白名单字段名应全部通过，但保险起见仍校验
        if validate_column_name(field).is_ok() {
            conditions.push(format!("{} LIKE ?", field));
            bindings.push(pattern.clone());
        }
    }

    if conditions.is_empty() {
        return KeywordClause {
            clause: String::new(),
            bindings: Vec::new(),
        };
    }

    let clause = format!(" AND ({})", conditions.join(" OR "));
    KeywordClause { clause, bindings }
}

/// 泛型计数查询：SELECT COUNT(*) FROM {table} WHERE is_deleted = 0
///
/// 适用于所有有 is_deleted 列的业务表（A 组记录表 + 其他标准表）。
/// 用于首页仪表盘统计各模块记录数。
pub async fn count_all(pool: &SqlitePool, table: &str) -> CoreResult<i64> {
    let sql = format!("SELECT COUNT(*) FROM {} WHERE is_deleted = 0", table);
    let (count,): (i64,) = sqlx::query_as(&sql).fetch_one(pool).await?;
    Ok(count)
}

/// 泛型按时间过滤计数：SELECT COUNT(*) FROM {table}
///     WHERE is_deleted = 0 AND created_at >= ?
///
/// 用于首页仪表盘"本月新增"等时间窗口指标统计。
/// `since_ms` 为毫秒级 Unix 时间戳（前端按本地时区计算本月 1 日 00:00:00 转毫秒）。
/// 适用于所有有 is_deleted + created_at 列的业务表。
pub async fn count_since(pool: &SqlitePool, table: &str, since_ms: i64) -> CoreResult<i64> {
    let sql = format!(
        "SELECT COUNT(*) FROM {} WHERE is_deleted = 0 AND created_at >= ?",
        table
    );
    let (count,): (i64,) = sqlx::query_as(&sql)
        .bind(since_ms)
        .fetch_one(pool)
        .await?;
    Ok(count)
}

/// 泛型按时间分桶计数：返回 `Vec<(bucket_key: String, count: i64)>`
///
/// 用于首页仪表盘趋势图（月度走势/年度对比/模块堆叠/活动热力图）。
/// `start_ms`/`end_ms` 为毫秒级时间戳，`bucket` 取值 `"day"` / `"month"` / `"year"`。
///
/// SQL 用 SQLite `strftime` 将 `created_at`（UTC 毫秒）转本地时区分组：
/// - `day`:   `strftime('%Y-%m-%d', created_at/1000, 'unixepoch', 'localtime')`
/// - `month`: `strftime('%Y-%m',    created_at/1000, 'unixepoch', 'localtime')`
/// - `year`:  `strftime('%Y',       created_at/1000, 'unixepoch', 'localtime')`
///
/// 仅返回有记录的桶，前端需自行补齐缺失桶为 0。
/// 适用于所有有 is_deleted + created_at 列的业务表。
pub async fn count_by_bucket(
    pool: &SqlitePool,
    table: &str,
    start_ms: i64,
    end_ms: i64,
    bucket: &str,
) -> CoreResult<Vec<(String, i64)>> {
    // 桶格式按 bucket 类型选择，校验避免 SQL 注入（仅允许 day/month/year）
    let fmt = match bucket {
        "day" => "%Y-%m-%d",
        "month" => "%Y-%m",
        "year" => "%Y",
        _ => {
            return Err(crate::error::CoreError::Other(format!(
                "invalid bucket '{}', expected day/month/year",
                bucket
            )));
        }
    };
    let sql = format!(
        "SELECT strftime('{}', created_at/1000, 'unixepoch', 'localtime') AS bucket_key, \
         COUNT(*) AS cnt FROM {} \
         WHERE is_deleted = 0 AND created_at >= ? AND created_at < ? \
         GROUP BY bucket_key ORDER BY bucket_key",
        fmt, table
    );
    let rows: Vec<(String, i64)> = sqlx::query_as(&sql)
        .bind(start_ms)
        .bind(end_ms)
        .fetch_all(pool)
        .await?;
    Ok(rows)
}

/// 允许作为热力图分桶日期字段的白名单（防 SQL 注入：列名不可参数化）
///
/// 仅允许毫秒级时间戳（INTEGER）列，与 created_at 类型一致，
/// 可直接复用 strftime(... /1000, 'unixepoch', 'localtime') 分桶逻辑。
const ALLOWED_DATE_FIELDS: &[&str] = &[
    "created_at",
    "watched_at",
    "finished_at",
    "paid_at",
    "acquired_at",
    "visited_at",
];

/// 泛型按自定义日期字段分桶计数：与 [count_by_bucket] 逻辑相同，
/// 但允许指定业务日期字段（如 watched_at / finished_at / paid_at 等）替代 created_at。
///
/// 用于主页热力图按业务日期（观看时间/购买日期/游玩日期等）聚合，而非记录创建时间。
/// `date_field` 必须在 [ALLOWED_DATE_FIELDS] 白名单中，否则返回错误。
/// 业务日期为 NULL 的记录会被 IS NOT NULL 条件过滤，不计入热力图。
pub async fn count_by_bucket_with_field(
    pool: &SqlitePool,
    table: &str,
    start_ms: i64,
    end_ms: i64,
    bucket: &str,
    date_field: &str,
) -> CoreResult<Vec<(String, i64)>> {
    // 校验 date_field 白名单，防止 SQL 注入
    if !ALLOWED_DATE_FIELDS.contains(&date_field) {
        return Err(crate::error::CoreError::Other(format!(
            "invalid date_field '{}', allowed: {:?}",
            date_field, ALLOWED_DATE_FIELDS
        )));
    }
    let fmt = match bucket {
        "day" => "%Y-%m-%d",
        "month" => "%Y-%m",
        "year" => "%Y",
        _ => {
            return Err(crate::error::CoreError::Other(format!(
                "invalid bucket '{}', expected day/month/year",
                bucket
            )));
        }
    };
    let sql = format!(
        "SELECT strftime('{}', {}/1000, 'unixepoch', 'localtime') AS bucket_key, \
         COUNT(*) AS cnt FROM {} \
         WHERE is_deleted = 0 AND {} IS NOT NULL AND {} >= ? AND {} < ? \
         GROUP BY bucket_key ORDER BY bucket_key",
        fmt, date_field, table, date_field, date_field, date_field
    );
    let rows: Vec<(String, i64)> = sqlx::query_as(&sql)
        .bind(start_ms)
        .bind(end_ms)
        .fetch_all(pool)
        .await?;
    Ok(rows)
}

/// 泛型计数查询（带 keyword 过滤）：与 [list] 使用完全相同的过滤条件
///
/// 复用 [build_keyword_clause] 拼装 keyword OR 子句，保证 total 与 list 条数一致。
/// 用于分页列表的真实总数统计（取代 items.length 近似值）。
pub async fn count_with_filter(
    pool: &SqlitePool,
    table: &str,
    filter: &ListFilter,
) -> CoreResult<i64> {
    let keyword_clause = build_keyword_clause(table, filter.keyword.as_deref());
    let sql = format!(
        "SELECT COUNT(*) FROM {} WHERE is_deleted = 0{}",
        table, keyword_clause.clause,
    );
    let mut q = sqlx::query_as::<_, (i64,)>(&sql);
    for value in keyword_clause.bindings {
        q = q.bind(value);
    }
    let (count,) = q.fetch_one(pool).await?;
    Ok(count)
}

/// 泛型详情查询：SELECT * FROM {table} WHERE id = ?
pub async fn get_by_id<T>(pool: &SqlitePool, table: &str, id: i64) -> CoreResult<T>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let sql = format!("SELECT * FROM {} WHERE id = ?", table);
    sqlx::query_as::<_, T>(&sql)
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("{} id={}", table, id)))
}

/// 泛型 UUID 查询：SELECT * FROM {table} WHERE uuid = ? AND is_deleted = 0
///
/// 适用于 A 组表（有 uuid + is_deleted 字段）。
pub async fn get_by_uuid<T>(pool: &SqlitePool, table: &str, uuid: &str) -> CoreResult<Option<T>>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let sql = format!(
        "SELECT * FROM {} WHERE uuid = ? AND is_deleted = 0 LIMIT 1",
        table
    );
    let item = sqlx::query_as::<_, T>(&sql)
        .bind(uuid)
        .fetch_optional(pool)
        .await?;
    Ok(item)
}

/// 泛型软删除：UPDATE {table} SET is_deleted=1, deleted_at=?, updated_at=?, version=version+1
/// WHERE id=?
///
/// device_id 从全局 context 读取（当前执行删除的设备），仅用于 DbEvent 事件传播。
pub async fn soft_delete_by_id(
    pool: &SqlitePool,
    table: &str,
    id: i64,
    record_uuid: &str,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let device_id = current_device_id();

    let sql = format!(
        "UPDATE {} SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1 WHERE id = ?",
        table
    );
    sqlx::query(&sql)
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(pool)
        .await?;

    EVENT_BUS.emit(DbEvent::delete(table, id, record_uuid, &device_id));

    Ok(())
}

// =============================================================================
// =============================================================================
// todo_ 表族 typed create/update（Vikunja 化重构，8 张表）
// =============================================================================

// ---------- todo_projects ----------

/// todo_projects 创建
pub async fn create_todo_project(pool: &SqlitePool, input: &TodoProjectCreateInput) -> CoreResult<TodoProject> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();

    let row = sqlx::query_as::<_, TodoProject>(
        "INSERT INTO todo_projects (uuid, title, description, hex_color, sort_order, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid)
    .bind(&input.title)
    .bind(input.description.as_deref())
    .bind(input.hex_color.as_deref().unwrap_or("#3B82F6"))
    .bind(input.sort_order.unwrap_or(0.0))
    .bind(now)
    .bind(now)
    .fetch_one(pool).await?;

    emit_event("todo_projects", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

/// todo_projects 更新
pub async fn update_todo_project(pool: &SqlitePool, id: i64, input: &TodoProjectUpdateInput) -> CoreResult<TodoProject> {
    let now = chrono::Utc::now().timestamp_millis();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() { sets.push("title = ?".into()); }
    if input.description.is_some() { sets.push("description = ?".into()); }
    if input.hex_color.is_some() { sets.push("hex_color = ?".into()); }
    if input.sort_order.is_some() { sets.push("sort_order = ?".into()); }

    let sql = format!("UPDATE todo_projects SET {} WHERE id = ? RETURNING *", sets.join(", "));
    let mut q = sqlx::query_as::<_, TodoProject>(&sql).bind(now);
    if let Some(v) = &input.title { q = q.bind(v); }
    if let Some(v) = input.description.as_ref() { q = q.bind(v); }
    if let Some(v) = &input.hex_color { q = q.bind(v); }
    if let Some(v) = input.sort_order { q = q.bind(v); }
    let row = q.bind(id).fetch_optional(pool).await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_project id={}", id)))?;

    emit_event("todo_projects", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_tasks ----------

/// todo_tasks 创建
pub async fn create_todo_task(pool: &SqlitePool, input: &TodoTaskCreateInput) -> CoreResult<TodoTask> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();

    let row = sqlx::query_as::<_, TodoTask>(
        "INSERT INTO todo_tasks (
            uuid, title, description, project_id, priority, status, done, done_at,
            due_date, start_date, end_date, repeat_after, repeat_mode,
            hex_color, percent_done, position, is_favorite,
            is_deleted, created_at, updated_at, version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, ?, 1)
        RETURNING *",
    )
    .bind(&uuid)
    .bind(&input.title)
    .bind(input.description.as_deref())
    .bind(input.project_id)
    .bind(input.priority.unwrap_or(0))
    .bind(input.status.as_deref().unwrap_or("pending"))
    .bind(input.done.unwrap_or(0))
    .bind(input.done_at)
    .bind(input.due_date)
    .bind(input.start_date)
    .bind(input.end_date)
    .bind(input.repeat_after.unwrap_or(0))
    .bind(input.repeat_mode.unwrap_or(0))
    .bind(input.hex_color.as_deref().unwrap_or(""))
    .bind(input.position.unwrap_or(0.0))
    .bind(input.is_favorite.unwrap_or(0))
    .bind(now)
    .bind(now)
    .fetch_one(pool).await?;

    emit_event("todo_tasks", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

/// todo_tasks 更新（Option<Option<T>> 模式）
pub async fn update_todo_task(pool: &SqlitePool, id: i64, input: &TodoTaskUpdateInput) -> CoreResult<TodoTask> {
    let now = chrono::Utc::now().timestamp_millis();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() { sets.push("title = ?".into()); }
    if input.description.is_some() { sets.push("description = ?".into()); }
    if input.project_id.is_some() { sets.push("project_id = ?".into()); }
    if input.priority.is_some() { sets.push("priority = ?".into()); }
    if input.status.is_some() { sets.push("status = ?".into()); }
    if input.done.is_some() { sets.push("done = ?".into()); }
    if input.done_at.is_some() { sets.push("done_at = ?".into()); }
    if input.due_date.is_some() { sets.push("due_date = ?".into()); }
    if input.start_date.is_some() { sets.push("start_date = ?".into()); }
    if input.end_date.is_some() { sets.push("end_date = ?".into()); }
    if input.repeat_after.is_some() { sets.push("repeat_after = ?".into()); }
    if input.repeat_mode.is_some() { sets.push("repeat_mode = ?".into()); }
    if input.hex_color.is_some() { sets.push("hex_color = ?".into()); }
    if input.percent_done.is_some() { sets.push("percent_done = ?".into()); }
    if input.position.is_some() { sets.push("position = ?".into()); }
    if input.is_favorite.is_some() { sets.push("is_favorite = ?".into()); }

    let sql = format!("UPDATE todo_tasks SET {} WHERE id = ? RETURNING *", sets.join(", "));
    let mut q = sqlx::query_as::<_, TodoTask>(&sql).bind(now);
    if let Some(v) = &input.title { q = q.bind(v); }
    if let Some(v) = input.description.as_ref() { q = q.bind(v); }
    if let Some(v) = input.project_id { q = q.bind(v); }
    if let Some(v) = input.priority { q = q.bind(v); }
    if let Some(v) = &input.status { q = q.bind(v); }
    if let Some(v) = input.done { q = q.bind(v); }
    if let Some(v) = input.done_at { q = q.bind(v); }
    if let Some(v) = input.due_date { q = q.bind(v); }
    if let Some(v) = input.start_date { q = q.bind(v); }
    if let Some(v) = input.end_date { q = q.bind(v); }
    if let Some(v) = input.repeat_after { q = q.bind(v); }
    if let Some(v) = input.repeat_mode { q = q.bind(v); }
    if let Some(v) = &input.hex_color { q = q.bind(v); }
    if let Some(v) = input.percent_done { q = q.bind(v); }
    if let Some(v) = input.position { q = q.bind(v); }
    if let Some(v) = input.is_favorite { q = q.bind(v); }
    let row = q.bind(id).fetch_optional(pool).await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_task id={}", id)))?;

    emit_event("todo_tasks", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_subtasks ----------

pub async fn create_todo_subtask(pool: &SqlitePool, input: &TodoSubtaskCreateInput) -> CoreResult<TodoSubtask> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoSubtask>(
        "INSERT INTO todo_subtasks (uuid, task_id, title, done, done_at, position, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, NULL, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(&input.title)
    .bind(input.position.unwrap_or(0.0))
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_subtasks", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

pub async fn update_todo_subtask(pool: &SqlitePool, id: i64, input: &TodoSubtaskUpdateInput) -> CoreResult<TodoSubtask> {
    let now = chrono::Utc::now().timestamp_millis();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() { sets.push("title = ?".into()); }
    if input.done.is_some() { sets.push("done = ?".into()); }
    if input.done_at.is_some() { sets.push("done_at = ?".into()); }
    if input.position.is_some() { sets.push("position = ?".into()); }
    let sql = format!("UPDATE todo_subtasks SET {} WHERE id = ? RETURNING *", sets.join(", "));
    let mut q = sqlx::query_as::<_, TodoSubtask>(&sql).bind(now);
    if let Some(v) = &input.title { q = q.bind(v); }
    if let Some(v) = input.done { q = q.bind(v); }
    if let Some(v) = input.done_at { q = q.bind(v); }
    if let Some(v) = input.position { q = q.bind(v); }
    let row = q.bind(id).fetch_optional(pool).await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_subtask id={}", id)))?;
    emit_event("todo_subtasks", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_labels ----------

pub async fn create_todo_label(pool: &SqlitePool, input: &TodoLabelCreateInput) -> CoreResult<TodoLabel> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoLabel>(
        "INSERT INTO todo_labels (uuid, title, hex_color, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(&input.title)
    .bind(input.hex_color.as_deref().unwrap_or("#6B7280"))
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_labels", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

pub async fn update_todo_label(pool: &SqlitePool, id: i64, input: &TodoLabelUpdateInput) -> CoreResult<TodoLabel> {
    let now = chrono::Utc::now().timestamp_millis();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() { sets.push("title = ?".into()); }
    if input.hex_color.is_some() { sets.push("hex_color = ?".into()); }
    let sql = format!("UPDATE todo_labels SET {} WHERE id = ? RETURNING *", sets.join(", "));
    let mut q = sqlx::query_as::<_, TodoLabel>(&sql).bind(now);
    if let Some(v) = &input.title { q = q.bind(v); }
    if let Some(v) = &input.hex_color { q = q.bind(v); }
    let row = q.bind(id).fetch_optional(pool).await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_label id={}", id)))?;
    emit_event("todo_labels", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_task_labels（仅 create + delete） ----------

pub async fn create_todo_task_label(pool: &SqlitePool, input: &TodoTaskLabelCreateInput) -> CoreResult<TodoTaskLabel> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoTaskLabel>(
        "INSERT INTO todo_task_labels (uuid, task_id, label_id, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(input.label_id)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_task_labels", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

// ---------- todo_comments（仅 create） ----------

pub async fn create_todo_comment(pool: &SqlitePool, input: &TodoCommentCreateInput) -> CoreResult<TodoComment> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoComment>(
        "INSERT INTO todo_comments (uuid, task_id, content, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(&input.content)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_comments", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

// ---------- todo_task_relations（仅 create） ----------

pub async fn create_todo_task_relation(pool: &SqlitePool, input: &TodoTaskRelationCreateInput) -> CoreResult<TodoTaskRelation> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoTaskRelation>(
        "INSERT INTO todo_task_relations (uuid, task_id, other_task_id, relation_type, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(input.other_task_id).bind(&input.relation_type)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_task_relations", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

// ---------- todo_reminders（仅 create） ----------

pub async fn create_todo_reminder(pool: &SqlitePool, input: &TodoReminderCreateInput) -> CoreResult<TodoReminder> {
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoReminder>(
        "INSERT INTO todo_reminders (uuid, task_id, remind_at, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(input.remind_at)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_reminders", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

/// 辅助：emit DbEvent（有 uuid 的表通用）
fn emit_event(table: &str, id: i64, uuid: &str, op: DbOp, timestamp: i64) {
    EVENT_BUS.emit(DbEvent {
        table: table.into(),
        op,
        record_id: id,
        record_uuid: uuid.to_string(),
        payload: None,
        device_id: current_device_id(),
        timestamp,
    });
}

// =============================================================================
// 泛型 create/update（基于 JSON 字段，适用于 A 组 19 张业务表；tags/tag_relations 已移除）
// =============================================================================

/// 验证列名只含字母/数字/下划线，防止 SQL 注入
pub(crate) fn validate_column_name(name: &str) -> CoreResult<()> {
    if name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return Err(CoreError::Other(format!("invalid column name: {}", name)));
    }
    Ok(())
}

/// 将 JSON 值绑定到 QueryBuilder（自动按类型选择 sqlx 绑定方式）
pub(crate) fn push_json_value(
    q: &mut sqlx::QueryBuilder<'_, sqlx::Sqlite>,
    val: &serde_json::Value,
) {
    match val {
        serde_json::Value::Null => {
            q.push_bind(None::<String>);
        }
        serde_json::Value::Bool(b) => {
            q.push_bind(if *b { 1i32 } else { 0i32 });
        }
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                q.push_bind(i);
            } else if let Some(f) = n.as_f64() {
                q.push_bind(f);
            } else {
                q.push_bind(n.to_string());
            }
        }
        serde_json::Value::String(s) => {
            q.push_bind(s.clone());
        }
        _ => {
            q.push_bind(val.to_string());
        }
    }
}

/// 泛型创建：自动补充元数据字段（uuid/timestamps/version），
/// 业务字段从 JSON 对象提取。适用于 A 组业务表。
///
/// v1 全量同步直读业务表，无需入队 sync_queue。
/// 调用方负责 emit DbEvent（因泛型 T 无法直接访问 uuid 字段）。
pub async fn create_record_by_json<T>(
    pool: &SqlitePool,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<T>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin + serde::Serialize,
{
    let now = chrono::Utc::now().timestamp_millis();
    let new_uuid = uuid::Uuid::new_v4().to_string();

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
    q.push(table);
    // 元数据列
    q.push(" (uuid, is_deleted, created_at, updated_at, version");
    // 业务列
    for key in fields.keys() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
    }
    q.push(") VALUES (");
    // 元数据值
    q.push_bind(new_uuid.clone());
    q.push(", ");
    q.push_bind(0i32); // is_deleted
    q.push(", ");
    q.push_bind(now); // created_at
    q.push(", ");
    q.push_bind(now); // updated_at
    q.push(", ");
    q.push_bind(1i32); // version
    // 业务值
    for val in fields.values() {
        q.push(", ");
        push_json_value(&mut q, val);
    }
    q.push(") RETURNING *");

    let record = q.build_query_as::<T>().fetch_one(pool).await?;
    Ok(record)
}

/// 泛型创建（无返回值版本）：与 create_record_by_json 逻辑一致，
/// 但不使用 RETURNING *，避免需要具体类型 T: FromRow 的约束。
///
/// 适用于数据导入等不需要返回记录的场景：逐条插入时只需知道成功/失败。
/// v1 全量同步直读业务表，无需入队 sync_queue。
pub async fn create_record_by_json_void(
    pool: &SqlitePool,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let new_uuid = uuid::Uuid::new_v4().to_string();

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
    q.push(table);
    q.push(" (uuid, is_deleted, created_at, updated_at, version");
    for key in fields.keys() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
    }
    q.push(") VALUES (");
    q.push_bind(new_uuid.clone());
    q.push(", ");
    q.push_bind(0i32);
    q.push(", ");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(1i32);
    for val in fields.values() {
        q.push(", ");
        push_json_value(&mut q, val);
    }
    q.push(")");

    q.build().execute(pool).await?;

    // v1 全量同步直读业务表，无需入队 sync_queue
    Ok(())
}

/// 泛型更新：自动补充 updated_at + version+1，
/// 业务字段从 JSON 对象提取。适用于 A 组业务表。
///
/// v1 全量同步直读业务表，无需入队 sync_queue。
/// 调用方负责 emit DbEvent。
pub async fn update_record_by_json<T>(
    pool: &SqlitePool,
    table: &str,
    id: i64,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<T>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin + serde::Serialize,
{
    let now = chrono::Utc::now().timestamp_millis();

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("UPDATE ");
    q.push(table);
    q.push(" SET updated_at = ");
    q.push_bind(now);
    q.push(", version = version + 1");

    for (key, val) in fields.iter() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
        q.push(" = ");
        push_json_value(&mut q, val);
    }

    q.push(" WHERE id = ");
    q.push_bind(id);
    q.push(" RETURNING *");

    let record = q
        .build_query_as::<T>()
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("{} id={}", table, id)))?;

    // v1 全量同步直读业务表，无需入队 sync_queue
    Ok(record)
}

/// 泛型更新（无返回值版本）：与 update_record_by_json 逻辑一致，
/// 但不使用 RETURNING *，避免需要具体类型 T: FromRow 的约束。
///
/// 适用于数据导入等不需要返回记录的场景：overwrite 策略下批量更新时只需知道成功/失败。
/// v1 全量同步直读业务表，无需入队 sync_queue。
pub async fn update_record_by_json_void(
    pool: &SqlitePool,
    table: &str,
    id: i64,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("UPDATE ");
    q.push(table);
    q.push(" SET updated_at = ");
    q.push_bind(now);
    q.push(", version = version + 1");

    for (key, val) in fields.iter() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
        q.push(" = ");
        push_json_value(&mut q, val);
    }

    q.push(" WHERE id = ");
    q.push_bind(id);

    q.build().execute(pool).await?;

    Ok(())
}

/// 按 UUID 查询记录的 id（用于 bulk_import 冲突检测）
///
/// 返回 Some(id) 表示存在未删除记录，None 表示不存在或已软删除。
/// 仅适用于有 uuid + is_deleted 列的 A 组业务表。
pub async fn get_id_by_uuid(pool: &SqlitePool, table: &str, uuid: &str) -> CoreResult<Option<i64>> {
    let sql = format!(
        "SELECT id FROM {} WHERE uuid = ? AND is_deleted = 0 LIMIT 1",
        table
    );
    let row: Option<(i64,)> = sqlx::query_as(&sql).bind(uuid).fetch_optional(pool).await?;
    Ok(row.map(|(id,)| id))
}

// =============================================================================
// B 组表泛型 create/update（无 uuid，按需包含 is_deleted）
// =============================================================================

/// B 组表泛型创建：自动补充 created_at/updated_at/version，
/// 按需补充 uuid / is_deleted，业务字段从 JSON 提取。
/// 适用于系统表（phone_app_services / phone_app_bindings 等）。
/// `include_uuid=true` 时自动生成 uuid（要求表有 uuid 列）。
pub async fn create_record_by_json_b<T>(
    pool: &SqlitePool,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
    include_is_deleted: bool,
    include_uuid: bool,
) -> CoreResult<T>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let now = chrono::Utc::now().timestamp_millis();
    let new_uuid = if include_uuid {
        Some(uuid::Uuid::new_v4().to_string())
    } else {
        None
    };
    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
    q.push(table);
    q.push(" (created_at, updated_at, version");
    if include_uuid {
        q.push(", uuid");
    }
    if include_is_deleted {
        q.push(", is_deleted");
    }
    for key in fields.keys() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
    }
    q.push(") VALUES (");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(1i32);
    if let Some(u) = &new_uuid {
        q.push(", ");
        q.push_bind(u);
    }
    if include_is_deleted {
        q.push(", ");
        q.push_bind(0i32);
    }
    for val in fields.values() {
        q.push(", ");
        push_json_value(&mut q, val);
    }
    q.push(") RETURNING *");

    let record = q.build_query_as::<T>().fetch_one(pool).await?;
    Ok(record)
}

/// B 组表泛型更新：自动补充 updated_at + version+1，
/// 业务字段从 JSON 提取。适用于系统表。
pub async fn update_record_by_json_b<T>(
    pool: &SqlitePool,
    table: &str,
    id: i64,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> CoreResult<T>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let now = chrono::Utc::now().timestamp_millis();
    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("UPDATE ");
    q.push(table);
    q.push(" SET updated_at = ");
    q.push_bind(now);
    q.push(", version = version + 1");

    for (key, val) in fields.iter() {
        validate_column_name(key)?;
        q.push(", ");
        q.push(key);
        q.push(" = ");
        push_json_value(&mut q, val);
    }

    q.push(" WHERE id = ");
    q.push_bind(id);
    q.push(" RETURNING *");

    let record = q
        .build_query_as::<T>()
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("{} id={}", table, id)))?;
    Ok(record)
}

// =============================================================================
// 单元测试
// =============================================================================

#[cfg(test)]
mod tests {
    use super::{build_keyword_clause, searchable_fields};

    /// 白名单表应返回非空字段列表
    #[test]
    fn searchable_fields_returns_fields_for_known_table() {
        let fields = searchable_fields("rec_books");
        assert!(!fields.is_empty(), "rec_books 应支持 keyword 搜索");
        assert!(fields.contains(&"title"));
        assert!(fields.contains(&"authors"));
    }

    /// 未知表返回空切片（不支持 keyword 搜索，但不崩溃）
    #[test]
    fn searchable_fields_returns_empty_for_unknown_table() {
        let fields = searchable_fields("unknown_table_xyz");
        assert!(fields.is_empty());
    }

    /// 空 keyword 应返回空子句（无 SQL 拼接、无绑定参数）
    #[test]
    fn build_keyword_clause_empty_when_no_keyword() {
        let clause = build_keyword_clause("rec_books", None);
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());

        let clause = build_keyword_clause("rec_books", Some(""));
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());

        let clause = build_keyword_clause("rec_books", Some("   "));
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());
    }

    /// 未知表即使有 keyword 也返回空子句（无搜索字段）
    #[test]
    fn build_keyword_clause_empty_for_unknown_table() {
        let clause = build_keyword_clause("unknown_table_xyz", Some("hello"));
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());
    }

    /// 已知表 + 非空 keyword 应生成 " AND (f1 LIKE ? OR f2 LIKE ? ...)" 子句
    /// 且绑定参数数量与字段数一致
    #[test]
    fn build_keyword_clause_generates_or_clause_for_known_table() {
        let clause = build_keyword_clause("rec_books", Some("三体"));
        let fields = searchable_fields("rec_books");

        assert!(!clause.clause.is_empty());
        assert!(clause.clause.starts_with(" AND ("));
        assert!(clause.clause.ends_with(")"));
        // 应包含 " OR " 分隔符（字段数 > 1 时）
        if fields.len() > 1 {
            assert!(clause.clause.contains(" OR "));
        }
        // 绑定参数数量应与字段数一致，且全部为 "%keyword%" 格式
        assert_eq!(clause.bindings.len(), fields.len());
        for binding in &clause.bindings {
            assert!(binding.starts_with("%") && binding.ends_with("%"));
            assert!(binding.contains("三体"));
        }
    }

    /// keyword 应被 trim 后再拼入 LIKE 模式
    #[test]
    fn build_keyword_clause_trims_keyword() {
        let clause = build_keyword_clause("rec_books", Some("  abc  "));
        for binding in &clause.bindings {
            assert_eq!(binding, "%abc%");
        }
    }
}
