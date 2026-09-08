//! saved_filter — 移动端桥接层：保存的筛选器（#35）
//!
//! 与桌面壳命令一一对应（薄包装，业务在 orbit_core::api::saved_filter_api）。
//! 条件应用在 Dart 侧完成（条件语义简单，不过服务端）。

use orbit_core::api::saved_filter_api;

use super::dto::{TodoSavedFilter, TodoSavedFilterCreateInput, TodoSavedFilterUpdateInput};
use super::state::with_state;

/// 列出全部保存的筛选器
pub async fn saved_filters_list() -> Result<Vec<TodoSavedFilter>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    saved_filter_api::list_saved_filters(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(TodoSavedFilter::from).collect())
}

/// 创建保存的筛选器
pub async fn saved_filter_create(
    input: TodoSavedFilterCreateInput,
) -> Result<TodoSavedFilter, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let core_input = orbit_core::models::business::TodoSavedFilterCreateInput {
        name: input.name,
        conditions: input.conditions,
        sort_order: input.sort_order,
    };
    saved_filter_api::create_saved_filter(&pool, &core_input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoSavedFilter::from)
}

/// 更新保存的筛选器
pub async fn saved_filter_update(
    id: i64,
    input: TodoSavedFilterUpdateInput,
) -> Result<TodoSavedFilter, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let core_input = orbit_core::models::business::TodoSavedFilterUpdateInput {
        name: input.name,
        conditions: input.conditions,
        sort_order: input.sort_order,
    };
    saved_filter_api::update_saved_filter(&pool, id, &core_input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoSavedFilter::from)
}

/// 删除保存的筛选器（软删）
pub async fn saved_filter_delete(id: i64) -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    saved_filter_api::delete_saved_filter(&pool, id)
        .await
        .map_err(|e| e.to_string())
}
