//! cfg_option — 选项表数据模型
//!
//! 配置类表（cfg_ 前缀），系统级全局共享，不参与增量同步。
//! 字段与 0003_cfg_options.sql 一一对应。

use serde::{Deserialize, Serialize};

// ========== 选项分组 ==========

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CfgOptionCategory {
    pub id: i64,
    pub category_key: String,
    pub label: String,
    pub description: String,
    pub is_active: i64,
    pub sort_order: i64,
    pub is_deleted: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
}

// ========== 选项项 ==========

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CfgOptionItem {
    pub id: i64,
    pub category_id: i64,
    pub value: String,
    pub label: String,
    pub sort_order: i64,
    pub is_default: i64,
    pub is_active: i64,
    pub color: String,
    pub is_deleted: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
}

// ========== 前端下拉框加载用精简 DTO ==========

/// 前端下拉框加载用精简 DTO
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct OptionItemDto {
    pub value: String,
    pub label: String,
    pub is_default: i64,
    pub color: String,
}
