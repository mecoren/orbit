//! business_cmd - Orbit MVP 命令面（todo 8 表 + 计数）
//!
//! 平移自 wait-home（02 文档 §四 A 类）；表集合与 db::sync_registry 对齐。

use orbit_core::api::business_api;
use orbit_core::models::business::*;
use tauri::State;

use crate::AppState;

// =============================================================================
// 其余 27 张表：list/get/delete（手写，保持与 business_api 一一对应）
// =============================================================================

// ---------- todo_projects ----------
#[tauri::command]
pub async fn todo_projects_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoProject>, String> {
    business_api::list_todo_projects(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_projects_get(state: State<'_, AppState>, id: i64) -> Result<TodoProject, String> {
    business_api::get_todo_project(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_projects_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_project(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_projects_create(
    state: State<'_, AppState>,
    input: TodoProjectCreateInput,
) -> Result<TodoProject, String> {
    business_api::create_todo_project(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_projects_update(
    state: State<'_, AppState>,
    id: i64,
    input: TodoProjectUpdateInput,
) -> Result<TodoProject, String> {
    business_api::update_todo_project(&state.pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}
/// 归档项目列表（侧栏「已归档」折叠区数据源；与 list 互斥的 is_archived=1 子集）
#[tauri::command]
pub async fn todo_projects_list_archived(
    state: State<'_, AppState>,
) -> Result<Vec<TodoProject>, String> {
    business_api::list_archived_todo_projects(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_tasks ----------
#[tauri::command]
pub async fn todo_tasks_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoTask>, String> {
    business_api::list_todo_tasks(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_tasks_get(state: State<'_, AppState>, id: i64) -> Result<TodoTask, String> {
    business_api::get_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_tasks_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_tasks_create(
    state: State<'_, AppState>,
    input: TodoTaskCreateInput,
) -> Result<TodoTask, String> {
    business_api::create_todo_task(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_tasks_update(
    state: State<'_, AppState>,
    id: i64,
    input: TodoTaskUpdateInput,
) -> Result<TodoTask, String> {
    business_api::update_todo_task(&state.pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_subtasks ----------
#[tauri::command]
pub async fn todo_subtasks_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoSubtask>, String> {
    business_api::list_todo_subtasks(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_subtasks_get(state: State<'_, AppState>, id: i64) -> Result<TodoSubtask, String> {
    business_api::get_todo_subtask(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_subtasks_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_subtask(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_subtasks_create(
    state: State<'_, AppState>,
    input: TodoSubtaskCreateInput,
) -> Result<TodoSubtask, String> {
    business_api::create_todo_subtask(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_subtasks_update(
    state: State<'_, AppState>,
    id: i64,
    input: TodoSubtaskUpdateInput,
) -> Result<TodoSubtask, String> {
    business_api::update_todo_subtask(&state.pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_labels ----------
#[tauri::command]
pub async fn todo_labels_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoLabel>, String> {
    business_api::list_todo_labels(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_labels_get(state: State<'_, AppState>, id: i64) -> Result<TodoLabel, String> {
    business_api::get_todo_label(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_labels_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_label(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_labels_create(
    state: State<'_, AppState>,
    input: TodoLabelCreateInput,
) -> Result<TodoLabel, String> {
    business_api::create_todo_label(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_labels_update(
    state: State<'_, AppState>,
    id: i64,
    input: TodoLabelUpdateInput,
) -> Result<TodoLabel, String> {
    business_api::update_todo_label(&state.pool, id, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_task_labels ----------
#[tauri::command]
pub async fn todo_task_labels_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoTaskLabel>, String> {
    business_api::list_todo_task_labels(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_labels_get(
    state: State<'_, AppState>,
    id: i64,
) -> Result<TodoTaskLabel, String> {
    business_api::get_todo_task_label(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_labels_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_task_label(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_labels_create(
    state: State<'_, AppState>,
    input: TodoTaskLabelCreateInput,
) -> Result<TodoTaskLabel, String> {
    business_api::create_todo_task_label(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_comments ----------
#[tauri::command]
pub async fn todo_comments_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoComment>, String> {
    business_api::list_todo_comments(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_comments_get(state: State<'_, AppState>, id: i64) -> Result<TodoComment, String> {
    business_api::get_todo_comment(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_comments_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_comment(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_comments_create(
    state: State<'_, AppState>,
    input: TodoCommentCreateInput,
) -> Result<TodoComment, String> {
    business_api::create_todo_comment(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_task_relations ----------
#[tauri::command]
pub async fn todo_task_relations_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoTaskRelation>, String> {
    business_api::list_todo_task_relations(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_relations_get(
    state: State<'_, AppState>,
    id: i64,
) -> Result<TodoTaskRelation, String> {
    business_api::get_todo_task_relation(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_relations_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_task_relation(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_task_relations_create(
    state: State<'_, AppState>,
    input: TodoTaskRelationCreateInput,
) -> Result<TodoTaskRelation, String> {
    business_api::create_todo_task_relation(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}

// ---------- todo_reminders ----------
#[tauri::command]
pub async fn todo_reminders_list(
    state: State<'_, AppState>,
    filter: ListFilter,
) -> Result<Vec<TodoReminder>, String> {
    business_api::list_todo_reminders(&state.pool, &filter)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_reminders_get(
    state: State<'_, AppState>,
    id: i64,
) -> Result<TodoReminder, String> {
    business_api::get_todo_reminder(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_reminders_delete(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    business_api::delete_todo_reminder(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn todo_reminders_create(
    state: State<'_, AppState>,
    input: TodoReminderCreateInput,
) -> Result<TodoReminder, String> {
    business_api::create_todo_reminder(&state.pool, &input)
        .await
        .map_err(|e| e.to_string())
}

// 注：cfg_theme_configs / sec_encryption_keys 的 list/get/delete 命令已删除（前端未使用）。
// 注：cfg_feature_modules 全链路（表/命令/同步）已删除（壳导航/强调色体系退役，前端无消费方）。

/// 用于首页仪表盘统计各模块记录数。
#[tauri::command]
pub async fn business_count(state: State<'_, AppState>, table: String) -> Result<i64, String> {
    let start = std::time::Instant::now();
    let result = business_api::business_count(&state.pool, &table)
        .await
        .map_err(|e| e.to_string());
    eprintln!(
        "[business_count] table={} elapsed={:?} result={:?}",
        table,
        start.elapsed(),
        result
    );
    result
}

// =============================================================================
// Phase 9A: 20 张业务表 get_by_uuid 命令（薄壳转发至 business_api）
//
// 用途：同步引擎定位远端记录、导入导出适配器按 uuid 引用实体等场景。
// 签名与移动端 FRB 调用一致：fn(pool, uuid: &str) -> Option<T>
// =============================================================================

/// 宏：为表批量生成 Tauri get_by_uuid 命令
/// 转发参数到 business_api 的同名函数，返回 Option<T>（不存在时为 None）
macro_rules! impl_cmd_get_by_uuid {
    ($fn_name:ident, $api_fn:path, $type:ty) => {
        #[tauri::command]
        pub async fn $fn_name(
            state: State<'_, AppState>,
            uuid: String,
        ) -> Result<Option<$type>, String> {
            $api_fn(&state.pool, &uuid).await.map_err(|e| e.to_string())
        }
    };
}

impl_cmd_get_by_uuid!(
    todo_projects_get_by_uuid,
    business_api::get_todo_project_by_uuid,
    TodoProject
);
impl_cmd_get_by_uuid!(
    todo_tasks_get_by_uuid,
    business_api::get_todo_task_by_uuid,
    TodoTask
);
