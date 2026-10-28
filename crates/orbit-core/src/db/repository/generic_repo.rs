//! generic_repo — 泛型仓储辅助
//!
//! 为 21 张表提供模式统一的 list/get/soft_delete 实现，避免每表重复代码。
//! create/update 因字段差异大，由各表 typed 函数承担（todo_projects / todo_tasks /
//! todo_subtasks / todo_labels / todo_comments 等），其余表走 create_record_by_json 泛型入口。
//!
//! 设计依据：写操作后 emit DbEvent。
//! 泛型函数同样在写操作后 emit 事件，保证响应式数据流一致。

use sqlx::SqlitePool;

use crate::context;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::{
    BoardGroupBy, ListCursor, ListFilter, TodoComment, TodoCommentCreateInput, TodoLabel,
    TodoLabelCreateInput, TodoLabelUpdateInput, TodoProject, TodoProjectCreateInput,
    TodoProjectUndone, TodoProjectUpdateInput, TodoReminder, TodoReminderCreateInput, TodoSubtask,
    TodoSubtaskCreateInput, TodoSubtaskUpdateInput, TodoTask, TodoTaskBoard, TodoTaskBoardGroup,
    TodoTaskCreateInput, TodoTaskLabel, TodoTaskLabelCreateInput, TodoTaskListItem,
    TodoTaskOverview, TodoTaskPage, TodoTaskRelation, TodoTaskRelationCreateInput,
    TodoTaskUpdateInput,
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

/// todo_tasks 列表通道列清单（批2 + 内存治理 A2）：与
/// [`TodoTaskListItem`](crate::models::business::TodoTaskListItem) 字段严格
/// 一一对应，行形状不匹配会让 `FromRow` 直接解码失败。
///
/// 列名外的 10 列（`uuid`、`repeat_after`、六个更细的 `repeat_*`、
/// `deleted_at`、`version`）已从列表通道 DTO 里整体移除——它们的键名本身
/// 就是开销，占位表达式省不掉，故改走独立瘦行 DTO；消费边界与被移除列的
/// 核实结论见该 struct 的文档注释。
///
/// `{desc}` 占位由 [task_list_columns] 按通道替换：
/// - keyword 空（列表主通道）→ `NULL AS description`：万级列表实测
///   description 占 IPC 序列化体积 47%（1KB/行），四视图与移动列表零消费；
/// - keyword 非空（搜索通道）→ `description AS description`：桌面面板命中集
///   落地前还要按描述做一次本地收敛（`task-panel.tsx` 的 placeholder
///   二次过滤），描述原文必须过桥——否则「按描述搜索」会静默丢结果
///   （A2 前置修复的教训，见 docs/09 §4.3）。
///
/// 字段顺序与 0001 迁移列序一致（可读性；SQLite 按名绑定）。
const LIST_COLUMNS_TASKS: &str = "id, title, {desc} AS description, project_id, priority, \
    status, done, done_at, due_date, start_date, repeat_mode, percent_done, position, \
    is_favorite, my_day_date, duration_minutes, is_deleted, created_at, updated_at";

/// 按通道拼 todo_tasks 列表列清单（见 [LIST_COLUMNS_TASKS]）。
fn task_list_columns(with_description: bool) -> String {
    LIST_COLUMNS_TASKS.replace(
        "{desc}",
        if with_description {
            "description"
        } else {
            "NULL"
        },
    )
}

/// 泛型分页列表查询：SELECT <列> FROM {table} WHERE is_deleted=0
///     [AND (field1 LIKE ? OR field2 LIKE ? ...)]
///     [AND todo_tasks 谓词下推子句（done/status/priority_min/project_id/
///      favorite_only/my_day_today）]
///     ORDER BY updated_at DESC LIMIT ? OFFSET ?
///
/// 当 filter.keyword 非空时，按 [searchable_fields] 返回的字段白名单拼接 LIKE OR 子句。
/// 谓词字段仅 todo_tasks 表消费（其他表结构无这些列，忽略不报错——
/// 调用方混用属契约错误，但基线是不静默丢数据所以选择忽略）。
/// 调用方需保证 T: sqlx::FromRow 且表结构匹配。
///
/// todo_tasks 列裁剪（批2 + 内存治理 A2）：列表通道只过瘦行列
/// [`TodoTaskListItem`](crate::models::business::TodoTaskListItem)
/// （清单与理由见 [LIST_COLUMNS_TASKS]）——10 个列表通道零消费列整体移除，
/// description 的**值**在无 keyword 时以 `NULL` 占位不传输（万级实测占 IPC
/// 体积 47%）；keyword 非空时 description 回真值（搜索通道本地收敛需要）。
/// 详情 `get_todo_task_detail` / `get_by_id` / 同步 / 回收站单条路径保持全列。
pub async fn list<T>(pool: &SqlitePool, table: &str, filter: &ListFilter) -> CoreResult<Vec<T>>
where
    T: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> + Send + Unpin,
{
    let page_size = if filter.page_size == 0 {
        20
    } else {
        filter.page_size
    } as i32;
    // offset 须用规范化后的 page_size（此前用原始 filter.page_size：
    // page_size=0 的默认 20 档第 2 页起 offset 恒 0，所有页都返第一页数据）
    let offset = (filter.page.saturating_sub(1)).saturating_mul(page_size.max(1) as u32) as i32;

    // 拼接 keyword 过滤子句：仅在 keyword 非空且表有可搜索字段时生效
    let keyword_clause = build_keyword_clause(table, filter.keyword.as_deref());
    // 谓词下推子句（仅 todo_tasks；占位符按声明顺序绑定）
    let predicate_clause = build_task_predicate_clause(table, filter);
    // 归档项目任务排除（仅 todo_tasks 的聚合视图；project_id / project_ids 谓词 =
    // 用户主动选中该项目（或其父清单）时放行——归档区点击进项目视图仍可读任务，
    // 对齐「归档=从默认列表收起，不是软删」语义）
    let archived_exclude_clause =
        if table == "todo_tasks" && filter.project_id.is_none() && filter.project_ids.is_none() {
            " AND (project_id IS NULL OR project_id NOT IN \
           (SELECT id FROM todo_projects WHERE is_deleted = 0 AND is_archived = 1))"
        } else {
            ""
        };
    // 列裁剪（批2 + A2）：todo_tasks 列表通道只过瘦行列；description 仅在
    // keyword 通道回真值（桌面搜索的本地收敛分支要读原文）
    let pruned_columns;
    let select_expr = if table == "todo_tasks" {
        pruned_columns = task_list_columns(!keyword_clause.clause.is_empty());
        pruned_columns.as_str()
    } else {
        "*"
    };

    let sql = format!(
        "SELECT {} FROM {} WHERE is_deleted = 0{}{}{} ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        select_expr, table, keyword_clause.clause, predicate_clause.clause, archived_exclude_clause,
    );

    let mut q = sqlx::query_as::<_, T>(&sql);
    // 绑定 keyword 参数（每个可搜索字段绑定一次 %keyword%）
    for value in keyword_clause.bindings {
        q = q.bind(value);
    }
    // 绑定谓词参数：status 文本先（子句中占位符在数值谓词前），后数值按声明序
    if let Some(status) = predicate_clause.status_binding {
        q = q.bind(status);
    }
    for value in predicate_clause.bindings {
        q = q.bind(value);
    }
    q = q.bind(page_size);
    q = q.bind(offset);

    let items = q.fetch_all(pool).await?;
    Ok(items)
}

// =============================================================================
// 任务键集分页（P1 50k 规模档）
// =============================================================================

/// 分页通道支持的排序键。
///
/// 只覆盖能**在 SQL 里精确定序**的档位；`title` 档由前端用
/// `localeCompare("zh-Hans-CN")` 排中文拼音序，SQLite 的 BINARY collation
/// 复刻不了（见 [ListFilter::sort_key] 注释），故不进本枚举。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TaskSortKey {
    /// 拖拽顺序：position 升序（方向不生效，与前端 manual 档一致）
    Manual,
    /// 截止时间：无截止恒沉底，其余按方向
    Due,
    /// 优先级：默认降序，同值回落 position 升序
    Priority,
    /// 创建时间：默认降序
    Created,
    /// 完成时间（Logbook 通道）：无完成时间恒沉底，默认降序
    DoneAt,
}

impl TaskSortKey {
    fn parse(raw: Option<&str>) -> CoreResult<Self> {
        match raw.map(str::trim).filter(|s| !s.is_empty()) {
            None | Some("manual") => Ok(Self::Manual),
            Some("due") => Ok(Self::Due),
            Some("priority") => Ok(Self::Priority),
            Some("created") => Ok(Self::Created),
            Some("done_at") => Ok(Self::DoneAt),
            Some("title") => Err(CoreError::Other(
                "title 排序不支持键集分页（中文拼音序无法在 SQL 侧复刻），请走全量通道".into(),
            )),
            Some(other) => Err(CoreError::Other(format!("未知排序键: {other}"))),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Due => "due",
            Self::Priority => "priority",
            Self::Created => "created",
            Self::DoneAt => "done_at",
        }
    }

    /// 该档在某方向下是否降序（None = 该档默认方向，与前端 BASE_SORT_DIR 一致）
    fn is_desc(self, raw: Option<&str>) -> bool {
        match raw.map(str::trim) {
            Some("asc") => false,
            Some("desc") => true,
            _ => matches!(self, Self::Priority | Self::Created | Self::DoneAt),
        }
    }

