//! todo — 移动端桥接层 todo 域（8 表 CRUD + 详情聚合 + 排序/完成切换）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core）：
//! - [business_cmd](../../../../../apps/desktop/src-tauri/src/commands/business_cmd.rs) 的
//!   todo_{projects,tasks,subtasks,labels,task_labels,comments,task_relations,reminders}_
//!   list/get/create/delete 命令 → 委托 orbit_core::api::business_api 同名函数；
//! - [todo_cmd](../../../../../apps/desktop/src-tauri/src/commands/todo_cmd.rs) 的
//!   todo_tasks_get_detail / todo_subtasks_toggle_done / todo_tasks_update_position /
//!   todo_projects_update_sort_order / task_labels_projection /
//!   task_reminders_projection / task_dependency_flags → 委托
//!   orbit_core::api::todo_api。
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
//!   DTO 按扁平形状镜像（与桌面 Tauri JSON 契约一致），见 [super::dto];
//! - get_by_uuid 已导出（todo_projects/tasks_get_by_uuid，与桌面 business_cmd 宏口径一致）；
//! - business_count / recalc_percent 只读聚合已对齐桌面。

use orbit_core::api::{business_api, todo_api};
// patch_json 仅在本模块内部反序列化为 core UpdateInput（不过 FRB 桥）
use orbit_core::models::business::{
    TodoLabelUpdateInput, TodoProjectUpdateInput, TodoSubtaskUpdateInput, TodoTaskUpdateInput,
};

// pub use：frb_generated.rs 经 `use crate::api::todo::*` 解析这些类型名；
// 类型定义在 super::dto（FRB 扫描范围内 → 字段级镜像而非 opaque）。
// 注：TaskLabelWithId 仅作为 TodoTaskDetail.labels 的元素类型出现，
// 生成代码经 crate::api::dto 路径引用，无需在此再导出。
// 同理 ProjectedTaskLabel / ProjectedReminder 仅作为分组 labels/reminders
// 的元素类型出现，不再导出（否则 unused_imports）。
pub use super::dto::{
    CompleteTaskResult, ListFilter, TaskDependencyFlags, TaskDescriptionFlag, TaskLabelsProjection,
    TaskRemindersProjection, TodoComment, TodoCommentCreateInput, TodoLabel, TodoLabelCreateInput,
    TodoProject, TodoProjectCreateInput, TodoReminder, TodoReminderCreateInput, TodoSubtask,
    TodoSubtaskCreateInput, TodoTask, TodoTaskCreateInput, TodoTaskDetail, TodoTaskLabel,
    TodoTaskLabelCreateInput, TodoTaskRelation, TodoTaskRelationCreateInput,
};

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

// =============================================================================
// todo_projects
// =============================================================================

/// 列出项目（对应桌面 todo_projects_list；默认排除已归档项目）
pub async fn todo_projects_list(filter: ListFilter) -> Result<Vec<TodoProject>, String> {
    let pool = pool()?;
    let items = business_api::list_todo_projects(&pool, &filter.into())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoProject::from).collect())
}

