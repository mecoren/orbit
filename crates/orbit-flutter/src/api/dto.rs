//! api::dto — todo 域过桥类型的显式本地镜像（DTO 模式）
//!
//! ## 为什么需要镜像 struct（而不是直接把 orbit_core 类型放进 FRB 签名）
//! FRB 只为 **rust_input（crate::api）扫描范围内可见的类型定义** 生成字段级
//! Dart 镜像；orbit_core 是外部 crate，其 struct 定义对 codegen 不可见，
//! 一律被降级为 opaque（Dart 侧生成
//! `abstract class TodoProject implements RustOpaqueInterface {}`——无任何字段，
//! 仅持 Rust 指针），且 i64 等整型在 opaque 路径下无法保证精确传递。
//!
//! 因此本模块为 todo 域全部过桥类型提供一一对应的本地镜像：
//! - 字段名、类型与 core 完全一致（仅用 i64/i32/u32/f64/String/bool 及其
//!   Option 包装等 FRB 可镜像的基本类型）；
//! - 实现 `From<core类型>`（core → DTO，出参方向）与
//!   `From<DTO> for core CreateInput/ListFilter`（入参方向）双向转换，
//!   桥接层（todo.rs）零业务逻辑、只做搬运；
//! - [TodoTaskDetail] 与 [TaskLabelWithId] 在 core 中以 `#[serde(flatten)]`
//!   内嵌 task/label，此处按 serde JSON 的实际形状**平铺展开**
//!   （与桌面 Tauri invoke 返回的 JSON 契约、移动端 data/api/dto.dart 一致）；
//! - UpdateInput 不镜像：其 `Option<Option<T>>` 三态语义依赖 core 的自定义
//!   serde 反序列化，FRB 参数面无法表达「null 与缺省键」之别，故 update 类
//!   继续走 patch_json 字符串（见 todo.rs 模块注释），仅在 Rust 内部反序列化。

use serde::Serialize;

// =============================================================================
// 通用过滤条件
// =============================================================================

/// 通用列表过滤条件（镜像 orbit_core::models::business::ListFilter；
/// 谓词下推七键仅 todo_tasks 消费，见 core 侧注释）
#[derive(Debug, Clone, Serialize)]
pub struct ListFilter {
    pub keyword: Option<String>,
    pub page: u32,
    pub page_size: u32,
    pub done: Option<bool>,
    pub status: Option<String>,
    pub priority_min: Option<i32>,
    pub project_id: Option<i64>,
    /// 项目 id **集合**（`project_id IN (...)`）：清单文件夹聚合——选中父
    /// 清单时客户端把「自身 + 全部后代项目 id」算好传入。非空时优先于
    /// [Self::project_id]；空集合 = 空结果。
    pub project_ids: Option<Vec<i64>>,
    pub favorite_only: Option<bool>,
    pub my_day_today: Option<i64>,
    /// 未分组视图：true = project_id IS NULL
    pub ungrouped: Option<bool>,
    /// 优先级等值（工具栏单值档）
    pub priority_eq: Option<i32>,
    /// 排除早于此时刻的截止（保留无截止行）：逾期置顶段已由独立查询取走
    pub exclude_due_before: Option<i64>,
    /// 是否有截止（日历「未排期」区用）：Some(false) = due_date IS NULL
    pub has_due: Option<bool>,
    /// 排序键（P1 键集分页）：manual/due/priority/created/done_at；title 走全量通道
    pub sort_key: Option<String>,
    /// 排序方向 asc/desc；None = 各档默认方向
    pub sort_dir: Option<String>,
    /// 截止区间下界（毫秒，含）：日历按可见范围取数
    pub due_from: Option<i64>,
    /// 截止区间上界（毫秒，不含）
    pub due_to: Option<i64>,
    /// 开始区间下界（毫秒，含）：日历时间轴按块起点取数
    pub start_from: Option<i64>,
    /// 开始区间上界（毫秒，不含）
    pub start_to: Option<i64>,
    /// 标签集合（任一命中）：空集合 = 不过滤
    pub label_ids: Option<Vec<i64>>,
    /// 有提醒：true = 至少一条活提醒，false = 一条也没有
    pub has_reminder: Option<bool>,
    /// 有附件：语义同上
    pub has_attachment: Option<bool>,
    /// 有未完成子任务：语义同上
    pub has_open_subtask: Option<bool>,
    /// 创建时间下界（毫秒，含）
    pub created_from: Option<i64>,
    /// 完成时间下界（毫秒，含；隐含只看已完成）
    pub done_from: Option<i64>,
    /// 状态**集合**（工具栏多选档）：派生状态口径（脏值回落 pending），
    /// `done` 档兼容「done = 1 或 status = 'done'」。与 [Self::status] 等值
    /// 互斥、集合优先；空集合 = 不过滤。
    pub status_in: Option<Vec<String>>,
}

impl From<orbit_core::models::business::ListFilter> for ListFilter {
    fn from(f: orbit_core::models::business::ListFilter) -> Self {
        Self {
            keyword: f.keyword,
            page: f.page,
            page_size: f.page_size,
            done: f.done,
            status: f.status,
            priority_min: f.priority_min,
            project_id: f.project_id,
            project_ids: f.project_ids,
            favorite_only: f.favorite_only,
            my_day_today: f.my_day_today,
            ungrouped: f.ungrouped,
            priority_eq: f.priority_eq,
            exclude_due_before: f.exclude_due_before,
            has_due: f.has_due,
            sort_key: f.sort_key,
            sort_dir: f.sort_dir,
            due_from: f.due_from,
            due_to: f.due_to,
            start_from: f.start_from,
            start_to: f.start_to,
            label_ids: f.label_ids,
            has_reminder: f.has_reminder,
            has_attachment: f.has_attachment,
            has_open_subtask: f.has_open_subtask,
            created_from: f.created_from,
            done_from: f.done_from,
            status_in: f.status_in,
        }
    }
}

impl From<ListFilter> for orbit_core::models::business::ListFilter {
    fn from(f: ListFilter) -> Self {
        Self {
            keyword: f.keyword,
            page: f.page,
            page_size: f.page_size,
            done: f.done,
            status: f.status,
            priority_min: f.priority_min,
            project_id: f.project_id,
            project_ids: f.project_ids,
            favorite_only: f.favorite_only,
            my_day_today: f.my_day_today,
            ungrouped: f.ungrouped,
            priority_eq: f.priority_eq,
            exclude_due_before: f.exclude_due_before,
            has_due: f.has_due,
            sort_key: f.sort_key,
            sort_dir: f.sort_dir,
            due_from: f.due_from,
            due_to: f.due_to,
            start_from: f.start_from,
            start_to: f.start_to,
            label_ids: f.label_ids,
            has_reminder: f.has_reminder,
            has_attachment: f.has_attachment,
            has_open_subtask: f.has_open_subtask,
            created_from: f.created_from,
            done_from: f.done_from,
            status_in: f.status_in,
        }
    }
}

// =============================================================================
// 键集分页（P1 50k 规模档）
// =============================================================================

/// 键集分页游标（镜像 orbit_core::models::business::ListCursor）
#[derive(Debug, Clone, Serialize)]
pub struct ListCursor {
    pub sort_key: String,
    pub dir: String,
    /// 主排序键值（position/priority/created_at/due_date）；due 档 None = 无截止尾段
    pub key: Option<f64>,
    /// 次排序键（仅 priority 档：同优先级按 position 升序）
    pub key2: Option<f64>,
    pub id: i64,
}

