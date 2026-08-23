//! 同步/备份/导入白名单注册表 —— 唯一权威来源（03 文档 §六）
//!
//! MVP 仅保留 todo 单模块：8 张 todo 业务表 + cfg_feature_modules。
//! 改动此文件时必须同步核对 `cloud_sync::modules` 的 SYNC_MODULES 定义与测试断言。
//! （本文件替代 wait-home 中散落在 business_api / db_loader / import_api 的各自为政的常量。）

/// 云同步白名单（push 时逐条附 `_table` 路由标记；与 FULL_BACKUP_TABLES 保持一致）
pub const SYNCABLE_TABLES: &[&str] = &[
    "todo_projects",
    "todo_tasks",
    "todo_subtasks",
    "todo_labels",
    "todo_task_labels",
    "todo_comments",
    "todo_task_relations",
    "todo_reminders",
    "cfg_feature_modules",
];

/// 全量备份包（.orsync）遍历导出的业务表白名单
pub const FULL_BACKUP_TABLES: &[&str] = SYNCABLE_TABLES;

/// 备份导入白名单 —— 已补齐 wait-home 版缺口（B 类小改）：
/// projects/subtasks/labels/comments/reminders 五张表在原版中导不进，现与备份对齐
pub const IMPORTABLE_TABLES: &[&str] = SYNCABLE_TABLES;
