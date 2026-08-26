//! todo — 移动端桥接层 todo 域（8 表 CRUD + 详情聚合 + 排序/完成切换）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core）：
//! - [business_cmd](../../../../../apps/desktop/src-tauri/src/commands/business_cmd.rs) 的
//!   todo_{projects,tasks,subtasks,labels,task_labels,comments,task_relations,reminders}_
//!   list/get/create/delete 命令 → 委托 orbit_core::api::business_api 同名函数；
//! - [todo_cmd](../../../../../apps/desktop/src-tauri/src/commands/todo_cmd.rs) 的
//!   todo_tasks_get_detail / todo_subtasks_toggle_done / todo_tasks_update_position /
//!   todo_projects_update_sort_order → 委托 orbit_core::api::todo_api。
//!
//! ## DTO 镜像模式（本模块签名一律使用 [super::dto] 本地类型）
//! FRB 只为 rust_input 扫描范围内的类型定义生成字段级 Dart 镜像；
//! 直接把 orbit_core 的模型放进签名会被降级为 opaque（Dart 侧
//! `abstract class TodoProject implements RustOpaqueInterface {}`，无字段可访问，
//! i64 等整型亦无法精确传递）。因此：
//! - 出参：调 core 原函数后逐字段映射为本 crate DTO（[super::dto] 定义，
//!   经下方 pub use 供 frb_generated.rs 按 `crate::api::todo::*` 解析名字）；
//! - create 入参：接收本 crate DTO，经 `From<DTO> for core CreateInput`
//!   反向转换后调 core（core 各 CreateInput 均为普通 Option<T>/T 字段，
//!   无三态语义，直接一一映射）；
//! - update 入参：保持 patch_json: String 不变——core UpdateInput 用
//!   Option<Option<T>> + 自定义 nullable 反序列化表达三态
//!   （「缺省键=跳过该列 / null=清空为 NULL / 有值=更新」），
//!   serde_json::from_str 可无损还原；若直接作为 FRB 参数，
//!   Dart 无法区分 null 与缺省，三态退化为两态。UpdateInput 因此不做 DTO 镜像；
//! - TodoTaskDetail / TaskLabelWithId 在 core 中 #[serde(flatten)] 内嵌任务/标签，
//!   DTO 按扁平形状镜像（与桌面 Tauri JSON 契约一致），见 [super::dto]；
//! - get_by_uuid 不导出（移动端桥不消费）。

use orbit_core::api::{business_api, todo_api};
// patch_json 仅在本模块内部反序列化为 core UpdateInput（不过 FRB 桥）
use orbit_core::models::business::{
    TodoLabelUpdateInput, TodoProjectUpdateInput, TodoSubtaskUpdateInput, TodoTaskUpdateInput,
};

// pub use：frb_generated.rs 经 `use crate::api::todo::*` 解析这些类型名；
// 类型定义在 super::dto（FRB 扫描范围内 → 字段级镜像而非 opaque）。
// 注：TaskLabelWithId 仅作为 TodoTaskDetail.labels 的元素类型出现，
// 生成代码经 crate::api::dto 路径引用，无需在此再导出。
pub use super::dto::{
    ListFilter, TodoComment, TodoCommentCreateInput, TodoLabel, TodoLabelCreateInput, TodoProject,
    TodoProjectCreateInput, TodoReminder, TodoReminderCreateInput, TodoSubtask,
    TodoSubtaskCreateInput, TodoTask, TodoTaskCreateInput, TodoTaskDetail, TodoTaskLabel,
    TodoTaskLabelCreateInput, TodoTaskRelation, TodoTaskRelationCreateInput,
};

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

// =============================================================================
// todo_projects
// =============================================================================

/// 列出项目（对应桌面 todo_projects_list）
pub async fn todo_projects_list(filter: ListFilter) -> Result<Vec<TodoProject>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_projects(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoProject::from).collect())
}

/// 获取单个项目（对应桌面 todo_projects_get）
pub async fn todo_projects_get(id: i64) -> Result<TodoProject, String> {
    let pool = pool()?;
    business_api::get_todo_project(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoProject::from)
}

/// 创建项目（对应桌面 todo_projects_create）
pub async fn todo_projects_create(input: TodoProjectCreateInput) -> Result<TodoProject, String> {
    let pool = pool()?;
    business_api::create_todo_project(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoProject::from)
}