impl From<orbit_core::models::business::ListCursor> for ListCursor {
    fn from(c: orbit_core::models::business::ListCursor) -> Self {
        Self {
            sort_key: c.sort_key,
            dir: c.dir,
            key: c.key,
            key2: c.key2,
            id: c.id,
        }
    }
}

impl From<ListCursor> for orbit_core::models::business::ListCursor {
    fn from(c: ListCursor) -> Self {
        Self {
            sort_key: c.sort_key,
            dir: c.dir,
            key: c.key,
            key2: c.key2,
            id: c.id,
        }
    }
}

/// 任务分页结果（镜像 orbit_core::models::business::TodoTaskPage）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskPage {
    pub items: Vec<TodoTaskListItem>,
    pub next_cursor: Option<ListCursor>,
    pub has_more: bool,
}

/// 单个项目的未完成计数（镜像 orbit_core::models::business::TodoProjectUndone）
#[derive(Debug, Clone, Serialize)]
pub struct TodoProjectUndone {
    pub project_id: Option<i64>,
    pub count: i64,
}

/// 任务总览（镜像 orbit_core::models::business::TodoTaskOverview）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskOverview {
    pub total: i64,
    pub undone_by_project: Vec<TodoProjectUndone>,
}

/// 看板/四象限分组维度（镜像 orbit_core::models::business::BoardGroupBy）
#[derive(Debug, Clone, Copy, Serialize)]
pub enum BoardGroupBy {
    Project,
    Status,
    Priority,
    Due,
    Quadrant,
}

impl BoardGroupBy {
    /// `pub(crate)`：core 类型不得出现在 FRB 扫描面上（会要求 core 侧实现
    /// SseEncode，生成物直接编译失败）
    pub(crate) fn as_core(self) -> orbit_core::models::business::BoardGroupBy {
        match self {
            Self::Project => orbit_core::models::business::BoardGroupBy::Project,
            Self::Status => orbit_core::models::business::BoardGroupBy::Status,
            Self::Priority => orbit_core::models::business::BoardGroupBy::Priority,
            Self::Due => orbit_core::models::business::BoardGroupBy::Due,
            Self::Quadrant => orbit_core::models::business::BoardGroupBy::Quadrant,
        }
    }
}

/// 看板单列（镜像 orbit_core::models::business::TodoTaskBoardGroup）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskBoardGroup {
    pub key: String,
    pub total: i64,
    pub items: Vec<TodoTaskListItem>,
}

/// 看板/四象限一次往返（镜像 orbit_core::models::business::TodoTaskBoard）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskBoard {
    pub groups: Vec<TodoTaskBoardGroup>,
    pub total: i64,
}

impl From<orbit_core::models::business::TodoTaskBoard> for TodoTaskBoard {
    fn from(b: orbit_core::models::business::TodoTaskBoard) -> Self {
        Self {
            groups: b
                .groups
                .into_iter()
                .map(|g| TodoTaskBoardGroup {
                    key: g.key,
                    total: g.total,
                    items: g.items.into_iter().map(Into::into).collect(),
                })
                .collect(),
            total: b.total,
        }
    }
}

// =============================================================================
// todo_projects
// =============================================================================

