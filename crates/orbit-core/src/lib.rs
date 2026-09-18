//! orbit_core —— Orbit（循迹）业务逻辑核心
//!
//! 零 FFI 依赖：不依赖 tauri。由 src-tauri 薄壳包装为 #[tauri::command]。
//! 资产平移自 wait-home wait_core（02 文档 §四），按 MVP 范围裁剪：
//! 剔除 douban / excel / password / changelog / sync(v1 引擎) / movie / asset 等模块。
//!
//! 模块分层：
//! - 统一错误/上下文：error / context
//! - 基础能力域：crypto / config_enc / webdav / s3 / fs_util
//! - 同步域：sync_adapters / sync_crypto / cloud_sync / full_sync_backup
//! - 数据访问域：db / models
//! - 业务编排层：api

// 统一错误与全局上下文（device_id 供 generic_repo 自动入队）
pub mod context;
pub mod error;

// 基础能力域
pub mod config_enc;
pub mod crypto;
pub mod fs_util;
pub mod s3;
pub mod webdav;

// 同步域（适配器构造/配置校验 + 云同步管线 + 密钥派生 + 全量备份）
pub mod cloud_sync;
pub mod full_sync_backup;
pub mod sync;
pub mod sync_adapters;
pub mod sync_crypto;

// 横切关注点
pub mod eventbus;

// 数据访问域
pub mod db;
pub mod models;

// 业务编排层
pub mod api;
