//! business — Orbit 业务表数据模型（MVP 所需段落）
//!
//! 平移自 wait-home wait_core models/business.rs（02 文档 §四 A 类），仅保留：
//! FlexibleI64 / ListFilter / todo 8 表全部 struct。
//! 字段与 0001_init.sql 一一对应；DateTime 统一 i64 毫秒时间戳；可空字段 Option<T>。

use serde::{Deserialize, Serialize};
use sqlx::Type;
use sqlx::TypeInfo;
use sqlx::ValueRef;
use sqlx::decode::Decode;
use sqlx::sqlite::{Sqlite, SqliteTypeInfo, SqliteValueRef};

/// 兼容 INTEGER 与「数字文本」(TEXT) 的整型包装。
///
/// 背景：rec_devices 等表历史上部分数值列（acquired_at 等）
/// 被以 TEXT 形式写入，而 Rust 模型声明为 INTEGER，SQLx 在 `SELECT *` 反序列化时
/// 会因「Rust i64 与 SQL TEXT 不兼容」直接报错，导致整张表列表/详情查询失败。
///
/// 该类型在 Decode 阶段同时接受 INTEGER 与数字 TEXT（空串/非数字则视为 None），
/// Serde 透明序列化为 `Option<i64>`，对前端无感知、无需改动数据库 schema。
#[derive(Debug, Clone, Copy, Default)]
pub struct FlexibleI64(pub Option<i64>);

impl<'r> Decode<'r, Sqlite> for FlexibleI64 {
    fn decode(value: SqliteValueRef<'r>) -> Result<Self, sqlx::error::BoxDynError> {
        if value.is_null() {
            return Ok(FlexibleI64(None));
        }
        match value.type_info().name() {
            "INTEGER" => {
                let v = <i64 as Decode<Sqlite>>::decode(value)?;
                Ok(FlexibleI64(Some(v)))
            }
            "TEXT" | "REAL" => {
                let s = <String as Decode<Sqlite>>::decode(value)?;
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    Ok(FlexibleI64(None))
                } else {
                    Ok(FlexibleI64(trimmed.parse::<i64>().ok()))
                }
            }
            _ => Ok(FlexibleI64(None)),
        }
    }
}

impl Serialize for FlexibleI64 {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Some(v) => serializer.serialize_some(&v),
            None => serializer.serialize_none(),
        }
    }
}

impl Type<Sqlite> for FlexibleI64 {
    fn type_info() -> SqliteTypeInfo {
        <i64 as Type<Sqlite>>::type_info()
    }
}

impl<'de> Deserialize<'de> for FlexibleI64 {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let opt = Option::<i64>::deserialize(deserializer)?;
        Ok(FlexibleI64(opt))
    }
}

// ========== 通用过滤条件 ==========

/// 通用列表过滤条件（所有业务表共用）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListFilter {
    pub keyword: Option<String>,
    pub page: u32,
    pub page_size: u32,
}

// ---------- todo_projects ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_projects 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoProjectCreateInput {
    pub title: String,
    pub description: Option<String>,
    pub hex_color: Option<String>,
    pub sort_order: Option<f64>,
}

/// todo_projects 更新输入（Option<Option<T>> 模式）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoProjectUpdateInput {
    pub title: Option<String>,
    pub description: Option<Option<String>>,
    pub hex_color: Option<String>,
    pub sort_order: Option<f64>,
}

// ---------- todo_tasks ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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
    /// 重复规则扩展（#34）：星期几位掩码（bit0=周一…bit6=周日；仅 WEEKLY 生效）
    pub repeat_weekdays: i32,
    /// 结束条件 0=永不 1=按日期 2=按次数
    pub repeat_end_type: i32,
    /// 结束参数：日期型=结束日 ms / 次数型=剩余次数
    pub repeat_end_param: i64,
    /// when done 语义：0=锚定原 due 推进 1=按完成日推进
    pub repeat_from_done: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    /// My Day「我的一天」：加入当天本地零点 ms；NULL = 不在任何一天的 My Day
    /// （07 报告新增项，对标微软 To Do；次日自动清空为视图侧按日判断，不改数据）
    pub my_day_date: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_tasks 创建输入
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
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
    #[serde(default)]
    pub repeat_weekdays: Option<i32>,
    #[serde(default)]
    pub repeat_end_type: Option<i32>,
    #[serde(default)]
    pub repeat_end_param: Option<i64>,
    #[serde(default)]
    pub repeat_from_done: Option<i32>,
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    pub my_day_date: Option<i64>,
}