/// 项目（镜像 orbit_core::models::business::TodoProject）
#[derive(Debug, Clone, Serialize)]
pub struct TodoProject {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub description: Option<String>,
    pub hex_color: String,
    pub sort_order: f64,
    /// M8 上级文件夹（父项目）的同步主键 uuid；None = 顶层
    pub parent_uuid: Option<String>,
    /// F1 回顾周期（天）；None/0 = 关闭（7=每周 14=每两周 30=每月）
    pub review_interval_days: Option<i64>,
    /// 上次回顾时间（毫秒）；None = 从未回顾
    pub review_last_at: Option<i64>,
    /// 回顾暂缓截止（毫秒，本地零点口径）；None = 未暂缓
    pub review_snooze_until: Option<i64>,
    pub is_archived: i32,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoProject> for TodoProject {
    fn from(p: orbit_core::models::business::TodoProject) -> Self {
        Self {
            id: p.id,
            uuid: p.uuid,
            title: p.title,
            description: p.description,
            hex_color: p.hex_color,
            sort_order: p.sort_order,
            parent_uuid: p.parent_uuid,
            review_interval_days: p.review_interval_days,
            review_last_at: p.review_last_at,
            review_snooze_until: p.review_snooze_until,
            is_archived: p.is_archived,
            is_deleted: p.is_deleted,
            created_at: p.created_at,
            updated_at: p.updated_at,
            deleted_at: p.deleted_at,
            version: p.version,
        }
    }
}

/// 回顾状态行（镜像 project_review_api::ProjectReviewStatus；F1 回顾中心用）
#[derive(Debug, Clone, Serialize)]
pub struct ProjectReviewStatus {
    pub project: TodoProject,
    /// 到期日序号（days since epoch，本地时区日界）
    pub due_day_index: i64,
    /// 已逾期天数（0 = 今天到期）
    pub overdue_days: i64,
    /// 项目内未完成且未软删的任务数
    pub open_task_count: i64,
}

impl From<orbit_core::api::project_review_api::ProjectReviewStatus> for ProjectReviewStatus {
    fn from(s: orbit_core::api::project_review_api::ProjectReviewStatus) -> Self {
        Self {
            project: s.project.into(),
            due_day_index: s.due_day_index,
            overdue_days: s.overdue_days,
            open_task_count: s.open_task_count,
        }
    }
}

/// 项目创建输入（镜像 TodoProjectCreateInput；create input 均为普通
/// Option<T>/T，无三态字段，可直接一一映射）
#[derive(Debug, Clone, Serialize)]
pub struct TodoProjectCreateInput {
    pub title: String,
    pub description: Option<String>,
    pub hex_color: Option<String>,
    pub sort_order: Option<f64>,
    /// 上级文件夹 uuid（M8）；None / 空白串 = 顶层
    pub parent_uuid: Option<String>,
}

impl From<TodoProjectCreateInput> for orbit_core::models::business::TodoProjectCreateInput {
    fn from(i: TodoProjectCreateInput) -> Self {
        Self {
            title: i.title,
            description: i.description,
            hex_color: i.hex_color,
            sort_order: i.sort_order,
            parent_uuid: i.parent_uuid,
        }
    }
}

// =============================================================================
// todo_tasks
// =============================================================================

/// 任务（镜像 orbit_core::models::business::TodoTask）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTask {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: i32,
    pub status: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_after: i64,
    pub repeat_mode: i32,
    /// #34 重复规则扩展（与 orbit-core TodoTask 同名列镜像）
    pub repeat_weekdays: i32,
    pub repeat_end_type: i32,
    pub repeat_end_param: i64,
    pub repeat_from_done: i32,
    /// #72 月高级语义（与 orbit-core TodoTask 同名列镜像）
    pub repeat_month_mode: i32,
    pub repeat_nth_week: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    pub my_day_date: Option<i64>,
    /// 任务预计时长（分钟，M9 阶段一）；None = 未设置
    pub duration_minutes: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoTask> for TodoTask {
    fn from(t: orbit_core::models::business::TodoTask) -> Self {
        Self {
            id: t.id,
            uuid: t.uuid,
            title: t.title,
            description: t.description,
            project_id: t.project_id,
            priority: t.priority,
            status: t.status,
            done: t.done,
            done_at: t.done_at,
            due_date: t.due_date,
            start_date: t.start_date,
            repeat_after: t.repeat_after,
            repeat_mode: t.repeat_mode,
            repeat_weekdays: t.repeat_weekdays,
            repeat_end_type: t.repeat_end_type,
            repeat_end_param: t.repeat_end_param,
            repeat_from_done: t.repeat_from_done,
            repeat_month_mode: t.repeat_month_mode,
            repeat_nth_week: t.repeat_nth_week,
            percent_done: t.percent_done,
            position: t.position,
            is_favorite: t.is_favorite,
            my_day_date: t.my_day_date,
            duration_minutes: t.duration_minutes,
            is_deleted: t.is_deleted,
            created_at: t.created_at,
            updated_at: t.updated_at,
            deleted_at: t.deleted_at,
            version: t.version,
        }
    }
}

/// 列表通道瘦行任务（镜像 orbit_core::models::business::TodoTaskListItem）
///
/// 内存治理 A2：列表通道不再回传 10 个零消费列（uuid / repeat_after /
/// 六个更细的 repeat_* / deleted_at / version），此处**刻意不镜像**这些字段——
/// FRB 只为签名的具体类型生成字段级 Dart 镜像，少一列就少一份解码与 Dart 对象
/// 分配。字段清单与 core 侧必须严格一致（core 文档注释列了消费边界与核实结论）。
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskListItem {
    pub id: i64,
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: i32,
    pub status: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_mode: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    /// 我的一天：加入当天本地零点 ms；None = 不在任何一天的 My Day
    pub my_day_date: Option<i64>,
    /// 任务预计时长（分钟，M9 阶段一）；None = 未设置
    pub duration_minutes: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

impl From<orbit_core::models::business::TodoTaskListItem> for TodoTaskListItem {
    fn from(t: orbit_core::models::business::TodoTaskListItem) -> Self {
        Self {
            id: t.id,
            title: t.title,
            description: t.description,
            project_id: t.project_id,
            priority: t.priority,
            status: t.status,
            done: t.done,
            done_at: t.done_at,
            due_date: t.due_date,
            start_date: t.start_date,
            repeat_mode: t.repeat_mode,
            percent_done: t.percent_done,
            position: t.position,
            is_favorite: t.is_favorite,
            my_day_date: t.my_day_date,
            duration_minutes: t.duration_minutes,
            is_deleted: t.is_deleted,
            created_at: t.created_at,
            updated_at: t.updated_at,
        }
    }
}

/// 任务创建输入（镜像 TodoTaskCreateInput；均为普通 Option<T>/T 字段）
///
/// 注：core 的 `TodoTaskUpdateInput` 才含 `Option<Option<T>>` 可空列
/// （project_id/done_at/due_date/start_date 等），不在此镜像，
/// 走 patch_json 路径。
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskCreateInput {
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: Option<i32>,
    pub status: Option<String>,
    pub done: Option<i32>,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_after: Option<i64>,
    pub repeat_mode: Option<i32>,
    pub repeat_weekdays: Option<i32>,
    pub repeat_end_type: Option<i32>,
    pub repeat_end_param: Option<i64>,
    pub repeat_from_done: Option<i32>,
    pub repeat_month_mode: Option<i32>,
    pub repeat_nth_week: Option<i32>,
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    pub my_day_date: Option<i64>,
    pub duration_minutes: Option<i64>,
}

impl From<TodoTaskCreateInput> for orbit_core::models::business::TodoTaskCreateInput {
    fn from(i: TodoTaskCreateInput) -> Self {
        Self {
            title: i.title,
            description: i.description,
            project_id: i.project_id,
            priority: i.priority,
            status: i.status,
            done: i.done,
            done_at: i.done_at,
            due_date: i.due_date,
            start_date: i.start_date,
            repeat_after: i.repeat_after,
            repeat_mode: i.repeat_mode,
            repeat_weekdays: i.repeat_weekdays,
            repeat_end_type: i.repeat_end_type,
            repeat_end_param: i.repeat_end_param,
            repeat_from_done: i.repeat_from_done,
            repeat_month_mode: i.repeat_month_mode,
            repeat_nth_week: i.repeat_nth_week,
            position: i.position,
            is_favorite: i.is_favorite,
            my_day_date: i.my_day_date,
            duration_minutes: i.duration_minutes,
        }
    }
}

// =============================================================================
// todo_subtasks
// =============================================================================

/// 子任务（镜像 orbit_core::models::business::TodoSubtask）
#[derive(Debug, Clone, Serialize)]
pub struct TodoSubtask {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub title: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub position: f64,
    /// 上级子任务（父）uuid；NULL = 顶层（M10 多层嵌套）
    pub parent_uuid: Option<String>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoSubtask> for TodoSubtask {
    fn from(s: orbit_core::models::business::TodoSubtask) -> Self {
        Self {
            id: s.id,
            uuid: s.uuid,
            task_id: s.task_id,
            title: s.title,
            done: s.done,
            done_at: s.done_at,
            position: s.position,
            parent_uuid: s.parent_uuid,
            is_deleted: s.is_deleted,
            created_at: s.created_at,
            updated_at: s.updated_at,
            deleted_at: s.deleted_at,
            version: s.version,
        }
    }
}

/// 子任务创建输入（镜像 TodoSubtaskCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoSubtaskCreateInput {
    pub task_id: i64,
    pub title: String,
    pub position: Option<f64>,
    /// 挂到哪个子任务下（父的 uuid）；None = 顶层。须与 task_id 同任务
    pub parent_uuid: Option<String>,
}

impl From<TodoSubtaskCreateInput> for orbit_core::models::business::TodoSubtaskCreateInput {
    fn from(i: TodoSubtaskCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            title: i.title,
            position: i.position,
            parent_uuid: i.parent_uuid,
        }
    }
}

// =============================================================================
// todo_labels
// =============================================================================

/// 标签（镜像 orbit_core::models::business::TodoLabel）
#[derive(Debug, Clone, Serialize)]
pub struct TodoLabel {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub hex_color: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoLabel> for TodoLabel {
    fn from(l: orbit_core::models::business::TodoLabel) -> Self {
        Self {
            id: l.id,
            uuid: l.uuid,
            title: l.title,
            hex_color: l.hex_color,
            is_deleted: l.is_deleted,
            created_at: l.created_at,
            updated_at: l.updated_at,
            deleted_at: l.deleted_at,
            version: l.version,
        }
    }
}

/// 标签创建输入（镜像 TodoLabelCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoLabelCreateInput {
    pub title: String,
    pub hex_color: Option<String>,
}

impl From<TodoLabelCreateInput> for orbit_core::models::business::TodoLabelCreateInput {
    fn from(i: TodoLabelCreateInput) -> Self {
        Self {
            title: i.title,
            hex_color: i.hex_color,
        }
    }
}

// =============================================================================
// todo_task_labels
// =============================================================================

/// 任务↔标签关联（镜像 orbit_core::models::business::TodoTaskLabel）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskLabel {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub label_id: i64,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoTaskLabel> for TodoTaskLabel {
    fn from(tl: orbit_core::models::business::TodoTaskLabel) -> Self {
        Self {
            id: tl.id,
            uuid: tl.uuid,
            task_id: tl.task_id,
            label_id: tl.label_id,
            is_deleted: tl.is_deleted,
            created_at: tl.created_at,
            updated_at: tl.updated_at,
            deleted_at: tl.deleted_at,
            version: tl.version,
        }
    }
}

/// 关联创建输入（镜像 TodoTaskLabelCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskLabelCreateInput {
    pub task_id: i64,
    pub label_id: i64,
}

impl From<TodoTaskLabelCreateInput> for orbit_core::models::business::TodoTaskLabelCreateInput {
    fn from(i: TodoTaskLabelCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            label_id: i.label_id,
        }
    }
}

// =============================================================================
// todo_comments
// =============================================================================