/// 更新项目（对应桌面 todo_projects_update；patch 三态语义见模块文档）
pub async fn todo_projects_update(id: i64, patch_json: String) -> Result<TodoProject, String> {
    let pool = pool()?;
    let input: TodoProjectUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_project(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoProject::from)
}

/// 删除项目（软删，对应桌面 todo_projects_delete）
pub async fn todo_projects_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_project(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新项目排序位置（拖拽排序，对应桌面 todo_cmd::todo_projects_update_sort_order）
pub async fn todo_projects_update_sort_order(id: i64, sort_order: f64) -> Result<(), String> {
    let pool = pool()?;
    todo_api::update_todo_project_sort_order(&pool, id, sort_order)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_tasks
// =============================================================================

/// 列出任务（对应桌面 todo_tasks_list）
pub async fn todo_tasks_list(filter: ListFilter) -> Result<Vec<TodoTask>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_tasks(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoTask::from).collect())
}

/// 获取单个任务（对应桌面 todo_tasks_get）
pub async fn todo_tasks_get(id: i64) -> Result<TodoTask, String> {
    let pool = pool()?;
    business_api::get_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTask::from)
}

/// 创建任务（对应桌面 todo_tasks_create）
pub async fn todo_tasks_create(input: TodoTaskCreateInput) -> Result<TodoTask, String> {
    let pool = pool()?;
    business_api::create_todo_task(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoTask::from)
}

/// 更新任务（对应桌面 todo_tasks_update；patch 三态语义见模块文档，
/// 如 project_id: null 表示移出项目，而缺省键表示不改归属）
pub async fn todo_tasks_update(id: i64, patch_json: String) -> Result<TodoTask, String> {
    let pool = pool()?;
    let input: TodoTaskUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_task(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTask::from)
}

/// 删除任务（软删，对应桌面 todo_tasks_delete）
pub async fn todo_tasks_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新任务排序位置（拖拽排序，对应桌面 todo_cmd::todo_tasks_update_position）
pub async fn todo_tasks_update_position(id: i64, position: f64) -> Result<(), String> {
    let pool = pool()?;
    todo_api::update_todo_task_position(&pool, id, position)
        .await
        .map_err(|e| e.to_string())
}

/// 任务详情聚合（含子任务/标签/评论/关系/提醒，对应桌面 todo_cmd::todo_tasks_get_detail）
pub async fn todo_tasks_get_detail(id: i64) -> Result<TodoTaskDetail, String> {
    let pool = pool()?;
    todo_api::get_todo_task_detail(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTaskDetail::from)
}

// =============================================================================
// todo_subtasks
// =============================================================================

/// 列出子任务（对应桌面 todo_subtasks_list）
pub async fn todo_subtasks_list(filter: ListFilter) -> Result<Vec<TodoSubtask>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_subtasks(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoSubtask::from).collect())
}

/// 获取单个子任务（对应桌面 todo_subtasks_get）
pub async fn todo_subtasks_get(id: i64) -> Result<TodoSubtask, String> {
    let pool = pool()?;
    business_api::get_todo_subtask(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoSubtask::from)
}

/// 创建子任务（对应桌面 todo_subtasks_create）
pub async fn todo_subtasks_create(input: TodoSubtaskCreateInput) -> Result<TodoSubtask, String> {
    let pool = pool()?;
    business_api::create_todo_subtask(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoSubtask::from)
}

/// 更新子任务（对应桌面 todo_subtasks_update；patch 三态语义见模块文档）
pub async fn todo_subtasks_update(id: i64, patch_json: String) -> Result<TodoSubtask, String> {
    let pool = pool()?;
    let input: TodoSubtaskUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_subtask(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoSubtask::from)
}

/// 删除子任务（软删，对应桌面 todo_subtasks_delete）
pub async fn todo_subtasks_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_subtask(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 切换子任务完成状态（对应桌面 todo_cmd::todo_subtasks_toggle_done；
/// core 内部自动重算父任务 percent_done）
pub async fn todo_subtasks_toggle_done(subtask_id: i64, done: bool) -> Result<(), String> {
    let pool = pool()?;
    todo_api::toggle_todo_subtask_done(&pool, subtask_id, done)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_labels
// =============================================================================

/// 列出标签（对应桌面 todo_labels_list）
pub async fn todo_labels_list(filter: ListFilter) -> Result<Vec<TodoLabel>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_labels(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoLabel::from).collect())
}