/// 归档项目列表（对应桌面 todo_projects_list_archived；侧栏归档区数据源。
/// 归档/取消归档走 todo_projects_update 的 patch_json {"is_archived":0|1}，
/// 无独立切换命令——与桌面 is_archived 谓词同口径）
pub async fn todo_projects_list_archived() -> Result<Vec<TodoProject>, String> {
    let pool = pool()?;
    let items = business_api::list_archived_todo_projects(&pool)
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

/// 统一完成任务（对应桌面 todo_cmd::todo_tasks_complete；引擎下沉后三端
/// 唯一完成入口——普通任务标记完成，重复任务单事务创建下一实例（含克隆
/// 子任务）再标记本实例，移动端由此补齐「完成后推进下一实例」断层）
pub async fn todo_tasks_complete(id: i64) -> Result<CompleteTaskResult, String> {
    let pool = pool()?;
    todo_api::complete_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(CompleteTaskResult::from)
}

/// 一键复制任务（#37 小而美批次；对应桌面 todo_cmd::todo_tasks_duplicate）——
/// 克隆字段+子任务（标题+顺序），完成态/提醒/标签/评论/关联/My Day 重置，
/// position 紧邻原任务，标题「（副本）」后缀
pub async fn todo_tasks_duplicate(id: i64) -> Result<super::dto::TodoTask, String> {
    let pool = pool()?;
    todo_api::duplicate_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(super::dto::TodoTask::from)
}

/// 重算任务进度（子任务变更后手动触发，对应桌面 todo_cmd::todo_tasks_recalc_percent）
pub async fn todo_tasks_recalc_percent(task_id: i64) -> Result<(), String> {
    let pool = pool()?;
    todo_api::recalc_task_percent_done(&pool, task_id)
        .await
        .map_err(|e| e.to_string())
}

/// 按 uuid 获取项目（对应桌面 todo_projects_get_by_uuid；同步引擎定位远端记录用）
pub async fn todo_projects_get_by_uuid(uuid: String) -> Result<Option<TodoProject>, String> {
    let pool = pool()?;
    business_api::get_todo_project_by_uuid(&pool, &uuid)
        .await
        .map_err(|e| e.to_string())
        .map(|opt| opt.map(TodoProject::from))
}

/// 按 uuid 获取任务（对应桌面 todo_tasks_get_by_uuid）
pub async fn todo_tasks_get_by_uuid(uuid: String) -> Result<Option<TodoTask>, String> {
    let pool = pool()?;
    business_api::get_todo_task_by_uuid(&pool, &uuid)
        .await
        .map_err(|e| e.to_string())
        .map(|opt| opt.map(TodoTask::from))
}

/// 业务表记录数（对应桌面 business_count；首页仪表盘计数角标，只读聚合）
pub async fn business_count(table: String) -> Result<i64, String> {
    let pool = pool()?;
    business_api::business_count(&pool, &table)
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

/// 子任务转独立任务（对应桌面 todo_cmd::todo_subtasks_promote；单事务：
/// 软删子任务行 + 承接父任务 project/priority/due 上下文建尾位新任务）
pub async fn todo_subtasks_promote(subtask_id: i64) -> Result<TodoTask, String> {
    let pool = pool()?;
    let created = todo_api::promote_todo_subtask(&pool, subtask_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(TodoTask::from(created))
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

/// 获取单个标签（对应桌面 todo_labels_get）
pub async fn todo_labels_get(id: i64) -> Result<TodoLabel, String> {
    let pool = pool()?;
    business_api::get_todo_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoLabel::from)
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

/// 获取单个任务↔标签关联（对应桌面 todo_task_labels_get）
pub async fn todo_task_labels_get(id: i64) -> Result<TodoTaskLabel, String> {
    let pool = pool()?;
    business_api::get_todo_task_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTaskLabel::from)
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

// =============================================================================
// 任务列表投影聚合（A4，只读；与桌面 task_*_projection 命令一一对应）
// =============================================================================

/// 任务→标签投影（对应桌面 task_labels_projection；一次往返替代两次整表）
pub async fn task_labels_projection() -> Result<Vec<TaskLabelsProjection>, String> {
    let pool = pool()?;
    todo_api::task_labels_projection(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|v| v.into_iter().map(TaskLabelsProjection::from).collect())
}

/// 任务→提醒投影（对应桌面 task_reminders_projection；组内 remind_at 升序）
pub async fn task_reminders_projection() -> Result<Vec<TaskRemindersProjection>, String> {
    let pool = pool()?;
    todo_api::task_reminders_projection(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|v| v.into_iter().map(TaskRemindersProjection::from).collect())
}

/// 任务→关联计数旗标（对应桌面 task_dependency_flags；Wave 5 的 C7 消费）
pub async fn task_dependency_flags() -> Result<Vec<TaskDependencyFlags>, String> {
    let pool = pool()?;
    todo_api::task_dependency_flags(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|v| v.into_iter().map(TaskDependencyFlags::from).collect())
}

/// 任务→「有描述」投影（对应桌面 task_description_flags；只出有描述的行）
pub async fn task_description_flags() -> Result<Vec<TaskDescriptionFlag>, String> {
    let pool = pool()?;
    todo_api::task_description_flags(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|v| v.into_iter().map(TaskDescriptionFlag::from).collect())
}