/// 评论（镜像 orbit_core::models::business::TodoComment）
#[derive(Debug, Clone, Serialize)]
pub struct TodoComment {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub content: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoComment> for TodoComment {
    fn from(c: orbit_core::models::business::TodoComment) -> Self {
        Self {
            id: c.id,
            uuid: c.uuid,
            task_id: c.task_id,
            content: c.content,
            is_deleted: c.is_deleted,
            created_at: c.created_at,
            updated_at: c.updated_at,
            deleted_at: c.deleted_at,
            version: c.version,
        }
    }
}

/// 评论创建输入（镜像 TodoCommentCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoCommentCreateInput {
    pub task_id: i64,
    pub content: String,
}

impl From<TodoCommentCreateInput> for orbit_core::models::business::TodoCommentCreateInput {
    fn from(i: TodoCommentCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            content: i.content,
        }
    }
}

// =============================================================================
// todo_task_relations
// =============================================================================

/// 任务关系（镜像 orbit_core::models::business::TodoTaskRelation）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskRelation {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub other_task_id: i64,
    pub relation_type: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoTaskRelation> for TodoTaskRelation {
    fn from(r: orbit_core::models::business::TodoTaskRelation) -> Self {
        Self {
            id: r.id,
            uuid: r.uuid,
            task_id: r.task_id,
            other_task_id: r.other_task_id,
            relation_type: r.relation_type,
            is_deleted: r.is_deleted,
            created_at: r.created_at,
            updated_at: r.updated_at,
            deleted_at: r.deleted_at,
            version: r.version,
        }
    }
}

/// 关系创建输入（镜像 TodoTaskRelationCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskRelationCreateInput {
    pub task_id: i64,
    pub other_task_id: i64,
    pub relation_type: String,
}

impl From<TodoTaskRelationCreateInput>
    for orbit_core::models::business::TodoTaskRelationCreateInput
{
    fn from(i: TodoTaskRelationCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            other_task_id: i.other_task_id,
            relation_type: i.relation_type,
        }
    }
}

// =============================================================================
// todo_reminders
// =============================================================================

/// 提醒（镜像 orbit_core::models::business::TodoReminder）
#[derive(Debug, Clone, Serialize)]
pub struct TodoReminder {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub remind_at: i64,
    /// 持续提醒标记（G2）：1 = 未完成则按间隔顺延重排（响到完成为止）
    pub is_constant: i32,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

impl From<orbit_core::models::business::TodoReminder> for TodoReminder {
    fn from(r: orbit_core::models::business::TodoReminder) -> Self {
        Self {
            id: r.id,
            uuid: r.uuid,
            task_id: r.task_id,
            remind_at: r.remind_at,
            is_constant: r.is_constant,
            is_deleted: r.is_deleted,
            created_at: r.created_at,
            updated_at: r.updated_at,
            deleted_at: r.deleted_at,
            version: r.version,
        }
    }
}

/// 提醒创建输入（镜像 TodoReminderCreateInput）
#[derive(Debug, Clone, Serialize)]
pub struct TodoReminderCreateInput {
    pub task_id: i64,
    pub remind_at: i64,
    /// 省略 = 0（一次性）——移动端表单未开持续提醒时传 0
    pub is_constant: i32,
}

impl From<TodoReminderCreateInput> for orbit_core::models::business::TodoReminderCreateInput {
    fn from(i: TodoReminderCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            remind_at: i.remind_at,
            is_constant: i.is_constant,
        }
    }
}

// =============================================================================
// 详情聚合（core #[serde(flatten)] 平铺镜像）
// =============================================================================

/// 任务详情中的标签：TodoLabel 全部字段 + task_label_id
///
/// core 版（orbit_core::api::todo_api::TaskLabelWithId）用
/// `#[serde(flatten)] label: TodoLabel`，JSON 为扁平形状；此处直接平铺。
#[derive(Debug, Clone, Serialize)]
pub struct TaskLabelWithId {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub hex_color: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
    /// todo_task_labels 关联记录自身 id（移除关联时用）
    pub task_label_id: i64,
}

impl From<orbit_core::api::todo_api::TaskLabelWithId> for TaskLabelWithId {
    fn from(tl: orbit_core::api::todo_api::TaskLabelWithId) -> Self {
        Self {
            id: tl.label.id,
            uuid: tl.label.uuid,
            title: tl.label.title,
            hex_color: tl.label.hex_color,
            is_deleted: tl.label.is_deleted,
            created_at: tl.label.created_at,
            updated_at: tl.label.updated_at,
            deleted_at: tl.label.deleted_at,
            version: tl.label.version,
            task_label_id: tl.task_label_id,
        }
    }
}

/// 任务详情聚合：TodoTask 全部字段 + 五张子表 Vec
///
/// core 版（orbit_core::api::todo_api::TodoTaskDetail）用
/// `#[serde(flatten)] task: TodoTask`，JSON 为扁平形状（与桌面 Tauri 契约、
/// 移动端 data/api/dto.dart 的 `TodoTaskDetail extends TodoTask` 一致）；
/// 此处平铺 task 字段，避免 Dart 侧出现嵌套差异。
#[derive(Debug, Clone, Serialize)]
pub struct TodoTaskDetail {
    // ── 展开 self.task（TodoTask）──
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: i32,
    pub status: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_after: i64,
    pub repeat_mode: i32,
    /// #34 重复规则扩展（与 orbit-core TodoTask 同名列镜像）
    pub repeat_weekdays: i32,
    pub repeat_end_type: i32,
    pub repeat_end_param: i64,
    pub repeat_from_done: i32,
    /// #72 月高级语义（与 orbit-core TodoTask 同名列镜像）
    pub repeat_month_mode: i32,
    pub repeat_nth_week: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    pub my_day_date: Option<i64>,
    /// 任务预计时长（分钟，M9 阶段一）；None = 未设置
    pub duration_minutes: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
    // ── 聚合子表 ──
    pub subtasks: Vec<TodoSubtask>,
    pub labels: Vec<TaskLabelWithId>,
    pub comments: Vec<TodoComment>,
    pub relations: Vec<TodoTaskRelation>,
    pub reminders: Vec<TodoReminder>,
}

impl From<orbit_core::api::todo_api::TodoTaskDetail> for TodoTaskDetail {
    fn from(d: orbit_core::api::todo_api::TodoTaskDetail) -> Self {
        Self {
            id: d.task.id,
            uuid: d.task.uuid,
            title: d.task.title,
            description: d.task.description,
            project_id: d.task.project_id,
            priority: d.task.priority,
            status: d.task.status,
            done: d.task.done,
            done_at: d.task.done_at,
            due_date: d.task.due_date,
            start_date: d.task.start_date,
            repeat_after: d.task.repeat_after,
            repeat_mode: d.task.repeat_mode,
            repeat_weekdays: d.task.repeat_weekdays,
            repeat_end_type: d.task.repeat_end_type,
            repeat_end_param: d.task.repeat_end_param,
            repeat_from_done: d.task.repeat_from_done,
            repeat_month_mode: d.task.repeat_month_mode,
            repeat_nth_week: d.task.repeat_nth_week,
            percent_done: d.task.percent_done,
            position: d.task.position,
            is_favorite: d.task.is_favorite,
            my_day_date: d.task.my_day_date,
            duration_minutes: d.task.duration_minutes,
            is_deleted: d.task.is_deleted,
            created_at: d.task.created_at,
            updated_at: d.task.updated_at,
            deleted_at: d.task.deleted_at,
            version: d.task.version,
            subtasks: d.subtasks.into_iter().map(TodoSubtask::from).collect(),
            labels: d.labels.into_iter().map(TaskLabelWithId::from).collect(),
            comments: d.comments.into_iter().map(TodoComment::from).collect(),
            relations: d
                .relations
                .into_iter()
                .map(TodoTaskRelation::from)
                .collect(),
            reminders: d.reminders.into_iter().map(TodoReminder::from).collect(),
        }
    }
}