    /// ORDER BY 片段。manual 忽略方向（拖拽顺序的唯一语义是 position 升序）。
    fn order_by(self, desc: bool) -> &'static str {
        match (self, desc) {
            (Self::Manual, _) => "ORDER BY position ASC, id ASC",
            (Self::Due, false) => "ORDER BY (due_date IS NULL) ASC, due_date ASC, id ASC",
            (Self::Due, true) => "ORDER BY (due_date IS NULL) ASC, due_date DESC, id DESC",
            (Self::Priority, false) => "ORDER BY priority ASC, position ASC, id ASC",
            (Self::Priority, true) => "ORDER BY priority DESC, position ASC, id ASC",
            (Self::Created, false) => "ORDER BY created_at ASC, id ASC",
            (Self::Created, true) => "ORDER BY created_at DESC, id DESC",
            (Self::DoneAt, false) => "ORDER BY (done_at IS NULL) ASC, done_at ASC, id ASC",
            (Self::DoneAt, true) => "ORDER BY (done_at IS NULL) ASC, done_at DESC, id DESC",
        }
    }
}

/// 绑定值（分页 WHERE 的占位符参数类型不统一，按声明顺序入列）
#[derive(Clone)]
enum BindVal {
    Text(String),
    Int(i64),
    Real(f64),
}

/// 任务查询的 WHERE 拼装结果（分页与聚合共用同一口径）
struct TaskWhere {
    /// 以 " AND ..." 开头的子句串
    clause: String,
    binds: Vec<BindVal>,
}

/// 构造任务查询的 WHERE（软删基线 + keyword + 谓词 + 截止区间 + 归档排除 + 游标）。
///
/// 参数顺序与 `clause` 中 `?` 的出现顺序严格一致：keyword 各字段 →
/// status 文本 → 谓词数值 → due 区间 → 游标。
fn build_task_where(
    filter: &ListFilter,
    sort: TaskSortKey,
    desc: bool,
    cursor: Option<&ListCursor>,
) -> TaskWhere {
    let keyword_clause = build_keyword_clause("todo_tasks", filter.keyword.as_deref());
    let predicate_clause = build_task_predicate_clause("todo_tasks", filter);
    let archived_exclude_clause = if filter.project_id.is_none() && filter.project_ids.is_none() {
        " AND (project_id IS NULL OR project_id NOT IN \
             (SELECT id FROM todo_projects WHERE is_deleted = 0 AND is_archived = 1))"
    } else {
        ""
    };

    let mut clause = String::new();
    let mut binds = Vec::new();

    clause.push_str(&keyword_clause.clause);
    for value in keyword_clause.bindings {
        binds.push(BindVal::Text(value));
    }
    if let Some(status) = predicate_clause.status_binding {
        binds.push(BindVal::Text(status));
    }
    clause.push_str(&predicate_clause.clause);
    for value in predicate_clause.bindings {
        binds.push(BindVal::Int(value));
    }

    if let Some(from) = filter.due_from {
        clause.push_str(" AND due_date >= ?");
        binds.push(BindVal::Int(from));
    }
    if let Some(to) = filter.due_to {
        clause.push_str(" AND due_date < ?");
        binds.push(BindVal::Int(to));
    }
    // 开始时间范围（日历时间轴按块起点取数）：NULL 不命中，与 due 区间同口径
    if let Some(from) = filter.start_from {
        clause.push_str(" AND start_date >= ?");
        binds.push(BindVal::Int(from));
    }
    if let Some(to) = filter.start_to {
        clause.push_str(" AND start_date < ?");
        binds.push(BindVal::Int(to));
    }
    // 逾期行已由置顶段的独立查询取走：主列表排除它们但保留无截止行
    if let Some(before) = filter.exclude_due_before {
        clause.push_str(" AND (due_date IS NULL OR due_date >= ?)");
        binds.push(BindVal::Int(before));
    }

    clause.push_str(archived_exclude_clause);

    if let Some(c) = cursor {
        let (frag, cursor_binds) = cursor_predicate(sort, desc, c);
        clause.push_str(&frag);
        binds.extend(cursor_binds);
    }

    TaskWhere { clause, binds }
}

/// 游标比较谓词：「严格位于游标之后」的行。
///
/// 每个档位手写而非用行值比较：`priority` 档是「主键降序 + 次键升序」的混合
/// 方向，`due` 档还要把 NULL 尾段整体排在游标之后——行值比较表达不了。
fn cursor_predicate(sort: TaskSortKey, desc: bool, c: &ListCursor) -> (String, Vec<BindVal>) {
    let mut binds = Vec::new();
    let frag = match sort {
        TaskSortKey::Manual => {
            let pos = c.key.unwrap_or(0.0);
            binds.push(BindVal::Real(pos));
            binds.push(BindVal::Real(pos));
            binds.push(BindVal::Int(c.id));
            " AND (position > ? OR (position = ? AND id > ?))".to_string()
        }
        TaskSortKey::Created => {
            let ts = c.key.unwrap_or(0.0);
            binds.push(BindVal::Real(ts));
            binds.push(BindVal::Real(ts));
            binds.push(BindVal::Int(c.id));
            if desc {
                " AND (created_at < ? OR (created_at = ? AND id < ?))".to_string()
            } else {
                " AND (created_at > ? OR (created_at = ? AND id > ?))".to_string()
            }
        }
        TaskSortKey::Priority => {
            let pri = c.key.unwrap_or(0.0);
            let pos = c.key2.unwrap_or(0.0);
            binds.push(BindVal::Real(pri));
            binds.push(BindVal::Real(pri));
            binds.push(BindVal::Real(pos));
            binds.push(BindVal::Real(pos));
            binds.push(BindVal::Int(c.id));
            let cmp = if desc { "<" } else { ">" };
            format!(
                " AND (priority {cmp} ? OR (priority = ? AND \
                 (position > ? OR (position = ? AND id > ?))))"
            )
        }
        TaskSortKey::Due => {
            let cmp = if desc { "<" } else { ">" };
            match c.key {
                // 已进入「无截止」尾段：只剩同段内 id 顺序
                None => {
                    binds.push(BindVal::Int(c.id));
                    format!(" AND (due_date IS NULL AND id {cmp} ?)")
                }
                // 有截止值：无截止行整体在后，或截止值更靠后，或同值比 id
                Some(due) => {
                    binds.push(BindVal::Real(due));
                    binds.push(BindVal::Real(due));
                    binds.push(BindVal::Int(c.id));
                    format!(
                        " AND (due_date IS NULL OR due_date {cmp} ? OR \
                         (due_date = ? AND id {cmp} ?))"
                    )
                }
            }
        }
        // 与 Due 同构：NULL 尾段（历史数据可能没写 done_at）整体沉底
        TaskSortKey::DoneAt => {
            let cmp = if desc { "<" } else { ">" };
            match c.key {
                None => {
                    binds.push(BindVal::Int(c.id));
                    format!(" AND (done_at IS NULL AND id {cmp} ?)")
                }
                Some(at) => {
                    binds.push(BindVal::Real(at));
                    binds.push(BindVal::Real(at));
                    binds.push(BindVal::Int(c.id));
                    format!(
                        " AND (done_at IS NULL OR done_at {cmp} ? OR \
                         (done_at = ? AND id {cmp} ?))"
                    )
                }
            }
        }
    };
    (frag, binds)
}

/// 从一行任务构造下一页游标（key/key2 按排序档取对应列）
fn cursor_from_task(
    sort: TaskSortKey,
    sort_str: &str,
    dir_str: &str,
    t: &TodoTaskListItem,
) -> ListCursor {
    let (key, key2) = match sort {
        TaskSortKey::Manual => (Some(t.position), None),
        TaskSortKey::Due => (t.due_date.map(|v| v as f64), None),
        TaskSortKey::Priority => (Some(t.priority as f64), Some(t.position)),
        TaskSortKey::Created => (Some(t.created_at as f64), None),
        // 游标里 done_at 可能为空（历史数据）——真实空值不能折成 0，
        // 否则会落进「有完成时间」段而不是 NULL 尾段
        TaskSortKey::DoneAt => (t.done_at.map(|v| v as f64), None),
    };
    ListCursor {
        sort_key: sort_str.to_string(),
        dir: dir_str.to_string(),
        key,
        key2,
        id: t.id,
    }
}

/// 任务键集分页查询（P1 50k 规模档）。
///
/// 与 [list] 的区别：排序键下推到 SQL（四档）、用游标代替 OFFSET、返回
/// `has_more` 与下一页游标。`limit` 上限 1000（窗口化首屏 200～500 足够；
/// 大值只会让单次 IPC 传输变大，失去窗口化意义）。
///
/// 游标与当前排序档不一致时返回**空页**（`has_more = false`）：调用方换了
/// 排序却沿用旧游标属于正常的 UI 竞态（用户快速切档），让它自然收敛比报错好。
pub async fn list_tasks_page(
    pool: &SqlitePool,
    filter: &ListFilter,
    cursor: Option<&ListCursor>,
    limit: u32,
) -> CoreResult<TodoTaskPage> {
    let sort = TaskSortKey::parse(filter.sort_key.as_deref())?;
    let desc = sort.is_desc(filter.sort_dir.as_deref());
    let dir_str = if sort == TaskSortKey::Manual {
        "asc"
    } else if desc {
        "desc"
    } else {
        "asc"
    };
    let sort_str = sort.as_str();
    let limit = limit.clamp(1, 1000) as i64;

    // 换档即作废：游标记录的排序档与本次请求不一致，说明是竞态下的旧游标
    if cursor.is_some_and(|c| c.sort_key != sort_str || c.dir != dir_str) {
        return Ok(TodoTaskPage {
            items: Vec::new(),
            next_cursor: None,
            has_more: false,
        });
    }

    let where_clause = build_task_where(filter, sort, desc, cursor);
    let has_keyword = filter
        .keyword
        .as_deref()
        .map(str::trim)
        .is_some_and(|k| !k.is_empty());
    let select_expr = task_list_columns(has_keyword);
    let sql = format!(
        "SELECT {} FROM todo_tasks WHERE is_deleted = 0{} {} LIMIT ?",
        select_expr,
        where_clause.clause,
        sort.order_by(desc),
    );

    let mut q = sqlx::query_as::<_, TodoTaskListItem>(&sql);
    for bind in where_clause.binds {
        q = match bind {
            BindVal::Text(v) => q.bind(v),
            BindVal::Int(v) => q.bind(v),
            BindVal::Real(v) => q.bind(v),
        };
    }
    // 多取一条用于判定 has_more（比再发一次 COUNT 便宜）
    q = q.bind(limit + 1);
    let mut rows = q.fetch_all(pool).await?;

    let has_more = rows.len() as i64 > limit;
    if has_more {
        rows.truncate(limit as usize);
    }
    let next_cursor = if has_more {
        rows.last()
            .map(|t| cursor_from_task(sort, sort_str, dir_str, t))
    } else {
        None
    };
    Ok(TodoTaskPage {
        items: rows,
        next_cursor,
        has_more,
    })
}