/// 反序列化 `Option<Option<T>>` 的可空字段。
///
/// 约定：
/// - 字段**缺失** → `None`（表示「不更新该列」）
/// - 字段**存在且为 null** → `Some(None)`（表示「将该列清空为 NULL」）
/// - 字段**存在且有值** → `Some(Some(v))`（表示「更新为 v」）
///
/// 标准 serde 对 `Option<Option<T>>` 反序列化 JSON `null` 会得到 `None`（外层 Option 短路），
/// 导致前端传 `project_id: null` 等「清空」意图被误判为「不更新」。此函数修正该行为。
mod nullable {
    use serde::de::{self, Visitor};
    use serde::{Deserialize, Deserializer};
    use std::fmt;
    use std::marker::PhantomData;

    pub fn deserialize<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
    where
        D: Deserializer<'de>,
        T: Deserialize<'de>,
    {
        struct OptOptVisitor<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for OptOptVisitor<T> {
            type Value = Option<Option<T>>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("optional value (null clears)")
            }
            fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Some(None))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Some(None))
            }
            fn visit_some<D2>(self, d: D2) -> Result<Self::Value, D2::Error>
            where
                D2: Deserializer<'de>,
            {
                Ok(Some(Some(T::deserialize(d)?)))
            }
        }
        deserializer.deserialize_option(OptOptVisitor(PhantomData))
    }
}

/// todo_tasks 更新输入（Option<Option<T>> 模式）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskUpdateInput {
    pub title: Option<String>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub description: Option<Option<String>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub project_id: Option<Option<i64>>,
    pub priority: Option<i32>,
    pub status: Option<String>,
    pub done: Option<i32>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub done_at: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub due_date: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub start_date: Option<Option<i64>>,
    pub repeat_after: Option<i64>,
    pub repeat_mode: Option<i32>,
    #[serde(default)]
    pub repeat_weekdays: Option<i32>,
    #[serde(default)]
    pub repeat_end_type: Option<i32>,
    #[serde(default)]
    pub repeat_end_param: Option<i64>,
    #[serde(default)]
    pub repeat_from_done: Option<i32>,
    pub percent_done: Option<f64>,
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub my_day_date: Option<Option<i64>>,
}

// ---------- todo_subtasks ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_subtasks 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSubtaskCreateInput {
    pub task_id: i64,
    pub title: String,
    pub position: Option<f64>,
}

/// todo_subtasks 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSubtaskUpdateInput {
    pub title: Option<String>,
    pub done: Option<i32>,
    pub done_at: Option<Option<i64>>,
    pub position: Option<f64>,
}

// ---------- todo_labels ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_labels 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoLabelCreateInput {
    pub title: String,
    pub hex_color: Option<String>,
}

/// todo_labels 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoLabelUpdateInput {
    pub title: Option<String>,
    pub hex_color: Option<String>,
}

// ---------- todo_task_labels ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_task_labels 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskLabelCreateInput {
    pub task_id: i64,
    pub label_id: i64,
}

// ---------- todo_comments ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_comments 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoCommentCreateInput {
    pub task_id: i64,
    pub content: String,
}

// ---------- todo_task_relations ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_task_relations 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskRelationCreateInput {
    pub task_id: i64,
    pub other_task_id: i64,
    pub relation_type: String,
}

// ---------- todo_reminders ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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

/// todo_reminders 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoReminderCreateInput {
    pub task_id: i64,
    pub remind_at: i64,
}

// ---------- todo_task_attachments（任务-附件关联，引用 sys_attachments.hash）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTaskAttachment {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub hash: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

// ---------- todo_saved_filters（保存的筛选器，#35）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoSavedFilter {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    /// 条件 JSON：{status?, priority_min?, project_ids?, label_ids?,
    /// due_within_days?, due_overdue?, favorite_only?}——缺键 = 不过滤
    pub conditions: String,
    pub sort_order: i64,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_saved_filters 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSavedFilterCreateInput {
    pub name: String,
    pub conditions: String,
    pub sort_order: Option<i64>,
}

/// todo_saved_filters 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSavedFilterUpdateInput {
    pub name: Option<String>,
    pub conditions: Option<String>,
    pub sort_order: Option<i64>,
}

// ---------- sys_attachments（PK: hash）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Attachment {
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub local_path: Option<String>,
    pub is_uploaded: i32,
    pub is_local_cached: i32,
    /// 创建时间（ms 时间戳；迁移 0001 原为 TEXT 属笔误，随附件功能落地对齐 i64）
    pub created_at: i64,
}

// ---------- sync_history ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SyncHistory {
    pub id: i64,
    pub sync_type: String,
    pub status: String,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub pulled_count: i64,
    pub pushed_count: i64,
    pub conflict_count: i64,
    pub error_message: Option<String>,
}