/// 统一完成命令结果（镜像 orbit_core::api::todo_api::CompleteTaskResult；
/// 引擎下沉三端唯一完成入口：普通标记 / 重复任务单事务推进下一实例）
#[derive(Debug, Clone, Serialize)]
pub struct CompleteTaskResult {
    pub task: TodoTask,
    /// 重复任务推进生成的下一实例（普通任务为 None）
    pub next_instance: Option<TodoTask>,
}

impl From<orbit_core::api::todo_api::CompleteTaskResult> for CompleteTaskResult {
    fn from(r: orbit_core::api::todo_api::CompleteTaskResult) -> Self {
        Self {
            task: TodoTask::from(r.task),
            next_instance: r.next_instance.map(TodoTask::from),
        }
    }
}

// ---------- 任务列表投影聚合（A4，只读；镜像 orbit_core::api::todo_api 三投影） ----------

/// 行内标签 chip 最小载荷（镜像 ProjectedTaskLabel：展示三列）
#[derive(Debug, Clone, Serialize)]
pub struct ProjectedTaskLabel {
    pub id: i64,
    pub title: String,
    pub hex_color: String,
}

impl From<orbit_core::api::todo_api::ProjectedTaskLabel> for ProjectedTaskLabel {
    fn from(l: orbit_core::api::todo_api::ProjectedTaskLabel) -> Self {
        Self {
            id: l.id,
            title: l.title,
            hex_color: l.hex_color,
        }
    }
}

/// 单任务的标签分组（镜像 TaskLabelsProjection）
#[derive(Debug, Clone, Serialize)]
pub struct TaskLabelsProjection {
    pub task_id: i64,
    pub labels: Vec<ProjectedTaskLabel>,
}

impl From<orbit_core::api::todo_api::TaskLabelsProjection> for TaskLabelsProjection {
    fn from(g: orbit_core::api::todo_api::TaskLabelsProjection) -> Self {
        Self {
            task_id: g.task_id,
            labels: g.labels.into_iter().map(ProjectedTaskLabel::from).collect(),
        }
    }
}

/// 行内提醒最小载荷（镜像 ProjectedReminder）
#[derive(Debug, Clone, Serialize)]
pub struct ProjectedReminder {
    pub id: i64,
    pub remind_at: i64,
}

impl From<orbit_core::api::todo_api::ProjectedReminder> for ProjectedReminder {
    fn from(r: orbit_core::api::todo_api::ProjectedReminder) -> Self {
        Self {
            id: r.id,
            remind_at: r.remind_at,
        }
    }
}

/// 单任务的提醒分组（镜像 TaskRemindersProjection）
#[derive(Debug, Clone, Serialize)]
pub struct TaskRemindersProjection {
    pub task_id: i64,
    pub reminders: Vec<ProjectedReminder>,
}

impl From<orbit_core::api::todo_api::TaskRemindersProjection> for TaskRemindersProjection {
    fn from(g: orbit_core::api::todo_api::TaskRemindersProjection) -> Self {
        Self {
            task_id: g.task_id,
            reminders: g
                .reminders
                .into_iter()
                .map(ProjectedReminder::from)
                .collect(),
        }
    }
}

/// 单任务的关联计数旗标（镜像 TaskDependencyFlags；C7 行内关联徽标消费）
#[derive(Debug, Clone, Serialize)]
pub struct TaskDependencyFlags {
    pub task_id: i64,
    /// 出边存活行总数（> 0 即「有关联」）
    pub relation_count: i64,
}

impl From<orbit_core::api::todo_api::TaskDependencyFlags> for TaskDependencyFlags {
    fn from(f: orbit_core::api::todo_api::TaskDependencyFlags) -> Self {
        Self {
            task_id: f.task_id,
            relation_count: f.relation_count,
        }
    }
}

/// 「有描述」任务 id 位（镜像 TaskDescriptionFlag；列表通道裁剪 description
/// 后行内描述图标的来源，只出有描述的行）
#[derive(Debug, Clone, Serialize)]
pub struct TaskDescriptionFlag {
    pub task_id: i64,
}

impl From<orbit_core::api::todo_api::TaskDescriptionFlag> for TaskDescriptionFlag {
    fn from(f: orbit_core::api::todo_api::TaskDescriptionFlag) -> Self {
        Self { task_id: f.task_id }
    }
}

/// 任务存在旗标一位（#71 筛选器存在键数据源；镜像 TaskExistenceFlag，
/// 只出有行的任务，缺位即 false；附件/未完成子任务两投影共用）
#[derive(Debug, Clone, Serialize)]
pub struct TaskExistenceFlag {
    pub task_id: i64,
}

impl From<orbit_core::api::todo_api::TaskExistenceFlag> for TaskExistenceFlag {
    fn from(f: orbit_core::api::todo_api::TaskExistenceFlag) -> Self {
        Self { task_id: f.task_id }
    }
}

// ---------- CSV 导入（迁移路径；镜像 orbit_core::api::csv_import_api） ----------

/// 一条映射后的待导入行（预览载荷）
#[derive(Debug, Clone, Serialize)]
pub struct CsvImportRowView {
    /// 源 CSV 行号（1 起，含表头）
    pub source_line: usize,
    /// 目标项目标题（None = 未分组；执行时按需自动建项目）
    pub project_title: Option<String>,
    /// 待创建任务字段（部分填充）
    pub input: TodoTaskCreateInput,
    /// 跳过原因（Some = 本行不导入）
    pub skip_reason: Option<String>,
}

impl From<orbit_core::api::csv_import_api::CsvImportRow> for CsvImportRowView {
    fn from(r: orbit_core::api::csv_import_api::CsvImportRow) -> Self {
        // core → dto 方向无既有 From（出参历来只在 todo 域整任务镜像），
        // 此处逐字段映射（字段清单一致，见上方 TodoTaskCreateInput）
        let i = r.input;
        Self {
            source_line: r.source_line,
            project_title: r.project_title,
            input: TodoTaskCreateInput {
                title: i.title,
                description: i.description,
                project_id: i.project_id,
                priority: i.priority,
                status: i.status,
                done: i.done,
                done_at: i.done_at,
                due_date: i.due_date,
                start_date: i.start_date,
                repeat_after: i.repeat_after,
                repeat_mode: i.repeat_mode,
                repeat_weekdays: i.repeat_weekdays,
                repeat_end_type: i.repeat_end_type,
                repeat_end_param: i.repeat_end_param,
                repeat_from_done: i.repeat_from_done,
                repeat_month_mode: i.repeat_month_mode,
                repeat_nth_week: i.repeat_nth_week,
                position: i.position,
                is_favorite: i.is_favorite,
                my_day_date: i.my_day_date,
                duration_minutes: None,
            },
            skip_reason: r.skip_reason,
        }
    }
}

/// 导入统计（预览口径 success=待导入条数；执行口径=实际成功条数）
#[derive(Debug, Clone, Serialize)]
pub struct CsvImportStatsView {
    pub success: usize,
    pub skipped: usize,
    pub failed: usize,
    /// 逐行错误/跳过说明（行号 + 原因）
    pub notes: Vec<String>,
}

impl From<orbit_core::api::csv_import_api::CsvImportStats> for CsvImportStatsView {
    fn from(s: orbit_core::api::csv_import_api::CsvImportStats) -> Self {
        Self {
            success: s.success,
            skipped: s.skipped,
            failed: s.failed,
            notes: s.notes,
        }
    }
}