/// 任务总览聚合（P1 窗口化后侧栏计数/总数的唯一来源）。
///
/// `total` 与分页共用同一套谓词（keyword/项目/完成态/截止区间/归档排除），
/// 但忽略游标与 limit；`undone_by_project` 是**全局口径**（不看当前视图谓词，
/// 与旧侧栏计数"从当前视图任务聚合"的错误行为解耦——切到「我的一天」时其它
/// 项目的角标不该归零）。
pub async fn task_overview(pool: &SqlitePool, filter: &ListFilter) -> CoreResult<TodoTaskOverview> {
    // total
    let where_clause = build_task_where(filter, TaskSortKey::Manual, false, None);
    let sql = format!(
        "SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0{}",
        where_clause.clause
    );
    let mut q = sqlx::query_as::<_, (i64,)>(&sql);
    for bind in where_clause.binds {
        q = match bind {
            BindVal::Text(v) => q.bind(v),
            BindVal::Int(v) => q.bind(v),
            BindVal::Real(v) => q.bind(v),
        };
    }
    let (total,) = q.fetch_one(pool).await?;

    // 侧栏未完成计数（全局，不含归档项目任务）
    let rows: Vec<(Option<i64>, i64)> = sqlx::query_as(
        "SELECT project_id, COUNT(*) FROM todo_tasks \
         WHERE is_deleted = 0 AND done = 0 AND \
         (project_id IS NULL OR project_id NOT IN \
          (SELECT id FROM todo_projects WHERE is_deleted = 0 AND is_archived = 1)) \
         GROUP BY project_id",
    )
    .fetch_all(pool)
    .await?;

    Ok(TodoTaskOverview {
        total,
        undone_by_project: rows
            .into_iter()
            .map(|(project_id, count)| TodoProjectUndone { project_id, count })
            .collect(),
    })
}

/// 看板/四象限分组表达式（列键与桌面 `kanbanColumnKey` 逐字一致）。
///
/// `day_start` 是本地今日零点（due 五分桶的界），`day_end` 是今日 24:00
/// （四象限的「紧急」界 = 今天以内到期，含逾期）。两者都由调用方按本地
/// 时区算好传入——Rust 侧不重复做日界换算以免口径分裂。
fn board_group_expr(
    group_by: BoardGroupBy,
    day_start: i64,
    day_end: i64,
) -> (String, Vec<BindVal>) {
    const DAY: i64 = 86_400_000;
    match group_by {
        BoardGroupBy::Project => (
            "CASE WHEN project_id IS NULL THEN 'ungrouped' ELSE CAST(project_id AS TEXT) END"
                .into(),
            Vec::new(),
        ),
        BoardGroupBy::Status => (
            "CASE WHEN status IN ('doing', 'done') THEN status ELSE 'pending' END".into(),
            Vec::new(),
        ),
        BoardGroupBy::Priority => (
            "'pri:' || (CASE WHEN priority BETWEEN 0 AND 5 THEN priority ELSE 0 END)".into(),
            Vec::new(),
        ),
        BoardGroupBy::Due => (
            "'due:' || (CASE WHEN due_date IS NULL THEN 'none' \
             WHEN due_date < ? THEN 'overdue' \
             WHEN due_date < ? THEN 'today' \
             WHEN due_date < ? THEN 'week' ELSE 'later' END)"
                .into(),
            vec![
                BindVal::Int(day_start),
                BindVal::Int(day_start + DAY),
                BindVal::Int(day_start + 7 * DAY),
            ],
        ),
        BoardGroupBy::Quadrant => (
            "CASE WHEN due_date IS NOT NULL AND due_date < ? THEN \
               (CASE WHEN priority >= 3 THEN 'urgentImportant' ELSE 'urgentNotImportant' END) \
             ELSE (CASE WHEN priority >= 3 THEN 'importantNotUrgent' ELSE 'neither' END) END"
                .into(),
            vec![BindVal::Int(day_end)],
        ),
    }
}

/// 把 [BindVal] 绑到查询上（类型按值分支，`QueryAs` 三个参数原样透传）
fn bind_val<'q, O>(
    q: sqlx::query::QueryAs<'q, sqlx::Sqlite, O, sqlx::sqlite::SqliteArguments<'q>>,
    v: BindVal,
) -> sqlx::query::QueryAs<'q, sqlx::Sqlite, O, sqlx::sqlite::SqliteArguments<'q>>
where
    O: for<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow>,
{
    match v {
        BindVal::Text(s) => q.bind(s),
        BindVal::Int(i) => q.bind(i),
        BindVal::Real(f) => q.bind(f),
    }
}

/// 看板/四象限窗口化查询：一次往返取「每列前 N 条 + 每列总数」。
///
/// 不用窗口函数一次查完的原因：`TodoTaskListItem` 有 18 列，`ROW_NUMBER()`
/// 会给每行多带附加列、解码要手写 18 次 `try_get`；而实际有任务的组数
/// （= 看板列数）通常个位数到十几个，`GROUP BY` + 逐组 `LIMIT` 的总成本
/// 反而更低，且每组都是同一索引前缀上的有序扫描。
///
/// 组键口径与桌面 `kanbanColumnKey` 逐字一致；`quadrant` 强制只看未完成
/// （`groupEisenhower` 跳过 done 行），其余维度沿用调用方 `done` 谓词。
pub async fn task_board(
    pool: &SqlitePool,
    filter: &ListFilter,
    group_by: BoardGroupBy,
    limit_per_group: u32,
    day_start: i64,
    day_end: i64,
) -> CoreResult<TodoTaskBoard> {
    let filter = filter.clone();
    // 四象限与前端 groupEisenhower 一致：只看未完成。用**追加 AND** 而不是
    // 覆盖 `filter.done`——用户显式筛「已完成」时结果应为空（前端同一行为），
    // 覆盖会把它悄悄变回「全部未完成」。
    let quadrant_clause = if group_by == BoardGroupBy::Quadrant {
        " AND done = 0"
    } else {
        ""
    };
    let (expr, expr_binds) = board_group_expr(group_by, day_start, day_end);
    let where_clause = build_task_where(&filter, TaskSortKey::Manual, false, None);

    // 1) 组键 + 组总数（不受 limit 影响，供「还有 N 条」与列头角标）
    let sql = format!(
        "SELECT {expr} AS g, COUNT(*) FROM todo_tasks \
         WHERE is_deleted = 0{}{quadrant_clause} GROUP BY g ORDER BY g",
        where_clause.clause
    );
    let mut q = sqlx::query_as::<_, (String, i64)>(&sql);
    for bind in where_clause
        .binds
        .iter()
        .cloned()
        .chain(expr_binds.iter().cloned())
    {
        q = bind_val(q, bind);
    }
    let counts = q.fetch_all(pool).await?;

    // 2) 每组前 N 条（列内沿用工具栏排序档）
    let sort = TaskSortKey::parse(filter.sort_key.as_deref())?;
    let desc = sort.is_desc(filter.sort_dir.as_deref());
    let order = sort.order_by(desc);
    let has_keyword = filter
        .keyword
        .as_deref()
        .map(|k| !k.trim().is_empty())
        .unwrap_or(false);
    let cols = task_list_columns(has_keyword);
    let limit = limit_per_group.clamp(1, 200) as i64;
    let mut groups = Vec::with_capacity(counts.len());
    let mut total = 0i64;
    for (key, count) in counts {
        total += count;
        let sql = format!(
            "SELECT {cols} FROM todo_tasks WHERE is_deleted = 0{}{quadrant_clause} \
             AND ({expr}) = ? {order} LIMIT ?",
            where_clause.clause
        );
        let mut q = sqlx::query_as::<_, TodoTaskListItem>(&sql);
        for bind in where_clause
            .binds
            .iter()
            .cloned()
            .chain(expr_binds.iter().cloned())
        {
            q = bind_val(q, bind);
        }
        q = q.bind(key.clone()).bind(limit);
        let items = q.fetch_all(pool).await?;
        groups.push(TodoTaskBoardGroup {
            key,
            total: count,
            items,
        });
    }
    Ok(TodoTaskBoard { groups, total })
}

/// 关键词过滤子句构造结果
struct KeywordClause {
    /// SQL 子句文本（如 " AND (title LIKE ? OR author LIKE ?)"），无 keyword 时为空串
    clause: String,
    /// 绑定参数值列表（每个字段一个 "%keyword%" 字符串）
    bindings: Vec<String>,
}

/// 谓词下推子句构造结果（2026-09-12 F5，仅 todo_tasks 消费）
struct TaskPredicateClause {
    /// SQL 子句文本（如 " AND done = 0 AND priority >= ?"），无谓词时为空串
    clause: String,
    /// 数值绑定（与子句占位符声明顺序一致；status 文本绑定单列）
    bindings: Vec<i64>,
    /// status 文本绑定（单独通道——TEXT 列绑 INTEGER 在 SQLite 比较不命中）
    status_binding: Option<String>,
}

