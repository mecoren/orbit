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

/// 通用列表过滤条件（镜像 orbit_core::models::business::ListFilter）
#[derive(Debug, Clone, Serialize)]
pub struct ListFilter {
    pub keyword: Option<String>,
    pub page: u32,
    pub page_size: u32,
}

impl From<orbit_core::models::business::ListFilter> for ListFilter {
    fn from(f: orbit_core::models::business::ListFilter) -> Self {
        Self {
            keyword: f.keyword,
            page: f.page,
            page_size: f.page_size,
        }
    }
}

impl From<ListFilter> for orbit_core::models::business::ListFilter {
    fn from(f: ListFilter) -> Self {
        Self {
            keyword: f.keyword,
            page: f.page,
            page_size: f.page_size,
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
            is_deleted: p.is_deleted,
            created_at: p.created_at,
            updated_at: p.updated_at,
            deleted_at: p.deleted_at,
            version: p.version,
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
}

impl From<TodoProjectCreateInput> for orbit_core::models::business::TodoProjectCreateInput {
    fn from(i: TodoProjectCreateInput) -> Self {
        Self {
            title: i.title,
            description: i.description,
            hex_color: i.hex_color,
            sort_order: i.sort_order,
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
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    pub my_day_date: Option<i64>,
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
            percent_done: t.percent_done,
            position: t.position,
            is_favorite: t.is_favorite,
            my_day_date: t.my_day_date,
            is_deleted: t.is_deleted,
            created_at: t.created_at,
            updated_at: t.updated_at,
            deleted_at: t.deleted_at,
            version: t.version,
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
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    pub my_day_date: Option<i64>,
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
            position: i.position,
            is_favorite: i.is_favorite,
            my_day_date: i.my_day_date,
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
}

impl From<TodoSubtaskCreateInput> for orbit_core::models::business::TodoSubtaskCreateInput {
    fn from(i: TodoSubtaskCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            title: i.title,
            position: i.position,
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
}

impl From<TodoReminderCreateInput> for orbit_core::models::business::TodoReminderCreateInput {
    fn from(i: TodoReminderCreateInput) -> Self {
        Self {
            task_id: i.task_id,
            remind_at: i.remind_at,
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
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    pub my_day_date: Option<i64>,
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
            percent_done: d.task.percent_done,
            position: d.task.position,
            is_favorite: d.task.is_favorite,
            my_day_date: d.task.my_day_date,
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
                position: i.position,
                is_favorite: i.is_favorite,
                my_day_date: i.my_day_date,
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

/// 节假日更新记账（上次更新时间/失败次数/固定时刻；日历工具栏展示用）
#[derive(Debug, Clone)]
pub struct HolidayMeta {
    /// 上次成功更新（ms；0 = 从未成功）
    pub last_update_ms: i64,
    /// 上次尝试（ms；0 = 从未尝试）
    pub last_attempt_ms: i64,
    /// 连续失败次数（成功后清零）
    pub failure_count: i32,
    /// 每日固定更新时刻（本地时区小时 0-23；默认 8）
    pub fixed_hour: u32,
}

impl From<orbit_core::api::holiday_api::HolidayMeta> for HolidayMeta {
    fn from(m: orbit_core::api::holiday_api::HolidayMeta) -> Self {
        Self {
            last_update_ms: m.last_update_ms,
            last_attempt_ms: m.last_attempt_ms,
            failure_count: m.failure_count,
            fixed_hour: m.fixed_hour,
        }
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