/// 预览结果：前 N 行预览载荷 + 全量统计
#[derive(Debug, Clone, Serialize)]
pub struct CsvImportPreviewView {
    pub preset: String,
    pub rows: Vec<CsvImportRowView>,
    pub stats: CsvImportStatsView,
}

impl From<orbit_core::api::csv_import_api::CsvImportPreview> for CsvImportPreviewView {
    fn from(p: orbit_core::api::csv_import_api::CsvImportPreview) -> Self {
        Self {
            preset: p.preset,
            rows: p.rows.into_iter().map(CsvImportRowView::from).collect(),
            stats: CsvImportStatsView::from(p.stats),
        }
    }
}

/// 导入限额（core ImportLimits 镜像）：Dart 侧选文件后先比对大小，超限即拦
#[derive(Debug, Clone, Serialize)]
pub struct ImportLimitsView {
    /// 单文件字节上限
    pub max_bytes: usize,
    /// 单文件数据行上限
    pub max_rows: usize,
}

impl From<orbit_core::api::csv_import_api::ImportLimits> for ImportLimitsView {
    fn from(l: orbit_core::api::csv_import_api::ImportLimits) -> Self {
        Self {
            max_bytes: l.max_bytes,
            max_rows: l.max_rows,
        }
    }
}

/// 可取消导入任务状态（core ImportJobStatus 镜像；UI 轮询用）
#[derive(Debug, Clone, Serialize)]
pub struct ImportJobStatusView {
    /// 任务 id（轮询与取消的句柄）
    pub job_id: String,
    /// 已处理行数（含跳过/失败）
    pub processed: usize,
    /// 预计总行数（启动前已数过，通常有值）
    pub total: Option<usize>,
    /// 是否已结束
    pub finished: bool,
    /// 是否被取消
    pub cancelled: bool,
    /// 结束时的统计（未结束为 None）
    pub stats: Option<CsvImportStatsView>,
    /// 结束时的错误说明
    pub error: Option<String>,
}

impl From<orbit_core::api::csv_import_api::ImportJobStatus> for ImportJobStatusView {
    fn from(s: orbit_core::api::csv_import_api::ImportJobStatus) -> Self {
        Self {
            job_id: s.job_id,
            processed: s.processed,
            total: s.total,
            finished: s.finished,
            cancelled: s.cancelled,
            stats: s.stats.map(CsvImportStatsView::from),
            error: s.error,
        }
    }
}

// ---------- holiday 域（cfg_holidays 缓存镜像；用户需求：日历视图联网更新节假日） ----------

/// 节假日行（core HolidayInfo 过桥镜像；FRB 字段级生成规则见模块注释）
#[derive(Debug, Clone)]
pub struct HolidayInfo {
    /// YYYY-MM-DD
    pub date: String,
    pub year: i32,
    /// true = 放假日；false = 调休补班日（要上班的周末）
    pub is_holiday: bool,
    /// 节假日名称（如「春节」「春节前补班」）
    pub name: String,
}

impl From<orbit_core::api::holiday_api::HolidayInfo> for HolidayInfo {
    fn from(h: orbit_core::api::holiday_api::HolidayInfo) -> Self {
        Self {
            date: h.date,
            year: h.year,
            is_holiday: h.is_holiday,
            name: h.name,
        }
    }
}

/// 节假日更新记账（上次更新/尝试时间、失败次数、自动更新开关；日历工具栏展示用）
#[derive(Debug, Clone)]
pub struct HolidayMeta {
    /// 上次「自动更新范围内年份」成功更新（ms；0 = 从未成功）
    pub last_update_ms: i64,
    /// 上次尝试（ms；0 = 从未尝试）
    pub last_attempt_ms: i64,
    /// 连续失败次数（成功后清零）
    pub failure_count: i32,
    /// 自动更新总开关（关闭后仅手动 / 按年补写）
    pub auto_enabled: bool,
}

impl From<orbit_core::api::holiday_api::HolidayMeta> for HolidayMeta {
    fn from(m: orbit_core::api::holiday_api::HolidayMeta) -> Self {
        Self {
            last_update_ms: m.last_update_ms,
            last_attempt_ms: m.last_attempt_ms,
            failure_count: m.failure_count,
            auto_enabled: m.auto_enabled,
        }
    }
}

/// 按单年补写结果（记账 + 该年实际行数；`row_count == 0` = 该年线上无数据）
#[derive(Debug, Clone)]
pub struct HolidayYearOutcome {
    pub meta: HolidayMeta,
    /// 该年实际拉取到的行数（0 = 线上无数据，UI 提示用）
    pub row_count: u32,
}

impl From<orbit_core::api::holiday_api::HolidayYearOutcome> for HolidayYearOutcome {
    fn from(o: orbit_core::api::holiday_api::HolidayYearOutcome) -> Self {
        Self {
            meta: HolidayMeta::from(o.meta),
            row_count: o.row_count,
        }
    }
}

/// 按年范围补写结果汇总
#[derive(Debug, Clone)]
pub struct HolidayRangeSummary {
    /// 成功写入（含空响应）的年份数
    pub ok: u32,
    /// 获取失败的年份数（含熔断后未尝试的年份）
    pub failed: u32,
    /// 成功但线上无数据的年份数
    pub empty: u32,
    /// 是否被中途取消
    pub cancelled: bool,
}

impl From<orbit_core::api::holiday_api::HolidayRangeSummary> for HolidayRangeSummary {
    fn from(s: orbit_core::api::holiday_api::HolidayRangeSummary) -> Self {
        Self {
            ok: s.ok,
            failed: s.failed,
            empty: s.empty,
            cancelled: s.cancelled,
        }
    }
}

/// 范围补写进度（core `HolidayProgress` 枚举的**平铺**镜像）
///
/// core 侧是 `#[serde(tag = "phase")]` 的带字段枚举；FRB api 扫描范围内无枚举
/// 先例，且带字段枚举的 Dart 生成形态（sealed class）与项目既有「本地 struct
/// 镜像」约定不一致，故此处按 serde 的实际形状**平铺**为单结构：
/// 只保证 `phase` 对应的字段有意义，其余字段为类型零值。
///
/// 字段命名刻意区分阶段前缀，避免跨变体同名不同型（core 的 `Year.ok` 是
/// `bool`「该年成功」，`Done.ok` 是 `u32`「成功年份数」——平铺后会撞名）：
/// - `year` 阶段：`total` / `year` / `done` / `year_ok` / `year_empty`
/// - `done` 阶段：`ok_count` / `failed` / `cancelled`
/// - `error` 阶段：`message`
#[derive(Debug, Clone)]
pub struct HolidayProgressDto {
    /// 阶段：`starting` / `year` / `done` / `error`
    pub phase: String,
    /// 总年份数（starting / year 阶段有效）
    pub total: u32,
    /// 当前年份（year 阶段有效）
    pub year: i32,
    /// 已结算年份数（year 阶段有效）
    pub done: u32,
    /// 该年是否拉取成功（year 阶段有效）
    pub year_ok: bool,
    /// 该年是否线上无数据（year 阶段有效）
    pub year_empty: bool,
    /// 成功写入（含空响应）的年份数（done 阶段有效）
    pub ok_count: u32,
    /// 获取失败的年份数（done 阶段有效）
    pub failed: u32,
    /// 是否被中途取消（done 阶段有效）
    pub cancelled: bool,
    /// 错误信息（error 阶段有效）
    pub message: String,
}