/// 拼接 todo_tasks 的谓词下推子句（其他表返回空——结构上没有这些列）。
///
/// 语义对齐前端 filterTasks：done/status/priority_min/project_id/
/// favorite_only/my_day_today（零点值由调用方传入）。
///
/// 保存筛选器相关键（label_ids 任一 / has_reminder / has_attachment /
/// has_open_subtask / created_from / done_from）也在这里下推——它们与本文件
/// `list` / `list_tasks_page` / `task_overview` / `task_board` 共用同一份
/// 子句，故窗口化通道与全量通道的谓词面不会分叉。
fn build_task_predicate_clause(table: &str, filter: &ListFilter) -> TaskPredicateClause {
    if table != "todo_tasks" {
        return TaskPredicateClause {
            clause: String::new(),
            bindings: Vec::new(),
            status_binding: None,
        };
    }
    let mut clause = String::new();
    let mut bindings = Vec::new();
    let mut status_binding = None;
    if let Some(done) = filter.done {
        clause.push_str(if done {
            " AND done = 1"
        } else {
            " AND done = 0"
        });
    }
    // 状态集合（工具栏多选档，2026-10-28）：集合优先于等值，与 project_ids
    // 同一优先级规则。判定口径 = 派生状态（脏值回落 pending，与看板 status
    // 列同源）：拖拽/导入留下的未知 status 在「待办」档也要能被筛到，否则
    // 那些行在任何档位都不可见。`done` 档额外放行 done = 1（完成态老数据兼容）。
    //
    // 值域白名单（pending/doing/done）过滤后**字面量内联**：派生状态只可能是
    // 这三档，未知名本来就命中不到任何行；内联免掉一条文本绑定通道。
    let has_status_in = filter.status_in.as_deref().is_some_and(|s| !s.is_empty());
    if has_status_in {
        let states = filter.status_in.as_deref().unwrap_or_default();
        let mut plain: Vec<&str> = Vec::new();
        let mut wants_done = false;
        for s in states {
            match s.as_str() {
                "done" => wants_done = true,
                "pending" | "doing" => {
                    if !plain.contains(&s.as_str()) {
                        plain.push(s.as_str());
                    }
                }
                _ => {}
            }
        }
        let mut terms: Vec<String> = Vec::new();
        if !plain.is_empty() {
            let list = plain
                .iter()
                .map(|s| format!("'{s}'"))
                .collect::<Vec<_>>()
                .join(", ");
            terms.push(format!(
                "(CASE WHEN status IN ('doing', 'done') THEN status ELSE 'pending' END) IN ({list})"
            ));
        }
        if wants_done {
            terms.push("(done = 1 OR status = 'done')".to_string());
        }
        if !terms.is_empty() {
            clause.push_str(&format!(" AND ({})", terms.join(" OR ")));
        }
    }
    if !has_status_in {
        if let Some(status) = filter.status.clone() {
            clause.push_str(" AND status = ?");
            status_binding = Some(status);
        }
    }
    if let Some(min) = filter.priority_min {
        clause.push_str(" AND priority >= ?");
        bindings.push(min as i64);
    }
    // 项目谓词：集合优先于等值（M8+ 清单文件夹聚合——选中父清单时客户端把
    // 「自身 + 全部后代项目 id」算好传 project_ids；两者同时给出时只认集合）
    if let Some(ids) = filter.project_ids.as_deref() {
        if ids.is_empty() {
            // 空集合 = 该视图不覆盖任何项目 → 空结果。**不能退化成「不加子句」**
            // （那会变成全量），故写恒假条件。
            clause.push_str(" AND 1 = 0");
        } else {
            clause.push_str(" AND project_id IN (");
            for (i, id) in ids.iter().enumerate() {
                if i > 0 {
                    clause.push_str(", ");
                }
                clause.push('?');
                bindings.push(*id);
            }
            clause.push(')');
        }
    } else if let Some(pid) = filter.project_id {
        clause.push_str(" AND project_id = ?");
        bindings.push(pid);
    }
    if filter.favorite_only == Some(true) {
        clause.push_str(" AND is_favorite = 1");
    }
    if let Some(zero) = filter.my_day_today {
        clause.push_str(" AND my_day_date = ?");
        bindings.push(zero);
    }
    // 未分组视图（P1 窗口化下推）：project_id IS NULL，无绑定
    if filter.ungrouped == Some(true) {
        clause.push_str(" AND project_id IS NULL");
    }
    // 优先级等值（工具栏单值档）
    if let Some(p) = filter.priority_eq {
        clause.push_str(" AND priority = ?");
        bindings.push(p as i64);
    }
    // 是否有截止（日历「未排期」区用）：false = due_date IS NULL
    match filter.has_due {
        Some(true) => clause.push_str(" AND due_date IS NOT NULL"),
        Some(false) => clause.push_str(" AND due_date IS NULL"),
        None => {}
    }
    // 标签任一命中（保存筛选器 label_ids / 列表内标签筛选）：用 EXISTS 子查询
    // 而非 JOIN——列表通道是单表投影，JOIN 会让多标签任务产生重复行，翻页
    // 边界与去重都要另写一套。
    if let Some(ids) = filter.label_ids.as_deref().filter(|ids| !ids.is_empty()) {
        clause.push_str(
            " AND EXISTS (SELECT 1 FROM todo_task_labels tl \
             WHERE tl.task_id = todo_tasks.id AND tl.is_deleted = 0 AND tl.label_id IN (",
        );
        for (i, id) in ids.iter().enumerate() {
            if i > 0 {
                clause.push_str(", ");
            }
            clause.push('?');
            bindings.push(*id);
        }
        clause.push_str("))");
    }
    // 存在性谓词（保存筛选器 has_reminder/has_attachment/has_open_subtask）：
    // true/false 只差一个 NOT，故共用同一段子查询文本。
    push_related_exists(&mut clause, filter.has_reminder, "todo_reminders", "tr", "");
    push_related_exists(
        &mut clause,
        filter.has_attachment,
        "todo_task_attachments",
        "ta",
        "",
    );
    push_related_exists(
        &mut clause,
        filter.has_open_subtask,
        "todo_subtasks",
        "ts",
        " AND ts.done = 0",
    );
    // 创建 / 完成时间下界（保存筛选器 created_from / done_from）
    if let Some(from) = filter.created_from {
        clause.push_str(" AND created_at >= ?");
        bindings.push(from);
    }
    if let Some(from) = filter.done_from {
        // 未完成行没有完成时间：本谓词隐含「只看已完成」
        clause.push_str(" AND done = 1 AND done_at >= ?");
        bindings.push(from);
    }
    TaskPredicateClause {
        clause,
        bindings,
        status_binding,
    }
}

/// 追加「存在 / 不存在关联行」谓词（子表统一带 `task_id` 与 `is_deleted`）。
///
/// `extra` 为附加条件，须以 `" AND "` 起头（如子任务的 `done = 0`）。
/// 表名与别名都是本文件内的编译期常量，不来自用户输入。
fn push_related_exists(
    clause: &mut String,
    flag: Option<bool>,
    table: &str,
    alias: &str,
    extra: &str,
) {
    let negate = match flag {
        Some(true) => "",
        Some(false) => "NOT ",
        None => return,
    };
    clause.push_str(&format!(
        " AND {negate}EXISTS (SELECT 1 FROM {table} {alias} \
         WHERE {alias}.task_id = todo_tasks.id AND {alias}.is_deleted = 0{extra})"
    ));
}

