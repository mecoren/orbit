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
//! 与桌面的签名差异（FRB 约束）：
//! - update 类以 patch JSON 字符串传参（patch_json），而非结构体参数：
//!   core UpdateInput 用 Option<Option<T>> + 自定义 nullable 反序列化，
//!   serde_json::from_str 可完整还原三态语义——「缺省键=跳过该列 / null=清空为 NULL / 有值=更新」；
//!   若把 UpdateInput 直接作为 FRB 参数，Dart 侧无法区分 null 与缺省，三态退化为两态；
//! - create 类仍直接接收 core CreateInput（纯 i64/String/Option 组合，FRB 自动生成镜像类）；
//! - 返回类型直用 orbit_core::models::business::* 纯 serde 结构体（FRB 自动镜像）；
//! - get_by_uuid 不导出（移动端桥不消费）。

use orbit_core::api::{business_api, todo_api};
// pub use：frb_generated.rs 经 `use crate::api::todo::*` 解析这些类型名
pub use orbit_core::api::todo_api::TodoTaskDetail;
pub use orbit_core::models::business::*;

// =============================================================================
// todo_projects
// =============================================================================

/// 列出项目（对应桌面 todo_projects_list）
pub async fn todo_projects_list(filter: ListFilter) -> Result<Vec<TodoProject>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_projects(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单个项目（对应桌面 todo_projects_get）
pub async fn todo_projects_get(id: i64) -> Result<TodoProject, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_project(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建项目（对应桌面 todo_projects_create）
pub async fn todo_projects_create(input: TodoProjectCreateInput) -> Result<TodoProject, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_project(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 更新项目（对应桌面 todo_projects_update；patch 三态语义见模块文档）
pub async fn todo_projects_update(id: i64, patch_json: String) -> Result<TodoProject, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    let input: TodoProjectUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_project(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除项目（软删，对应桌面 todo_projects_delete）
pub async fn todo_projects_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_project(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新项目排序位置（拖拽排序，对应桌面 todo_cmd::todo_projects_update_sort_order）
pub async fn todo_projects_update_sort_order(id: i64, sort_order: f64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    todo_api::update_todo_project_sort_order(&pool, id, sort_order)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_tasks
// =============================================================================

/// 列出任务（对应桌面 todo_tasks_list）
pub async fn todo_tasks_list(filter: ListFilter) -> Result<Vec<TodoTask>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_tasks(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单个任务（对应桌面 todo_tasks_get）
pub async fn todo_tasks_get(id: i64) -> Result<TodoTask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建任务（对应桌面 todo_tasks_create）
pub async fn todo_tasks_create(input: TodoTaskCreateInput) -> Result<TodoTask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_task(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 更新任务（对应桌面 todo_tasks_update；patch 三态语义见模块文档，
/// 如 project_id: null 表示移出项目，而缺省键表示不改归属）
pub async fn todo_tasks_update(id: i64, patch_json: String) -> Result<TodoTask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    let input: TodoTaskUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_task(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除任务（软删，对应桌面 todo_tasks_delete）
pub async fn todo_tasks_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新任务排序位置（拖拽排序，对应桌面 todo_cmd::todo_tasks_update_position）
pub async fn todo_tasks_update_position(id: i64, position: f64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    todo_api::update_todo_task_position(&pool, id, position)
        .await
        .map_err(|e| e.to_string())
}

/// 任务详情聚合（含子任务/标签/评论/关系/提醒，对应桌面 todo_cmd::todo_tasks_get_detail）
pub async fn todo_tasks_get_detail(id: i64) -> Result<todo_api::TodoTaskDetail, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    todo_api::get_todo_task_detail(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_subtasks
// =============================================================================

/// 列出子任务（对应桌面 todo_subtasks_list）
pub async fn todo_subtasks_list(filter: ListFilter) -> Result<Vec<TodoSubtask>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_subtasks(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单个子任务（对应桌面 todo_subtasks_get）
pub async fn todo_subtasks_get(id: i64) -> Result<TodoSubtask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_subtask(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建子任务（对应桌面 todo_subtasks_create）
pub async fn todo_subtasks_create(input: TodoSubtaskCreateInput) -> Result<TodoSubtask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_subtask(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 更新子任务（对应桌面 todo_subtasks_update；patch 三态语义见模块文档）
pub async fn todo_subtasks_update(id: i64, patch_json: String) -> Result<TodoSubtask, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    let input: TodoSubtaskUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_subtask(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除子任务（软删，对应桌面 todo_subtasks_delete）
pub async fn todo_subtasks_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_subtask(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 切换子任务完成状态（对应桌面 todo_cmd::todo_subtasks_toggle_done；
/// core 内部自动重算父任务 percent_done）
pub async fn todo_subtasks_toggle_done(subtask_id: i64, done: bool) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    todo_api::toggle_todo_subtask_done(&pool, subtask_id, done)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_labels
// =============================================================================

/// 列出标签（对应桌面 todo_labels_list）
pub async fn todo_labels_list(filter: ListFilter) -> Result<Vec<TodoLabel>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_labels(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 创建标签（对应桌面 todo_labels_create）
pub async fn todo_labels_create(input: TodoLabelCreateInput) -> Result<TodoLabel, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_label(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 更新标签（对应桌面 todo_labels_update；patch 三态语义见模块文档）
pub async fn todo_labels_update(id: i64, patch_json: String) -> Result<TodoLabel, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    let input: TodoLabelUpdateInput =
        serde_json::from_str(&patch_json).map_err(|e| e.to_string())?;
    business_api::update_todo_label(&pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除标签（软删，对应桌面 todo_labels_delete）
pub async fn todo_labels_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_task_labels
// =============================================================================

/// 列出任务↔标签关联（对应桌面 todo_task_labels_list）
pub async fn todo_task_labels_list(filter: ListFilter) -> Result<Vec<TodoTaskLabel>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_task_labels(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 关联标签到任务（对应桌面 todo_task_labels_create）
pub async fn todo_task_labels_create(
    input: TodoTaskLabelCreateInput,
) -> Result<TodoTaskLabel, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_task_label(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 解除关联（软删，对应桌面 todo_task_labels_delete）
pub async fn todo_task_labels_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_task_label(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_comments
// =============================================================================

/// 列出评论（对应桌面 todo_comments_list）
pub async fn todo_comments_list(filter: ListFilter) -> Result<Vec<TodoComment>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_comments(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单条评论（对应桌面 todo_comments_get）
pub async fn todo_comments_get(id: i64) -> Result<TodoComment, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_comment(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建评论（对应桌面 todo_comments_create）
pub async fn todo_comments_create(input: TodoCommentCreateInput) -> Result<TodoComment, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_comment(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除评论（软删，对应桌面 todo_comments_delete）
pub async fn todo_comments_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_comment(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_task_relations
// =============================================================================

/// 列出任务关系（对应桌面 todo_task_relations_list）
pub async fn todo_task_relations_list(
    filter: ListFilter,
) -> Result<Vec<TodoTaskRelation>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_task_relations(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单条关系（对应桌面 todo_task_relations_get）
pub async fn todo_task_relations_get(id: i64) -> Result<TodoTaskRelation, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_task_relation(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建任务关系（对应桌面 todo_task_relations_create）
pub async fn todo_task_relations_create(
    input: TodoTaskRelationCreateInput,
) -> Result<TodoTaskRelation, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_task_relation(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除任务关系（软删，对应桌面 todo_task_relations_delete）
pub async fn todo_task_relations_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_task_relation(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// =============================================================================
// todo_reminders
// =============================================================================

/// 列出提醒（对应桌面 todo_reminders_list）
pub async fn todo_reminders_list(filter: ListFilter) -> Result<Vec<TodoReminder>, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::list_todo_reminders(&pool, &filter)
        .await
        .map_err(|e| e.to_string())
}

/// 获取单条提醒（对应桌面 todo_reminders_get）
pub async fn todo_reminders_get(id: i64) -> Result<TodoReminder, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::get_todo_reminder(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 创建提醒（对应桌面 todo_reminders_create）
pub async fn todo_reminders_create(input: TodoReminderCreateInput) -> Result<TodoReminder, String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::create_todo_reminder(&pool, &input)
        .await
        .map_err(|e| e.to_string())
}

/// 删除提醒（软删，对应桌面 todo_reminders_delete）
pub async fn todo_reminders_delete(id: i64) -> Result<(), String> {
    let pool = super::state::with_state(|s| Ok(s.pool.clone()))?;
    business_api::delete_todo_reminder(&pool, id)
        .await
        .map_err(|e| e.to_string())
}