impl From<orbit_core::api::holiday_api::HolidayProgress> for HolidayProgressDto {
    fn from(p: orbit_core::api::holiday_api::HolidayProgress) -> Self {
        use orbit_core::api::holiday_api::HolidayProgress as P;
        let mut dto = Self {
            phase: String::new(),
            total: 0,
            year: 0,
            done: 0,
            year_ok: false,
            year_empty: false,
            ok_count: 0,
            failed: 0,
            cancelled: false,
            message: String::new(),
        };
        match p {
            P::Starting { total } => {
                dto.phase = "starting".into();
                dto.total = total;
            }
            P::Year {
                year,
                done,
                total,
                ok,
                empty,
            } => {
                dto.phase = "year".into();
                dto.year = year;
                dto.done = done;
                dto.total = total;
                dto.year_ok = ok;
                dto.year_empty = empty;
            }
            P::Done {
                ok,
                failed,
                cancelled,
            } => {
                dto.phase = "done".into();
                dto.ok_count = ok;
                dto.failed = failed;
                dto.cancelled = cancelled;
            }
            P::Error { message } => {
                dto.phase = "error".into();
                dto.message = message;
            }
        }
        dto
    }
}

// ---------- 任务附件（07 排查报告后续批次：附件功能；镜像桌面 TaskAttachmentView）----------
pub struct TaskAttachmentView {
    pub link_id: i64,
    pub link_uuid: String,
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    /// 0 = 尚未从云端拉回（云端有但本机未下载），UI 置灰打开入口
    pub is_local_cached: i32,
}

impl From<orbit_core::api::asset_api::TaskAttachmentView> for TaskAttachmentView {
    fn from(v: orbit_core::api::asset_api::TaskAttachmentView) -> Self {
        Self {
            link_id: v.link_id,
            link_uuid: v.link_uuid,
            hash: v.hash,
            original_name: v.original_name,
            mime_type: v.mime_type,
            size_bytes: v.size_bytes,
            is_local_cached: v.is_local_cached,
        }
    }
}

// ---------- 未使用附件（诊断页清理入口；镜像桌面 UnusedAttachmentView）----------
#[derive(Debug, Clone, Serialize)]
pub struct UnusedAttachmentView {
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    /// 0 = 尚未上传云端（删除后其他设备无法找回）
    pub is_uploaded: i32,
    pub is_local_cached: i32,
    pub created_at: i64,
}

impl From<orbit_core::api::asset_api::UnusedAttachmentView> for UnusedAttachmentView {
    fn from(v: orbit_core::api::asset_api::UnusedAttachmentView) -> Self {
        Self {
            hash: v.hash,
            original_name: v.original_name,
            mime_type: v.mime_type,
            size_bytes: v.size_bytes,
            is_uploaded: v.is_uploaded,
            is_local_cached: v.is_local_cached,
            created_at: v.created_at,
        }
    }
}

// ---------- 云端孤儿附件清理（docs/15）----------

/// 云端孤儿附件行（诊断页「云端存储」清单）
///
/// 与 `UnusedAttachmentView` 的区别：这是**云端对象**，不是本地账本行——
/// 体积有密文/明文两个来源，`kind` 标明整包/分片布局。
#[derive(Debug, Clone, Serialize)]
pub struct CloudUnusedAttachmentView {
    pub hash: String,
    /// 密文体积；WebDAV 分片形态为 0（目录条目没有长度）
    pub cipher_bytes: i64,
    /// 服务端最后修改时间（Unix 秒；<=0 表示不可得）
    pub last_modified: i64,
    /// 云端形态：`whole` / `chunked` / `both`
    pub kind: String,
    pub original_name: String,
    /// 本地账本明文体积（0 = 账本无该行）
    pub size_bytes: i64,
    pub is_local_cached: i32,
    pub is_uploaded: i32,
}

/// 云端孤儿扫描结果
#[derive(Debug, Clone, Serialize)]
pub struct CloudUnusedScanResult {
    pub items: Vec<CloudUnusedAttachmentView>,
    /// 清单 epoch：删除时原样回传做 CAS
    pub epoch: i64,
    pub min_age_secs: i64,
}

/// 云端孤儿删除结果
#[derive(Debug, Clone, Serialize)]
pub struct CloudUnusedDeleteResult {
    pub deleted_assets: i64,
    pub deleted_objects: i64,
    pub skipped_referenced: i64,
    pub local_rows_cleaned: i64,
    pub stale_manifest: bool,
    pub errors: Vec<String>,
}

impl From<orbit_core::api::cloud_sync_api::CloudUnusedAttachmentView>
    for CloudUnusedAttachmentView
{
    fn from(v: orbit_core::api::cloud_sync_api::CloudUnusedAttachmentView) -> Self {
        Self {
            hash: v.hash,
            cipher_bytes: v.cipher_bytes as i64,
            last_modified: v.last_modified,
            kind: v.kind,
            original_name: v.original_name,
            size_bytes: v.size_bytes,
            is_local_cached: v.is_local_cached,
            is_uploaded: v.is_uploaded,
        }
    }
}

impl From<orbit_core::api::cloud_sync_api::CloudUnusedScanResult> for CloudUnusedScanResult {
    fn from(v: orbit_core::api::cloud_sync_api::CloudUnusedScanResult) -> Self {
        Self {
            items: v.items.into_iter().map(Into::into).collect(),
            epoch: v.epoch as i64,
            min_age_secs: v.min_age_secs,
        }
    }
}

impl From<orbit_core::api::cloud_sync_api::CloudUnusedDeleteResult> for CloudUnusedDeleteResult {
    fn from(v: orbit_core::api::cloud_sync_api::CloudUnusedDeleteResult) -> Self {
        Self {
            deleted_assets: v.deleted_assets as i64,
            deleted_objects: v.deleted_objects as i64,
            skipped_referenced: v.skipped_referenced as i64,
            local_rows_cleaned: v.local_rows_cleaned as i64,
            stale_manifest: v.stale_manifest,
            errors: v.errors,
        }
    }
}

/// 孤儿数据分桶回收结果（镜像 core `OrphanChunkGcResult`；docs/07 #96 尾款）
#[derive(Debug, Clone, Serialize)]
pub struct OrphanChunkGcResult {
    /// 删除成功（含原本已不存在）的分桶对象数
    pub deleted_buckets: i64,
    /// 单对象失败明细（不中断整轮）
    pub errors: Vec<String>,
}

impl From<orbit_core::api::cloud_sync_api::OrphanChunkGcResult> for OrphanChunkGcResult {
    fn from(v: orbit_core::api::cloud_sync_api::OrphanChunkGcResult) -> Self {
        Self {
            deleted_buckets: v.deleted_buckets as i64,
            errors: v.errors,
        }
    }
}

/// 同步进度事件（镜像 core `cloud_sync::progress::SyncProgress`）
///
/// core 侧是 `#[serde(tag = "phase")]` 的内部标签 enum，FRB 不能直接镜像 enum
/// 变体，故压平成「`phase` 判别 + 全部变体字段可空」的单一 struct——与桌面
/// `SyncProgressEvent`（TS 接口）逐字段同形，双端 UI 文案可共用一套判据。
///
/// **不引入 `serde_json::Value`**：进度是高频流，每次序列化/反序列化一个
/// 动态 JSON 只会让 UI 线程多做一次解析；压平 struct 的字段全是基本类型，
/// FRB 走的是零解析的字段级传递。
#[derive(Debug, Clone, Serialize)]
pub struct SyncProgressDto {
    /// starting / pushing / pulling / merging / local_data_applied / attachments / done / error
    pub phase: String,
    /// background / manual / exit（UI 按来源过滤：设置页只认 manual）
    pub origin: String,
    /// 模块显示名（pushing/pulling/merging 有值）
    pub display_name: Option<String>,
    /// 当前序号（pushing/pulling/attachments 有值，1-based）
    pub current: Option<i64>,
    /// 总数（同上有值）
    pub total: Option<i64>,
    /// 错误消息（error 有值）
    pub message: Option<String>,
    /// 估算百分比 0-100（core `SyncProgress::percent` 同口径）
    pub percent: i64,
    /// 可直接展示的整句文案（core `SyncProgress::display_text` 同口径）
    ///
    /// 双端共用同一句中文：文案口径在 core 单点维护，避免 Dart 侧再抄一份
    /// 而与桌面漂移（桌面 `syncProgressText` 有自己的措辞，属既有实现，不动）。
    pub display_text: String,
}