/// 返回指定业务表的可搜索字符串字段白名单
///
/// 白名单集中维护，遗漏字段只是搜索不到，不会崩溃。
/// 未在白名单中的表返回空切片（不支持 keyword 搜索）。
///
/// 只列本仓实际建表的 `todo_*` 表（见 `db/migrations/`）。蓝本 wait-home 的
/// 生活记录域表（rec_books / important_events / career_* / women_* / phone_numbers …）
/// 在 AGENTS.md「明确不做」清单内，永不建表，故不列——列了只会让搜索白名单
/// 看起来像承诺了这些模块。
fn searchable_fields(table: &str) -> &'static [&'static str] {
    match table {
        "todo_tasks" => &["title", "description"],
        "todo_projects" => &["title", "description"],
        "todo_subtasks" => &["title"],
        "todo_labels" => &["title"],
        "todo_comments" => &["content"],
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
    let (count,): (i64,) = sqlx::query_as(&sql).bind(since_ms).fetch_one(pool).await?;
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
// bounded-by-data: GROUP BY 日期桶，结果集 = 区间内桶数（day ≤ 365 / month 12 / year 个位数）
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
// bounded-by-data: GROUP BY 日期桶，结果集 = 区间内桶数（day ≤ 365 / month 12 / year 个位数）
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
    // bounded-by-data: 结果集 = 区间内日期桶数（与行数无关）
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
    let now = crate::db::clock::next_ms();
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

    // F5 拼音索引：被索引的三表软删即移除（防幽灵命中；恢复由 restore 钩子
    // 与置脏后的对账兜底重建）。表清单只在 search_pinyin::INDEXED_TABLES 一处定义。
    if crate::db::search_pinyin::is_indexed_table(table)
        && let Err(e) = crate::db::search_pinyin::remove_row(pool, record_uuid).await
    {
        log::warn!("search_pinyin remove(soft_delete) failed: {e}");
    }

    Ok(())
}

// =============================================================================
// =============================================================================
// todo_ 表族 typed create/update（Vikunja 化重构，8 张表）
// =============================================================================

// ---------- todo_projects ----------

/// todo_projects 创建
pub async fn create_todo_project(
    pool: &SqlitePool,
    input: &TodoProjectCreateInput,
) -> CoreResult<TodoProject> {
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();

    let row = sqlx::query_as::<_, TodoProject>(
        "INSERT INTO todo_projects (uuid, title, description, hex_color, sort_order, parent_uuid, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid)
    .bind(&input.title)
    .bind(input.description.as_deref())
    .bind(input.hex_color.as_deref().unwrap_or("#3B82F6"))
    .bind(input.sort_order.unwrap_or(0.0))
    .bind(input.parent_uuid.as_deref())
    .bind(now)
    .bind(now)
    .fetch_one(pool).await?;

    emit_event("todo_projects", row.id, &row.uuid, DbOp::Insert, now);
    // F5 拼音索引：项目标题入检索面（失败不阻断业务写——reconcile 兜底）
    if let Err(e) = crate::db::search_pinyin::sync_row(
        pool,
        crate::db::search_pinyin::KIND_PROJECT,
        &row.uuid,
        &row.title,
    )
    .await
    {
        log::warn!("search_pinyin sync(project insert) failed: {e}");
    }
    Ok(row)
}

/// todo_projects 更新
pub async fn update_todo_project(
    pool: &SqlitePool,
    id: i64,
    input: &TodoProjectUpdateInput,
) -> CoreResult<TodoProject> {
    let now = crate::db::clock::next_ms();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() {
        sets.push("title = ?".into());
    }
    if input.description.is_some() {
        sets.push("description = ?".into());
    }
    if input.hex_color.is_some() {
        sets.push("hex_color = ?".into());
    }
    if input.sort_order.is_some() {
        sets.push("sort_order = ?".into());
    }
    if input.is_archived.is_some() {
        sets.push("is_archived = ?".into());
    }
    // M8 上级文件夹：内层 None = 移到顶层（写 NULL）；由 business_api 完成环/存在性校验
    if input.parent_uuid.is_some() {
        sets.push("parent_uuid = ?".into());
    }
    // F1 项目回顾节奏三列：外层 Some = 本次要改，内层 None = 写 NULL
    //（关闭回顾 / 从未回顾 / 未暂缓）；SET 与 bind 顺序必须一致
    if input.review_interval_days.is_some() {
        sets.push("review_interval_days = ?".into());
    }
    if input.review_last_at.is_some() {
        sets.push("review_last_at = ?".into());
    }
    if input.review_snooze_until.is_some() {
        sets.push("review_snooze_until = ?".into());
    }

    let sql = format!(
        "UPDATE todo_projects SET {} WHERE id = ? RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoProject>(&sql).bind(now);
    if let Some(v) = &input.title {
        q = q.bind(v);
    }
    if let Some(v) = input.description.as_ref() {
        q = q.bind(v);
    }
    if let Some(v) = &input.hex_color {
        q = q.bind(v);
    }
    if let Some(v) = input.sort_order {
        q = q.bind(v);
    }
    if let Some(v) = input.is_archived {
        q = q.bind(v);
    }
    if let Some(v) = input.parent_uuid.as_ref() {
        q = q.bind(v);
    }
    if let Some(v) = input.review_interval_days.as_ref() {
        q = q.bind(v);
    }
    if let Some(v) = input.review_last_at.as_ref() {
        q = q.bind(v);
    }
    if let Some(v) = input.review_snooze_until.as_ref() {
        q = q.bind(v);
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_project id={}", id)))?;

    emit_event("todo_projects", row.id, &row.uuid, DbOp::Update, now);
    // F5 拼音索引：检索文本变更随行重建（失败不阻断业务写——reconcile 兜底）
    if let Err(e) = crate::db::search_pinyin::sync_row(
        pool,
        crate::db::search_pinyin::KIND_PROJECT,
        &row.uuid,
        &row.title,
    )
    .await
    {
        log::warn!("search_pinyin sync(KIND_PROJECT) failed: {e}");
    }
    Ok(row)
}

// ---------- todo_tasks ----------

/// todo_tasks 创建
pub async fn create_todo_task(
    pool: &SqlitePool,
    input: &TodoTaskCreateInput,
) -> CoreResult<TodoTask> {
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();

    let row = sqlx::query_as::<_, TodoTask>(
        "INSERT INTO todo_tasks (
            uuid, title, description, project_id, priority, status, done, done_at,
            due_date, start_date, repeat_after, repeat_mode,
            repeat_weekdays, repeat_end_type, repeat_end_param, repeat_from_done,
            repeat_month_mode, repeat_nth_week,
            percent_done, position, is_favorite, my_day_date, duration_minutes,
            is_deleted, created_at, updated_at, version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 0, ?, ?, 1)
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
    .bind(input.repeat_after.unwrap_or(0))
    .bind(input.repeat_mode.unwrap_or(0))
    .bind(input.repeat_weekdays.unwrap_or(0))
    .bind(input.repeat_end_type.unwrap_or(0))
    .bind(input.repeat_end_param.unwrap_or(0))
    .bind(input.repeat_from_done.unwrap_or(0))
    .bind(input.repeat_month_mode.unwrap_or(0))
    .bind(input.repeat_nth_week.unwrap_or(0))
    .bind(input.position.unwrap_or(0.0))
    .bind(input.is_favorite.unwrap_or(0))
    .bind(input.my_day_date)
    .bind(input.duration_minutes.filter(|m| *m > 0))
    .bind(now)
    .bind(now)
    .fetch_one(pool)
    .await?;

    emit_event("todo_tasks", row.id, &row.uuid, DbOp::Insert, now);
    // F5 拼音索引：检索文本变更随行重建（失败不阻断业务写——reconcile 兜底）
    if let Err(e) = crate::db::search_pinyin::sync_row(
        pool,
        crate::db::search_pinyin::KIND_TASK,
        &row.uuid,
        &row.title,
    )
    .await
    {
        log::warn!("search_pinyin sync(KIND_TASK) failed: {e}");
    }
    Ok(row)
}

/// todo_tasks 更新（Option<Option<T>> 模式）
pub async fn update_todo_task(
    pool: &SqlitePool,
    id: i64,
    input: &TodoTaskUpdateInput,
) -> CoreResult<TodoTask> {
    let now = crate::db::clock::next_ms();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() {
        sets.push("title = ?".into());
    }
    if input.description.is_some() {
        sets.push("description = ?".into());
    }
    if input.project_id.is_some() {
        sets.push("project_id = ?".into());
    }
    if input.priority.is_some() {
        sets.push("priority = ?".into());
    }
    if input.status.is_some() {
        sets.push("status = ?".into());
    }
    if input.done.is_some() {
        sets.push("done = ?".into());
    }
    if input.done_at.is_some() {
        sets.push("done_at = ?".into());
    }
    if input.due_date.is_some() {
        sets.push("due_date = ?".into());
    }
    if input.start_date.is_some() {
        sets.push("start_date = ?".into());
    }
    if input.repeat_after.is_some() {
        sets.push("repeat_after = ?".into());
    }
    if input.repeat_mode.is_some() {
        sets.push("repeat_mode = ?".into());
    }
    if input.repeat_weekdays.is_some() {
        sets.push("repeat_weekdays = ?".into());
    }
    if input.repeat_end_type.is_some() {
        sets.push("repeat_end_type = ?".into());
    }
    if input.repeat_end_param.is_some() {
        sets.push("repeat_end_param = ?".into());
    }
    if input.repeat_from_done.is_some() {
        sets.push("repeat_from_done = ?".into());
    }
    if input.repeat_month_mode.is_some() {
        sets.push("repeat_month_mode = ?".into());
    }
    if input.repeat_nth_week.is_some() {
        sets.push("repeat_nth_week = ?".into());
    }
    if input.percent_done.is_some() {
        sets.push("percent_done = ?".into());
    }
    if input.position.is_some() {
        sets.push("position = ?".into());
    }
    if input.is_favorite.is_some() {
        sets.push("is_favorite = ?".into());
    }
    if input.my_day_date.is_some() {
        sets.push("my_day_date = ?".into());
    }
    if input.duration_minutes.is_some() {
        sets.push("duration_minutes = ?".into());
    }

    let sql = format!(
        "UPDATE todo_tasks SET {} WHERE id = ? RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoTask>(&sql).bind(now);
    if let Some(v) = &input.title {
        q = q.bind(v);
    }
    if let Some(v) = input.description.as_ref() {
        q = q.bind(v);
    }
    if let Some(v) = input.project_id {
        q = q.bind(v);
    }
    if let Some(v) = input.priority {
        q = q.bind(v);
    }
    if let Some(v) = &input.status {
        q = q.bind(v);
    }
    if let Some(v) = input.done {
        q = q.bind(v);
    }
    if let Some(v) = input.done_at {
        q = q.bind(v);
    }
    if let Some(v) = input.due_date {
        q = q.bind(v);
    }
    if let Some(v) = input.start_date {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_after {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_mode {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_weekdays {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_end_type {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_end_param {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_from_done {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_month_mode {
        q = q.bind(v);
    }
    if let Some(v) = input.repeat_nth_week {
        q = q.bind(v);
    }
    if let Some(v) = input.percent_done {
        q = q.bind(v);
    }
    if let Some(v) = input.position {
        q = q.bind(v);
    }
    if let Some(v) = input.is_favorite {
        q = q.bind(v);
    }
    if let Some(v) = input.my_day_date {
        q = q.bind(v);
    }
    if let Some(v) = input.duration_minutes {
        // 非 None 即落库：Some(None) 清为 NULL，Some(Some(0)) 视同清除（负值/零非合法时长）
        q = q.bind(v.filter(|m| *m > 0));
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_task id={}", id)))?;

    emit_event("todo_tasks", row.id, &row.uuid, DbOp::Update, now);
    // F5 拼音索引：检索文本变更随行重建（失败不阻断业务写——reconcile 兜底）
    if let Err(e) = crate::db::search_pinyin::sync_row(
        pool,
        crate::db::search_pinyin::KIND_TASK,
        &row.uuid,
        &row.title,
    )
    .await
    {
        log::warn!("search_pinyin sync(KIND_TASK) failed: {e}");
    }
    Ok(row)
}

// ---------- todo_subtasks ----------

pub async fn create_todo_subtask(
    pool: &SqlitePool,
    input: &TodoSubtaskCreateInput,
) -> CoreResult<TodoSubtask> {
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoSubtask>(
        "INSERT INTO todo_subtasks (uuid, task_id, title, done, done_at, position, parent_uuid, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, NULL, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(&input.title)
    .bind(input.position.unwrap_or(0.0))
    .bind(&input.parent_uuid)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_subtasks", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

pub async fn update_todo_subtask(
    pool: &SqlitePool,
    id: i64,
    input: &TodoSubtaskUpdateInput,
) -> CoreResult<TodoSubtask> {
    let now = crate::db::clock::next_ms();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() {
        sets.push("title = ?".into());
    }
    if input.done.is_some() {
        sets.push("done = ?".into());
    }
    if input.done_at.is_some() {
        sets.push("done_at = ?".into());
    }
    if input.position.is_some() {
        sets.push("position = ?".into());
    }
    // M10 三态：None 不动 / Some(None) 置 NULL（提顶层）/ Some(Some) 挂父
    if input.parent_uuid.is_some() {
        sets.push("parent_uuid = ?".into());
    }
    let sql = format!(
        "UPDATE todo_subtasks SET {} WHERE id = ? RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoSubtask>(&sql).bind(now);
    if let Some(v) = &input.title {
        q = q.bind(v);
    }
    if let Some(v) = input.done {
        q = q.bind(v);
    }
    if let Some(v) = input.done_at {
        q = q.bind(v);
    }
    if let Some(v) = input.position {
        q = q.bind(v);
    }
    if let Some(v) = &input.parent_uuid {
        q = q.bind(v.as_deref());
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_subtask id={}", id)))?;
    emit_event("todo_subtasks", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_labels ----------

pub async fn create_todo_label(
    pool: &SqlitePool,
    input: &TodoLabelCreateInput,
) -> CoreResult<TodoLabel> {
    let now = crate::db::clock::next_ms();
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

pub async fn update_todo_label(
    pool: &SqlitePool,
    id: i64,
    input: &TodoLabelUpdateInput,
) -> CoreResult<TodoLabel> {
    let now = crate::db::clock::next_ms();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.title.is_some() {
        sets.push("title = ?".into());
    }
    if input.hex_color.is_some() {
        sets.push("hex_color = ?".into());
    }
    let sql = format!(
        "UPDATE todo_labels SET {} WHERE id = ? RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoLabel>(&sql).bind(now);
    if let Some(v) = &input.title {
        q = q.bind(v);
    }
    if let Some(v) = &input.hex_color {
        q = q.bind(v);
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("todo_label id={}", id)))?;
    emit_event("todo_labels", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

// ---------- todo_task_labels（仅 create + delete） ----------

pub async fn create_todo_task_label(
    pool: &SqlitePool,
    input: &TodoTaskLabelCreateInput,
) -> CoreResult<TodoTaskLabel> {
    let now = crate::db::clock::next_ms();
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

pub async fn create_todo_comment(
    pool: &SqlitePool,
    input: &TodoCommentCreateInput,
) -> CoreResult<TodoComment> {
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoComment>(
        "INSERT INTO todo_comments (uuid, task_id, content, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(&input.content)
    .bind(now).bind(now).fetch_one(pool).await?;
    emit_event("todo_comments", row.id, &row.uuid, DbOp::Insert, now);
    // F5 拼音索引：检索文本变更随行重建（失败不阻断业务写——reconcile 兜底）
    if let Err(e) = crate::db::search_pinyin::sync_row(
        pool,
        crate::db::search_pinyin::KIND_COMMENT,
        &row.uuid,
        &row.content,
    )
    .await
    {
        log::warn!("search_pinyin sync(KIND_COMMENT) failed: {e}");
    }
    Ok(row)
}

// ---------- todo_task_relations（仅 create） ----------

pub async fn create_todo_task_relation(
    pool: &SqlitePool,
    input: &TodoTaskRelationCreateInput,
) -> CoreResult<TodoTaskRelation> {
    let now = crate::db::clock::next_ms();
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

pub async fn create_todo_reminder(
    pool: &SqlitePool,
    input: &TodoReminderCreateInput,
) -> CoreResult<TodoReminder> {
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();
    let row = sqlx::query_as::<_, TodoReminder>(
        "INSERT INTO todo_reminders (uuid, task_id, remind_at, is_constant, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid).bind(input.task_id).bind(input.remind_at)
    .bind(input.is_constant)
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
    let now = crate::db::clock::next_ms();
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
    let now = crate::db::clock::next_ms();
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
    let now = crate::db::clock::next_ms();

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
    let now = crate::db::clock::next_ms();

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
    let now = crate::db::clock::next_ms();
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
    let now = crate::db::clock::next_ms();
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
        let fields = searchable_fields("todo_tasks");
        assert!(!fields.is_empty(), "todo_tasks 应支持 keyword 搜索");
        assert!(fields.contains(&"title"));
        assert!(fields.contains(&"description"));
    }

    /// 生活记录域表（AGENTS.md「明确不做」清单）不应出现在白名单里
    #[test]
    fn searchable_fields_excludes_life_tracking_tables() {
        for table in [
            "rec_books",
            "important_events",
            "career_projects",
            "women_periods",
            "phone_numbers",
        ] {
            assert!(
                searchable_fields(table).is_empty(),
                "{table} 属生活记录域，永不建表，不应可搜索"
            );
        }
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
        let clause = build_keyword_clause("todo_tasks", None);
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());

        let clause = build_keyword_clause("todo_tasks", Some(""));
        assert!(clause.clause.is_empty());
        assert!(clause.bindings.is_empty());

        let clause = build_keyword_clause("todo_tasks", Some("   "));
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
        let clause = build_keyword_clause("todo_tasks", Some("买牛奶"));
        let fields = searchable_fields("todo_tasks");

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
            assert!(binding.contains("买牛奶"));
        }
    }

    /// keyword 应被 trim 后再拼入 LIKE 模式
    #[test]
    fn build_keyword_clause_trims_keyword() {
        let clause = build_keyword_clause("todo_tasks", Some("  abc  "));
        for binding in &clause.bindings {
            assert_eq!(binding, "%abc%");
        }
    }
}

// ============================================================================
// 谓词下推子句纯函数单测（2026-09-12 F5；SQL 语义集成见 todo_api tests）
// ============================================================================

#[cfg(test)]
mod task_predicate_tests {
    use super::{ListFilter, build_task_predicate_clause};

    fn filter_with(p: impl FnOnce(&mut ListFilter)) -> ListFilter {
        let mut f = ListFilter::default();
        p(&mut f);
        f
    }

    /// 非任务表忽略全部谓词（空子句空绑定）
    #[test]
    fn predicate_ignored_for_non_task_tables() {
        let c = build_task_predicate_clause(
            "todo_projects",
            &filter_with(|f| {
                f.done = Some(false);
                f.priority_min = Some(3);
            }),
        );
        assert!(c.clause.is_empty());
        assert!(c.bindings.is_empty() && c.status_binding.is_none());
    }

    /// done=false → done = 0 字面量（无绑定参数）
    #[test]
    fn done_false_is_literal_clause() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.done = Some(false);
            }),
        );
        assert_eq!(c.clause, " AND done = 0");
        assert!(c.bindings.is_empty());
    }

    /// status 文本绑定单通道（TEXT 列不可绑 INTEGER）
    #[test]
    fn status_binds_text_separately() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status = Some("doing".into());
                f.priority_min = Some(4);
            }),
        );
        assert!(c.clause.contains(" AND status = ? AND priority >= ?"));
        assert_eq!(c.status_binding.as_deref(), Some("doing"));
        // 数值绑定序 = 子句声明序（priority_min 在 status 后声明）
        assert_eq!(c.bindings, vec![4]);
    }

    /// 状态集合（工具栏多选档）：pending/doing 字面量内联、done 转完成态放行
    #[test]
    fn status_in_renders_derived_status_clause() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status_in = Some(vec!["pending".into(), "doing".into()]);
            }),
        );
        assert!(
            c.clause
                .contains("(CASE WHEN status IN ('doing', 'done') THEN status ELSE 'pending' END) IN ('pending', 'doing')")
        );
        assert!(c.bindings.is_empty() && c.status_binding.is_none());
    }

    /// done 档 = 「status='done' 或 done=1」完成态（老数据勾选完成不写 status）
    #[test]
    fn status_in_done_matches_completed_flag() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status_in = Some(vec!["done".into()]);
            }),
        );
        assert!(c.clause.contains("(done = 1 OR status = 'done')"));
        assert!(!c.clause.contains("IN ('done')"));
    }

    /// 空集合 = 不过滤（工具栏「全部状态」，与 label_ids 同语义）
    #[test]
    fn empty_status_in_is_noop() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status_in = Some(vec![]);
            }),
        );
        assert_eq!(c.clause, "");
    }

    /// 脏值静默剔除（派生状态只可能是 pending/doing/done 三档）
    #[test]
    fn status_in_drops_unknown_values() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status_in = Some(vec!["weird".into(), "pending".into()]);
            }),
        );
        assert!(!c.clause.contains("weird"));
        assert!(c.clause.contains("'pending'"));
    }

    /// 集合优先于等值：同时给出只认集合（不叠加、不重复绑定）
    #[test]
    fn status_in_wins_over_status() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.status = Some("doing".into());
                f.status_in = Some(vec!["pending".into()]);
            }),
        );
        assert!(c.clause.contains("'pending'"));
        assert!(c.status_binding.is_none());
        assert!(!c.clause.contains("status = ?"));
    }

    /// project_id / my_day_today / favorite_only 组合
    #[test]
    fn combined_numeric_predicates() {
        let zero = 1_789_142_400_000_i64;
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.project_id = Some(7);
                f.favorite_only = Some(true);
                f.my_day_today = Some(zero);
            }),
        );
        assert!(
            c.clause
                .contains(" AND project_id = ? AND is_favorite = 1 AND my_day_date = ?")
        );
        assert_eq!(c.bindings, vec![7, zero]);
        assert!(c.status_binding.is_none());
    }

    /// project_ids 集合 → IN (?, ?, ?)，绑定序 = 集合序（清单文件夹聚合）
    #[test]
    fn project_ids_renders_in_clause() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.project_ids = Some(vec![3, 5, 8]);
            }),
        );
        assert_eq!(c.clause, " AND project_id IN (?, ?, ?)");
        assert_eq!(c.bindings, vec![3, 5, 8]);
        assert!(c.status_binding.is_none());
    }

    /// 集合优先于等值：两者同时给出时只认集合（不叠加、不重复绑定）
    #[test]
    fn project_ids_wins_over_project_id() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.project_id = Some(7);
                f.project_ids = Some(vec![7, 9]);
            }),
        );
        assert_eq!(c.clause, " AND project_id IN (?, ?)");
        assert_eq!(c.bindings, vec![7, 9]);
    }

    /// 空集合 = 空结果：恒假子句而非「不加约束」
    ///（退化成全量会让「无所属项目的视图」意外显示全部任务）
    #[test]
    fn empty_project_ids_is_always_false() {
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.project_ids = Some(vec![]);
            }),
        );
        assert_eq!(c.clause, " AND 1 = 0");
        assert!(c.bindings.is_empty());
    }

    /// project_ids 与前置/后置谓词的绑定序不串位
    /// （IN 的 N 个占位符插在 priority_min 与 my_day_today 之间）
    #[test]
    fn project_ids_binding_order_with_neighbors() {
        let zero = 1_789_142_400_000_i64;
        let c = build_task_predicate_clause(
            "todo_tasks",
            &filter_with(|f| {
                f.priority_min = Some(2);
                f.project_ids = Some(vec![11, 12]);
                f.my_day_today = Some(zero);
            }),
        );
        assert_eq!(
            c.clause,
            " AND priority >= ? AND project_id IN (?, ?) AND my_day_date = ?"
        );
        assert_eq!(c.bindings, vec![2, 11, 12, zero]);
    }

    /// 空谓词 → 空子句（基线查询零开销）
    #[test]
    fn no_predicates_yields_empty_clause() {
        let c = build_task_predicate_clause("todo_tasks", &ListFilter::default());
        assert!(c.clause.is_empty());
    }
}

