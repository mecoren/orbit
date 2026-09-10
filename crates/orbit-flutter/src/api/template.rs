//! template — 移动端桥接层：任务模板（竞品矩阵高价值缺口）
//!
//! 与桌面壳命令一一对应（薄包装，业务在 orbit_core::api::template_api）。
//! 套用（按 payload 预填任务表单）在 Dart 侧完成——预填是纯 UI 行为。

use orbit_core::api::template_api;

use super::dto::{TodoTemplate, TodoTemplateCreateInput, TodoTemplateUpdateInput};
use super::state::with_state;

/// 列出全部任务模板
pub async fn templates_list() -> Result<Vec<TodoTemplate>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    template_api::list_templates(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(TodoTemplate::from).collect())
}

/// 创建任务模板
pub async fn template_create(input: TodoTemplateCreateInput) -> Result<TodoTemplate, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let core_input = orbit_core::models::business::TodoTemplateCreateInput {
        name: input.name,
        payload: input.payload,
        sort_order: input.sort_order,
    };
    template_api::create_template(&pool, &core_input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTemplate::from)
}

/// 更新任务模板
pub async fn template_update(
    id: i64,
    input: TodoTemplateUpdateInput,
) -> Result<TodoTemplate, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let core_input = orbit_core::models::business::TodoTemplateUpdateInput {
        name: input.name,
        payload: input.payload,
        sort_order: input.sort_order,
    };
    template_api::update_template(&pool, id, &core_input)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTemplate::from)
}

/// 删除任务模板（软删）
pub async fn template_delete(id: i64) -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    template_api::delete_template(&pool, id)
        .await
        .map_err(|e| e.to_string())
}
