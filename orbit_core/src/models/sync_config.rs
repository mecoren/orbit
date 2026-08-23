//! sync_config — 同步配置数据模型
//!
//! sync_configs 表的 Rust 侧持久化结构，取代 Drift 的 SyncConfigs 表定义。
//! 时间字段统一为 i64 毫秒时间戳（与 Rust 现有业务表一致）。

use serde::{Deserialize, Serialize};

/// sync_configs 表的完整记录（35 字段，含 region 列）
///
/// 对应 Dart 侧 SyncConfigData（UI 层 DTO），由 bridge 层做字段映射。
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SyncConfigRecord {
    pub id: i64,
    pub protocol: String,
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub path: String,
    pub device_id: String,
    pub credential: String,
    pub encryption_key_id: String,
    pub merge_strategy: String,
    pub sync_mode: String,
    pub max_update_age_hours: i64,
    pub is_encrypted: i64,
    pub is_active: i64,
    pub is_auto_sync: i64,
    pub sync_interval: i64,
    pub sync_on_change: i64,
    pub concurrent_reqs: i64,
    pub timeout: i64,
    pub skip_tls_verify: i64,
    pub last_synced_at: Option<i64>,
    pub last_gc_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i64,
    pub targets: String,
    pub local_path: Option<String>,
    pub schedule_type: String,
    pub schedule_time: Option<String>,
    pub schedule_weekday: Option<i64>,
    pub sync_scope: String,
    pub full_sync_interval: i64,
    pub history_keep_count: i64,
    pub notify_progress: i64,
}

/// 保存配置时的输入（id 为 None 表示新建）
///
/// 激活互斥逻辑由仓储层保证：保存激活配置时先取消其他配置的激活状态。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncConfigSaveInput {
    pub id: Option<i64>,
    pub protocol: String,
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub path: String,
    pub device_id: String,
    pub credential: String,
    pub encryption_key_id: String,
    pub merge_strategy: String,
    pub sync_mode: String,
    pub max_update_age_hours: i64,
    pub is_encrypted: i64,
    pub is_active: i64,
    pub is_auto_sync: i64,
    pub sync_interval: i64,
    pub sync_on_change: i64,
    pub concurrent_reqs: i64,
    pub timeout: i64,
    pub skip_tls_verify: i64,
    pub targets: String,
    pub local_path: Option<String>,
    pub schedule_type: String,
    pub schedule_time: Option<String>,
    pub schedule_weekday: Option<i64>,
    pub sync_scope: String,
    pub full_sync_interval: i64,
    pub history_keep_count: i64,
    pub notify_progress: i64,
}