impl From<orbit_core::cloud_sync::progress::SyncProgress> for SyncProgressDto {
    fn from(p: orbit_core::cloud_sync::progress::SyncProgress) -> Self {
        use orbit_core::cloud_sync::progress::SyncProgress as P;
        let origin = match &p {
            P::Starting { origin, .. }
            | P::Pushing { origin, .. }
            | P::Pulling { origin, .. }
            | P::Merging { origin, .. }
            | P::LocalDataApplied { origin, .. }
            | P::Attachments { origin, .. }
            | P::Done { origin, .. }
            | P::Error { origin, .. } => match origin {
                orbit_core::cloud_sync::progress::SyncOrigin::Background => "background",
                orbit_core::cloud_sync::progress::SyncOrigin::Manual => "manual",
                orbit_core::cloud_sync::progress::SyncOrigin::Exit => "exit",
            },
        };
        let (phase, display_name, current, total, message) = match &p {
            P::Starting { .. } => ("starting", None, None, None, None),
            P::Pushing {
                display_name,
                current,
                total,
                ..
            } => (
                "pushing",
                Some(display_name.clone()),
                Some(*current as i64),
                Some(*total as i64),
                None,
            ),
            P::Pulling {
                display_name,
                current,
                total,
                ..
            } => (
                "pulling",
                Some(display_name.clone()),
                Some(*current as i64),
                Some(*total as i64),
                None,
            ),
            P::Merging { display_name, .. } => {
                ("merging", Some(display_name.clone()), None, None, None)
            }
            P::LocalDataApplied { .. } => ("local_data_applied", None, None, None, None),
            P::Attachments {
                action,
                current,
                total,
                ..
            } => {
                // 附件档的 display_name 位借来放动作（upload/download），
                // 让 Dart 侧不必再判一次 phase 就能区分方向
                let name = if action == "upload" {
                    "upload"
                } else {
                    "download"
                };
                (
                    "attachments",
                    Some(name.to_string()),
                    Some(*current as i64),
                    Some(*total as i64),
                    None,
                )
            }
            P::Done { .. } => ("done", None, None, None, None),
            P::Error { message, .. } => ("error", None, None, None, Some(message.clone())),
        };
        Self {
            phase: phase.to_string(),
            origin: origin.to_string(),
            display_name,
            current,
            total,
            message,
            percent: p.percent() as i64,
            display_text: p.display_text(),
        }
    }
}

// ---------- todo_saved_filters（保存的筛选器，#35）----------
#[derive(Debug, Clone, Serialize)]
pub struct TodoSavedFilter {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    /// 条件 JSON：{status?, priority_min?, project_ids?, label_ids?, due_within_days?, due_overdue?, favorite_only?}
    pub conditions: String,
    pub sort_order: i64,
}

impl From<orbit_core::models::business::TodoSavedFilter> for TodoSavedFilter {
    fn from(f: orbit_core::models::business::TodoSavedFilter) -> Self {
        Self {
            id: f.id,
            uuid: f.uuid,
            name: f.name,
            conditions: f.conditions,
            sort_order: f.sort_order,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TodoSavedFilterCreateInput {
    pub name: String,
    pub conditions: String,
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TodoSavedFilterUpdateInput {
    pub name: Option<String>,
    pub conditions: Option<String>,
    pub sort_order: Option<i64>,
}

// ---------- todo_templates（任务模板）----------
#[derive(Debug, Clone, Serialize)]
pub struct TodoTemplate {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    /// 模板内容 JSON：{title?, notes?, priority?, due_offset_days?, subtasks?}——套用时按存在键预填
    pub payload: String,
    pub sort_order: i64,
}

impl From<orbit_core::models::business::TodoTemplate> for TodoTemplate {
    fn from(t: orbit_core::models::business::TodoTemplate) -> Self {
        Self {
            id: t.id,
            uuid: t.uuid,
            name: t.name,
            payload: t.payload,
            sort_order: t.sort_order,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TodoTemplateCreateInput {
    pub name: String,
    pub payload: String,
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TodoTemplateUpdateInput {
    pub name: Option<String>,
    pub payload: Option<String>,
    pub sort_order: Option<i64>,
}

// ---------- sync_conflicts（冲突败方副本，03 文档 §八 遗留项）----------
/// 冲突败方副本（纯本地表，不随云同步；两个 payload 为整行字段快照 JSON 字符串）
#[derive(Debug, Clone, Serialize)]
pub struct SyncConflict {
    pub id: i64,
    pub table_name: String,
    pub record_uuid: String,
    pub record_title: String,
    /// lww 时间戳裁决 / tie_version 同毫秒按 version 裁决
    pub decision: String,
    /// 败方归属：local 本地被覆盖 / remote 远端被丢弃
    pub loser_side: String,
    pub winner_side: String,
    pub loser_payload: String,
    pub winner_payload: String,
    pub loser_updated_at: i64,
    pub winner_updated_at: i64,
    /// unresolved 未处理 / restored 已恢复 / dismissed 已忽略
    pub resolution: String,
    pub created_at: i64,
    pub resolved_at: i64,
}

impl From<orbit_core::api::sync_conflict_api::SyncConflict> for SyncConflict {
    fn from(c: orbit_core::api::sync_conflict_api::SyncConflict) -> Self {
        Self {
            id: c.id,
            table_name: c.table_name,
            record_uuid: c.record_uuid,
            record_title: c.record_title,
            decision: c.decision,
            loser_side: c.loser_side,
            winner_side: c.winner_side,
            loser_payload: c.loser_payload,
            winner_payload: c.winner_payload,
            loser_updated_at: c.loser_updated_at,
            winner_updated_at: c.winner_updated_at,
            resolution: c.resolution,
            created_at: c.created_at,
            resolved_at: c.resolved_at,
        }
    }
}

// ---------- 任务活动日志（历史区块批次；镜像 core ActivityLogRow 查询视图）----------
/// 活动日志行（todo_activity_log 为本地轨迹表，不进同步白名单）
#[derive(Debug, Clone, serde::Serialize)]
pub struct ActivityLogRow {
    pub id: i64,
    pub task_id: Option<i64>,
    /// 任务标题快照（任务删除后仍可读）
    pub task_title: String,
    pub action: String,
    /// 附加 JSON：{"fields"/"changes"/"label"/"target"} 四代形状（格式化在 Dart 侧）
    pub detail: String,
    /// 记录时间（ms）
    pub created_at: i64,
}

impl From<orbit_core::api::activity_log_api::ActivityLogRow> for ActivityLogRow {
    fn from(r: orbit_core::api::activity_log_api::ActivityLogRow) -> Self {
        Self {
            id: r.id,
            task_id: r.task_id,
            task_title: r.task_title,
            action: r.action,
            detail: r.detail,
            created_at: r.created_at,
        }
    }
}