/// 键集分页测试（P1 50k 规模档）。
///
/// 重点不是「单页内容对不对」，而是**翻页遍历结果与一次性全量完全一致**：
/// 键集分页最容易出的错是边界重复/漏行（`>` 写成 `>=`、tiebreaker 漏掉、
/// NULL 段漏判），它们不会让任何单页断言翻红，只有「逐页收集 vs 全量」能抓到。
#[cfg(test)]
mod keyset_paging_tests {
    use super::*;
    use crate::api::business_api::create_todo_task;
    use crate::models::business::{ListCursor, ListFilter, TodoTaskCreateInput};

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 造 25 条任务：priority 只有 0/1/2 三值、due 有 6 条无截止、position 留给手工
    async fn seed(pool: &SqlitePool) -> Vec<i64> {
        let mut ids = Vec::new();
        for i in 0..25i64 {
            let t = create_todo_task(
                pool,
                &TodoTaskCreateInput {
                    title: format!("任务 {i:02}"),
                    priority: Some((i % 3) as i32),
                    due_date: if i % 4 == 0 {
                        None
                    } else {
                        Some(1_700_000_000_000 + (i % 5) * 86_400_000)
                    },
                    ..Default::default()
                },
            )
            .await
            .unwrap();
            // 拖拽序刻意与 id 逆序，才能区分 manual 档有没有真的按 position 排
            sqlx::query("UPDATE todo_tasks SET position = ? WHERE id = ?")
                .bind((100 - i) as f64)
                .bind(t.id)
                .execute(pool)
                .await
                .unwrap();
            ids.push(t.id);
        }
        ids
    }

