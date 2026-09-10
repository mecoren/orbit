//! widget — 移动端桥接层：Android 桌面小组件数据口（#3）
//!
//! 与桌面壳命令一一对应（薄包装，业务在 orbit_core::api::widget_api）。
//! 查询供 Dart 快照写入 home_widget；勾选由原生广播经互操作回调转发到
//! 这里落库（完成复用 complete 全语义，见 widget_api 模块文档）。

use orbit_core::api::widget_api;

use super::state::with_state;

/// 小组件任务行（FRB 镜像；RemoteViews 渲染最小字段集）
#[derive(Debug, Clone, serde::Serialize)]
pub struct WidgetTodoItem {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub priority: i32,
    pub done: i32,
}

impl From<orbit_core::api::widget_api::WidgetTodoItem> for WidgetTodoItem {
    fn from(i: orbit_core::api::widget_api::WidgetTodoItem) -> Self {
        Self {
            id: i.id,
            uuid: i.uuid,
            title: i.title,
            priority: i.priority,
            done: i.done,
        }
    }
}

/// 拉小组件快照：今天截止或已逾期的未完成任务（优先级降序，limit 截断）
pub async fn widget_todo_query(limit: i64) -> Result<Vec<WidgetTodoItem>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    widget_api::widget_todo_query(&pool, limit)
        .await
        .map_err(|e| e.to_string())
        .map(|list| list.into_iter().map(WidgetTodoItem::from).collect())
}

/// 小组件勾选切换（done=1 完成 / 0 取消；完成复用 complete 全语义）
pub async fn widget_todo_toggle(id: i64, done: i32) -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    widget_api::widget_todo_toggle(&pool, id, done)
        .await
        .map_err(|e| e.to_string())
}
