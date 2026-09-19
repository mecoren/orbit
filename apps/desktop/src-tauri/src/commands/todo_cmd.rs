//! 待办模块 Tauri 命令（复杂查询）
//!
//! 转发至 rust_core::api::todo_api：
//! - 任务详情（含子任务/标签/评论/关系/提醒）
//! - 子任务完成切换
//! - 任务/项目排序位置更新（拖拽）

use orbit_core::api::business_api;
use orbit_core::api::business_api::GlobalSearchResult;
use orbit_core::api::todo_api;
use orbit_core::models::business::TodoTask;
use tauri::State;

use crate::AppState;

/// 查询任务详情（含关联数据）
#[tauri::command]
pub async fn todo_tasks_get_detail(
    state: State<'_, AppState>,
    id: i64,
) -> Result<todo_api::TodoTaskDetail, String> {
    todo_api::get_todo_task_detail(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 切换子任务完成状态（自动重算父任务进度）
#[tauri::command]
pub async fn todo_subtasks_toggle_done(
    state: State<'_, AppState>,
    subtask_id: i64,
    done: bool,
) -> Result<(), String> {
    todo_api::toggle_todo_subtask_done(&state.pool, subtask_id, done)
        .await
        .map_err(|e| e.to_string())
}

/// 子任务转独立任务（单事务：软删子任务行 + 承接父任务上下文建新任务）
#[tauri::command]
pub async fn todo_subtasks_promote(
    state: State<'_, AppState>,
    subtask_id: i64,
) -> Result<TodoTask, String> {
    todo_api::promote_todo_subtask(&state.pool, subtask_id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新任务排序位置（拖拽排序）
#[tauri::command]
pub async fn todo_tasks_update_position(
    state: State<'_, AppState>,
    id: i64,
    position: f64,
) -> Result<(), String> {
    todo_api::update_todo_task_position(&state.pool, id, position)
        .await
        .map_err(|e| e.to_string())
}

/// 统一完成任务（引擎下沉后三端唯一入口：普通标记 / 重复任务单事务推进下一实例）
#[tauri::command]
pub async fn todo_tasks_complete(
    state: State<'_, AppState>,
    id: i64,
) -> Result<todo_api::CompleteTaskResult, String> {
    todo_api::complete_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 一键复制任务（#37 小而美批次：克隆字段+子任务，完成态/社交字段重置）
#[tauri::command]
pub async fn todo_tasks_duplicate(
    state: State<'_, AppState>,
    id: i64,
) -> Result<TodoTask, String> {
    todo_api::duplicate_todo_task(&state.pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 更新项目排序位置（拖拽排序）
#[tauri::command]
pub async fn todo_projects_update_sort_order(
    state: State<'_, AppState>,
    id: i64,
    sort_order: f64,
) -> Result<(), String> {
    todo_api::update_todo_project_sort_order(&state.pool, id, sort_order)
        .await
        .map_err(|e| e.to_string())
}

/// 重算任务进度（子任务变更后手动触发）
#[tauri::command]
pub async fn todo_tasks_recalc_percent(
    state: State<'_, AppState>,
    task_id: i64,
) -> Result<(), String> {
    todo_api::recalc_task_percent_done(&state.pool, task_id)
        .await
        .map_err(|e| e.to_string())
}

/// 全局跨表搜索（07 报告 §五-P1#9）：tasks/projects/comments 三路聚合
#[tauri::command]
pub async fn global_search(
    state: State<'_, AppState>,
    keyword: String,
    limit: Option<i32>,
) -> Result<GlobalSearchResult, String> {
    business_api::search_all(&state.pool, &keyword, limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())
}

// ---------- 任务列表投影聚合（A4，只读） ----------
//
// 薄壳转发 orbit_core::api::todo_api 三投影（不 emit、不进同步白名单）：
// - `task_labels_projection`：任务→标签 chips（替代 labels+task_labels 两次整表）；
// - `task_reminders_projection`：任务→提醒徽标（替代万行提醒整表）；
// - `task_dependency_flags`：任务→关联计数（Wave 5 的 C7 列表徽标用）。

/// 任务→标签投影（一次往返；组内按 label id 升序）
#[tauri::command]
pub async fn task_labels_projection(
    state: State<'_, AppState>,
) -> Result<Vec<todo_api::TaskLabelsProjection>, String> {
    todo_api::task_labels_projection(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 任务→提醒投影（一次往返；组内按 remind_at 升序）
#[tauri::command]
pub async fn task_reminders_projection(
    state: State<'_, AppState>,
) -> Result<Vec<todo_api::TaskRemindersProjection>, String> {
    todo_api::task_reminders_projection(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

/// 任务→关联计数旗标（仅出边存活行；C7 消费前无前端调用方）
#[tauri::command]
pub async fn task_dependency_flags(
    state: State<'_, AppState>,
) -> Result<Vec<todo_api::TaskDependencyFlags>, String> {
    todo_api::task_dependency_flags(&state.pool)
        .await
        .map_err(|e| e.to_string())
}