    fn filter(sort_key: &str, sort_dir: Option<&str>) -> ListFilter {
        ListFilter {
            sort_key: Some(sort_key.into()),
            sort_dir: sort_dir.map(str::to_string),
            page_size: 10_000,
            ..Default::default()
        }
    }

    /// 逐页收集（带死循环护栏）
    async fn collect_all(pool: &SqlitePool, f: &ListFilter, limit: u32) -> Vec<i64> {
        let mut out = Vec::new();
        let mut cursor: Option<ListCursor> = None;
        for _ in 0..1000 {
            let page = list_tasks_page(pool, f, cursor.as_ref(), limit)
                .await
                .unwrap();
            out.extend(page.items.iter().map(|t| t.id));
            assert_eq!(page.has_more, page.next_cursor.is_some());
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => return out,
            }
        }
        panic!("翻页未收敛（游标没有推进）");
    }

    /// 四档 × 多种页长：逐页遍历必须与单页全量等价（同序、无重复、无遗漏）
    #[tokio::test]
    async fn paging_traversal_matches_single_page() {
        let pool = setup_db().await;
        seed(&pool).await;
        for (key, dir) in [
            ("manual", None),
            ("due", None),
            ("due", Some("desc")),
            ("priority", None),
            ("priority", Some("asc")),
            ("created", None),
        ] {
            let f = filter(key, dir);
            let full: Vec<i64> = list_tasks_page(&pool, &f, None, 1000)
                .await
                .unwrap()
                .items
                .iter()
                .map(|t| t.id)
                .collect();
            assert_eq!(full.len(), 25, "{key}/{dir:?} 单页应取满");
            for limit in [1u32, 3, 7, 24] {
                let paged = collect_all(&pool, &f, limit).await;
                assert_eq!(
                    paged, full,
                    "{key}/{dir:?} limit={limit} 逐页序应与全量一致"
                );
            }
        }
    }

    /// 各档主键顺序（不是随便排；tiebreaker 之外必须按声明键）
    #[tokio::test]
    async fn sort_orders_follow_declared_keys() {
        let pool = setup_db().await;
        seed(&pool).await;

        let manual = list_tasks_page(&pool, &filter("manual", None), None, 1000)
            .await
            .unwrap();
        let positions: Vec<f64> = manual.items.iter().map(|t| t.position).collect();
        assert!(
            positions.windows(2).all(|w| w[0] <= w[1]),
            "manual 档必须 position 升序"
        );

        let priority = list_tasks_page(&pool, &filter("priority", None), None, 1000)
            .await
            .unwrap();
        assert!(
            priority
                .items
                .windows(2)
                .all(|w| w[0].priority >= w[1].priority),
            "priority 档默认降序"
        );
        // 同优先级内 position 升序
        for pair in priority.items.windows(2) {
            if pair[0].priority == pair[1].priority {
                assert!(pair[0].position <= pair[1].position);
            }
        }

        let due = list_tasks_page(&pool, &filter("due", None), None, 1000)
            .await
            .unwrap();
        let first_null = due.items.iter().position(|t| t.due_date.is_none());
        if let Some(idx) = first_null {
            assert!(
                due.items[idx..].iter().all(|t| t.due_date.is_none()),
                "due 档无截止必须整体沉底"
            );
        }
        // 方向只翻主键：desc 时无截止仍在最后
        let due_desc = list_tasks_page(&pool, &filter("due", Some("desc")), None, 1000)
            .await
            .unwrap();
        let first_null_desc = due_desc.items.iter().position(|t| t.due_date.is_none());
        if let Some(idx) = first_null_desc {
            assert!(due_desc.items[idx..].iter().all(|t| t.due_date.is_none()));
        }
        assert!(
            due_desc.items[..first_null_desc.unwrap_or(due_desc.items.len())]
                .windows(2)
                .all(|w| w[0].due_date >= w[1].due_date),
            "due desc 主键应降序"
        );
    }

    /// 换排序档沿用旧游标 → 空页（UI 快速切档的竞态自愈，不报错也不给错数据）
    #[tokio::test]
    async fn stale_cursor_from_other_sort_yields_empty_page() {
        let pool = setup_db().await;
        seed(&pool).await;
        let first = list_tasks_page(&pool, &filter("manual", None), None, 5)
            .await
            .unwrap();
        let stale = first.next_cursor.unwrap();
        let page = list_tasks_page(&pool, &filter("due", None), Some(&stale), 5)
            .await
            .unwrap();
        assert!(page.items.is_empty());
        assert!(!page.has_more);
    }

    /// 未知排序键报错；title 档明确拒绝（必须走全量通道）
    #[tokio::test]
    async fn unsupported_sort_keys_are_rejected() {
        let pool = setup_db().await;
        for key in ["title", "position"] {
            let err = list_tasks_page(&pool, &filter(key, None), None, 10)
                .await
                .unwrap_err();
            assert!(err.to_string().contains(key), "错误信息应点名排序键: {err}");
        }
    }

    /// 总览聚合：total 与筛选一致；侧栏计数是全局口径（不受 done 谓词影响）
    #[tokio::test]
    async fn overview_total_and_project_counts() {
        let pool = setup_db().await;
        seed(&pool).await;
        let project = crate::api::business_api::create_todo_project(
            &pool,
            &crate::models::business::TodoProjectCreateInput {
                title: "项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap();
        // 两条进项目、一条完成（完成后不应计入未完成角标）
        for (idx, done) in [(0, false), (1, true)] {
            let t = create_todo_task(
                &pool,
                &TodoTaskCreateInput {
                    title: format!("项目任务 {idx}"),
                    project_id: Some(project.id),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
            if done {
                crate::api::todo_api::complete_todo_task(&pool, t.id)
                    .await
                    .unwrap();
            }
        }

        let ov = task_overview(&pool, &ListFilter::default()).await.unwrap();
        assert_eq!(ov.total, 27, "25 条种子 + 2 条项目任务");
        let bucket = ov
            .undone_by_project
            .iter()
            .find(|b| b.project_id == Some(project.id))
            .expect("项目桶应存在");
        assert_eq!(bucket.count, 1, "已完成的那条不计入未完成");

        // done 谓词只影响 total，不影响侧栏全局计数
        let ov_done = task_overview(&pool, &filter_done(true)).await.unwrap();
        assert_eq!(ov_done.total, 1);
        let bucket_done = ov_done
            .undone_by_project
            .iter()
            .find(|b| b.project_id == Some(project.id))
            .expect("项目桶仍应在");
        assert_eq!(bucket_done.count, 1);
    }

    fn filter_done(done: bool) -> ListFilter {
        ListFilter {
            done: Some(done),
            ..Default::default()
        }
    }
}

/// 列裁剪集成测试（批2 + A2）：todo_tasks 列表通道返回瘦行
/// [`TodoTaskListItem`](crate::models::business::TodoTaskListItem)（10 个零消费列
/// 整体不在行列清单里），description 值仅在 keyword 通道回真值；get_by_id
/// 单条保持全列。
#[cfg(test)]
mod column_prune_tests {
    use super::*;
    use crate::api::business_api::create_todo_task;
    use crate::models::business::{ListFilter, TodoTask, TodoTaskCreateInput, TodoTaskListItem};

    async fn setup_db() -> sqlx::SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    fn all_tasks() -> ListFilter {
        ListFilter {
            page_size: 10_000,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn list_without_keyword_prunes_description() {
        let pool = setup_db().await;
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "带描述的任务".into(),
                description: Some("很长的描述文本".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        // A2：列表通道返回瘦行 DTO——10 个零消费列不在行列清单里（uuid /
        // repeat_after / 六个更细 repeat_* / deleted_at / version），编译期即不足
        let rows: Vec<TodoTaskListItem> = list(&pool, "todo_tasks", &all_tasks()).await.unwrap();
        assert_eq!(rows.len(), 1);
        // 裁剪：列表通道 description 为 NULL（形状在、值不传）
        assert_eq!(rows[0].description, None);
        // 保留列全量（含非默认值字段防白名单漏列）
        assert_eq!(rows[0].title, "带描述的任务");
        assert_eq!(rows[0].status, "pending");
        assert_eq!(rows[0].is_deleted, 0);
        assert!(
            rows[0].created_at > 0,
            "created_at 桌面排序消费，必须在瘦行里"
        );
    }

    /// 两档列清单只差 description 表达式（防 {desc} 占位被改歪导致
    /// keyword 通道跟着丢描述原文），且两档都不含被裁列
    #[test]
    fn task_list_columns_differ_only_in_description() {
        let plain = task_list_columns(false);
        let keyworded = task_list_columns(true);
        assert_eq!(
            keyworded.replace("description AS description", "NULL AS description"),
            plain,
            "两档列清单只应差 description 表达式"
        );
        for pruned in [
            "uuid",
            "repeat_after",
            "repeat_weekdays",
            "repeat_end_type",
            "repeat_end_param",
            "repeat_from_done",
            "repeat_month_mode",
            "repeat_nth_week",
            "deleted_at",
            "version",
        ] {
            assert!(
                !plain.contains(pruned),
                "被裁列 {pruned} 不应出现在列表通道列清单: {plain}"
            );
        }
    }

    #[tokio::test]
    async fn list_with_keyword_keeps_description() {
        let pool = setup_db().await;
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "标题甲".into(),
                description: Some("描述含关键词采购".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let mut f = all_tasks();
        f.keyword = Some("采购".into());
        // 列清单同为瘦行（同为 TodoTaskListItem），只是 description 回真值
        let rows: Vec<TodoTaskListItem> = list(&pool, "todo_tasks", &f).await.unwrap();
        // keyword 命中 description → 行返回且描述原文过桥（桌面本地收敛分支要读）
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].description.as_deref(), Some("描述含关键词采购"));
    }

    #[tokio::test]
    async fn get_by_id_keeps_full_columns() {
        let pool = setup_db().await;
        let created = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "详情任务".into(),
                description: Some("详情应有完整描述".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let row: TodoTask = get_by_id(&pool, "todo_tasks", created.id).await.unwrap();
        assert_eq!(row.description.as_deref(), Some("详情应有完整描述"));
    }

    /// 非任务表不受裁剪影响（全列直通）
    #[tokio::test]
    async fn other_tables_keep_select_star() {
        let pool = setup_db().await;
        // todo_projects 列表走 list() 但不该套任务列清单（列不匹配会 FromRow 报错）
        // 断言改为可执行即白名单未误套：若误套 LIST_COLUMNS_TASKS，
        // todo_projects 行缺 hex_color/sort_order 列 FromRow 会直接报错
        let _rows: Vec<crate::models::business::TodoProject> =
            list(&pool, "todo_projects", &ListFilter::default())
                .await
                .unwrap();
    }
}

/// 看板/四象限窗口化（P1）：列键与桌面 `kanbanColumnKey` 一致、每组限流、
/// 组总数不受限流影响、四象限跳过已完成。
#[cfg(test)]
mod board_tests {
    use super::*;
    use crate::api::business_api::create_todo_task;
    use crate::models::business::{BoardGroupBy, TodoTaskCreateInput};

    const DAY: i64 = 86_400_000;
    /// 固定「今日零点」与「今日 24:00」：测试不随运行时刻漂移
    const DAY_START: i64 = 1_700_000_000_000;
    const DAY_END: i64 = DAY_START + DAY;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 5 条：逾期+重要 / 今天+重要 / 本周+不重要 / 无截止 / 已完成（逾期+重要）
    async fn seed(pool: &SqlitePool) {
        let rows: [(i32, Option<i64>, bool); 5] = [
            (5, Some(DAY_START - DAY), false),
            (3, Some(DAY_START + 1_000), false),
            (0, Some(DAY_START + 3 * DAY), false),
            (0, None, false),
            (5, Some(DAY_START - DAY), true),
        ];
        for (idx, (priority, due, done)) in rows.into_iter().enumerate() {
            let t = create_todo_task(
                pool,
                &TodoTaskCreateInput {
                    title: format!("看板任务 {idx}"),
                    priority: Some(priority),
                    due_date: due,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
            if done {
                crate::api::todo_api::complete_todo_task(pool, t.id)
                    .await
                    .unwrap();
            }
        }
    }

    fn undone() -> ListFilter {
        ListFilter {
            done: Some(false),
            ..Default::default()
        }
    }

    fn find<'a>(board: &'a TodoTaskBoard, key: &str) -> &'a TodoTaskBoardGroup {
        board
            .groups
            .iter()
            .find(|g| g.key == key)
            .unwrap_or_else(|| panic!("缺少分组 {key}，实际: {:?}", keys_of(board)))
    }

    fn keys_of(board: &TodoTaskBoard) -> Vec<&str> {
        board.groups.iter().map(|g| g.key.as_str()).collect()
    }

    #[tokio::test]
    async fn priority_groups_limit_items_but_not_total() {
        let pool = setup_db().await;
        seed(&pool).await;
        let board = task_board(
            &pool,
            &undone(),
            BoardGroupBy::Priority,
            1,
            DAY_START,
            DAY_END,
        )
        .await
        .unwrap();
        // 列键与桌面 kanbanColumnKey 同形
        assert_eq!(keys_of(&board), vec!["pri:0", "pri:3", "pri:5"]);
        assert_eq!(find(&board, "pri:0").total, 2);
        // 限流只截 items，total 仍是整组
        assert_eq!(find(&board, "pri:0").items.len(), 1);
        assert_eq!(find(&board, "pri:5").total, 1);
        assert_eq!(board.total, 4, "done 行被 undone 谓词排除");
    }

    #[tokio::test]
    async fn due_groups_follow_local_five_buckets() {
        let pool = setup_db().await;
        seed(&pool).await;
        let board = task_board(&pool, &undone(), BoardGroupBy::Due, 10, DAY_START, DAY_END)
            .await
            .unwrap();
        assert_eq!(
            keys_of(&board),
            vec!["due:none", "due:overdue", "due:today", "due:week"]
        );
        for key in ["due:none", "due:overdue", "due:today", "due:week"] {
            assert_eq!(find(&board, key).total, 1, "{key} 应各 1 条");
        }
    }

    #[tokio::test]
    async fn quadrant_skips_done_and_splits_by_urgency() {
        let pool = setup_db().await;
        seed(&pool).await;
        // 不传 done 谓词：四象限自己排除已完成（与 groupEisenhower 一致）
        let board = task_board(
            &pool,
            &ListFilter::default(),
            BoardGroupBy::Quadrant,
            10,
            DAY_START,
            DAY_END,
        )
        .await
        .unwrap();
        assert_eq!(board.total, 4, "已完成那条不进四象限");
        // 只返回有行的组（空列由前端按固定列定义补），逾期(P5) 与今天(P3)
        // 都算紧急；本周(P0) 与无截止(P0) 都不紧急
        assert_eq!(keys_of(&board), vec!["neither", "urgentImportant"]);
        assert_eq!(find(&board, "urgentImportant").total, 2);
        assert_eq!(find(&board, "neither").total, 2);
    }

    #[tokio::test]
    async fn quadrant_with_explicit_done_filter_is_empty() {
        // groupEisenhower 跳过 done：用户把状态筛成「已完成」时四象限必须为空，
        // 不能因为内部强制 done=0 而变回「全部未完成」
        let pool = setup_db().await;
        seed(&pool).await;
        let filter = ListFilter {
            done: Some(true),
            ..Default::default()
        };
        let board = task_board(
            &pool,
            &filter,
            BoardGroupBy::Quadrant,
            10,
            DAY_START,
            DAY_END,
        )
        .await
        .unwrap();
        assert_eq!(board.total, 0);
        assert!(board.groups.is_empty());
    }

    #[tokio::test]
    async fn project_groups_use_ungrouped_key() {
        let pool = setup_db().await;
        seed(&pool).await;
        let board = task_board(
            &pool,
            &undone(),
            BoardGroupBy::Project,
            10,
            DAY_START,
            DAY_END,
        )
        .await
        .unwrap();
        assert_eq!(keys_of(&board), vec!["ungrouped"]);
        assert_eq!(find(&board, "ungrouped").total, 4);
    }

    #[tokio::test]
    async fn status_groups_collapse_unknown_status() {
        let pool = setup_db().await;
        seed(&pool).await;
        let board = task_board(
            &pool,
            &undone(),
            BoardGroupBy::Status,
            10,
            DAY_START,
            DAY_END,
        )
        .await
        .unwrap();
        assert_eq!(keys_of(&board), vec!["pending"]);
        assert_eq!(find(&board, "pending").total, 4);
    }
}
