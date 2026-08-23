//! events — 数据库变更事件定义
//!
//! 跨端共享的响应式数据流载荷。Serde 序列化后：
//! - Tauri 端：序列化为 JSON 通过 emit("db-change", &event) 推送
//! - FRB 端：FRB 自动生成 Dart 对应类，StreamSink<DbEvent> 推送

use serde::{Deserialize, Serialize};

/// 数据库变更事件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbEvent {
    /// 表名（如 "rec_movies" / "rec_books"），前端据此失效对应查询
    pub table: String,
    /// 操作类型
    pub op: DbOp,
    /// 记录主键 ID
    pub record_id: i64,
    /// 记录 UUID（跨设备标识）
    pub record_uuid: String,
    /// 变更后的记录内容（Delete 时为 None）
    pub payload: Option<serde_json::Value>,
    /// 来源设备 ID
    pub device_id: String,
    /// 事件时间戳（毫秒）
    pub timestamp: i64,
}

/// 操作类型枚举
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum DbOp {
    Insert,
    Update,
    Delete,
    /// 同步导入触发的变更（前端可降级刷新频率）
    Sync,
}

impl DbEvent {
    /// 便捷构造：Insert 事件
    pub fn insert(
        table: &str,
        record_id: i64,
        record_uuid: &str,
        payload: serde_json::Value,
        device_id: &str,
    ) -> Self {
        Self {
            table: table.to_string(),
            op: DbOp::Insert,
            record_id,
            record_uuid: record_uuid.to_string(),
            payload: Some(payload),
            device_id: device_id.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// 便捷构造：Update 事件
    pub fn update(
        table: &str,
        record_id: i64,
        record_uuid: &str,
        payload: serde_json::Value,
        device_id: &str,
    ) -> Self {
        Self {
            table: table.to_string(),
            op: DbOp::Update,
            record_id,
            record_uuid: record_uuid.to_string(),
            payload: Some(payload),
            device_id: device_id.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// 便捷构造：Delete 事件（无 payload）
    pub fn delete(table: &str, record_id: i64, record_uuid: &str, device_id: &str) -> Self {
        Self {
            table: table.to_string(),
            op: DbOp::Delete,
            record_id,
            record_uuid: record_uuid.to_string(),
            payload: None,
            device_id: device_id.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
        }
    }
}