/// 创建标签（对应桌面 todo_labels_create）
pub async fn todo_labels_create(input: TodoLabelCreateInput) -> Result<TodoLabel, String> {
    let pool = pool()?;
    business_api::create_todo_label(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoLabel::from)
}

/// 更新标签（对应桌面 todo_labels_update；patch 三态语义见模块文档）
pub async fn todo_labels_update(id: i64, patch_json: String) -> Result<TodoLabel, String> {
    let pool = pool()?;
    let input: TodoLabelUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_label(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoLabel::from)
}

/// 删除标签（软删，对应桌面 todo_labels_delete）
pub async fn todo_labels_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_task_labels
// =============================================================================

/// 列出任务↔标签关联（对应桌面 todo_task_labels_list）
pub async fn todo_task_labels_list(filter: ListFilter) -> Result<Vec<TodoTaskLabel>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_task_labels(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoTaskLabel::from).collect())
}

/// 关联标签到任务（对应桌面 todo_task_labels_create）
pub async fn todo_task_labels_create(
    input: TodoTaskLabelCreateInput,
) -> Result<TodoTaskLabel, String> {
    let pool = pool()?;
    business_api::create_todo_task_label(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoTaskLabel::from)
}

/// 解除关联（软删，对应桌面 todo_task_labels_delete）
pub async fn todo_task_labels_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_task_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_comments
// =============================================================================

/// 列出评论（对应桌面 todo_comments_list）
pub async fn todo_comments_list(filter: ListFilter) -> Result<Vec<TodoComment>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_comments(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoComment::from).collect())
}

/// 获取单条评论（对应桌面 todo_comments_get）
pub async fn todo_comments_get(id: i64) -> Result<TodoComment, String> {
    let pool = pool()?;
    business_api::get_todo_comment(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoComment::from)
}

/// 创建评论（对应桌面 todo_comments_create）
pub async fn todo_comments_create(input: TodoCommentCreateInput) -> Result<TodoComment, String> {
    let pool = pool()?;
    business_api::create_todo_comment(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoComment::from)
}

/// 删除评论（软删，对应桌面 todo_comments_delete）
pub async fn todo_comments_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_comment(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_task_relations
// =============================================================================

/// 列出任务关系（对应桌面 todo_task_relations_list）
pub async fn todo_task_relations_list(filter: ListFilter) -> Result<Vec<TodoTaskRelation>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_task_relations(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoTaskRelation::from).collect())
}

/// 获取单条关系（对应桌面 todo_task_relations_get）
pub async fn todo_task_relations_get(id: i64) -> Result<TodoTaskRelation, String> {
    let pool = pool()?;
    business_api::get_todo_task_relation(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTaskRelation::from)
}

/// 创建任务关系（对应桌面 todo_task_relations_create）
pub async fn todo_task_relations_create(
    input: TodoTaskRelationCreateInput,
) -> Result<TodoTaskRelation, String> {
    let pool = pool()?;
    business_api::create_todo_task_relation(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoTaskRelation::from)
}

/// 删除任务关系（软删，对应桌面 todo_task_relations_delete）
pub async fn todo_task_relations_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_task_relation(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_reminders
// =============================================================================

/// 列出提醒（对应桌面 todo_reminders_list）
pub async fn todo_reminders_list(filter: ListFilter) -> Result<Vec<TodoReminder>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_reminders(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoReminder::from).collect())
}

/// 获取单条提醒（对应桌面 todo_reminders_get）
pub async fn todo_reminders_get(id: i64) -> Result<TodoReminder, String> {
    let pool = pool()?;
    business_api::get_todo_reminder(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoReminder::from)
}

/// 创建提醒（对应桌面 todo_reminders_create）
pub async fn todo_reminders_create(input: TodoReminderCreateInput) -> Result<TodoReminder, String> {
    let pool = pool()?;
    business_api::create_todo_reminder(&pool, &input.into())
        .await
        .map_err(|e| e.to_string())
        .map(TodoReminder::from)
}

/// 删除提醒（软删，对应桌面 todo_reminders_delete）
pub async fn todo_reminders_delete(id: i64) -> Result<(), String> {
    let pool = pool()?;
    business_api::delete_todo_reminder(&pool, id)
        .await
        .map_err(|e| e.to_string())
}
