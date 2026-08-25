//! models — 跨端共享数据模型（Serde structs）
//!
//! 字段名 snake_case；时间统一 i64 毫秒时间戳；JSON 数组字段存 String。

pub mod business;
pub mod cfg_option;
pub mod sync_config;
