//! context — 进程级全局上下文
//!
//! 持有当前设备 ID，供 generic_repo 在 create/update/delete 时
//! 填充 `DbEvent.device_id`（**只是事件来源元数据**，不再写入业务表列）。
//!
//! 注：v1 同步架构已移除 sync_queue 队列与业务表 `lamport_version` 列，
//! 改用全量同步直读业务表 + manifest 合并策略。因此「device_id 为空会跳过
//! Lamport 版本号写入」是历史遗留的**错误口径**：版本号由 SQL
//! `version = version + 1` 维护，与 device_id 无关；真正受空标识影响的是
//! cloud_sync/push.rs 的 `manifest.device_id`、`touch_device()` 检查点与
//! `verify_manifest_write()` 的 CAS 比对。
//!
//! 设计：`OnceCell` 一次性写入，进程生命周期内不可变。
//! Dart 侧在应用启动（数据库初始化 + 设备注册）后调用
//! `set_device_id` 写入全局值。

use once_cell::sync::OnceCell;

/// 当前设备 ID（进程级单例）
static DEVICE_ID: OnceCell<String> = OnceCell::new();

/// 写入当前设备 ID（仅可调用一次，重复调用返回错误）
pub fn set_device_id(id: String) -> Result<(), String> {
    DEVICE_ID
        .set(id)
        .map_err(|_| "device_id already set".to_string())
}

/// 读取当前设备 ID；未设置时返回 Err。
///
/// **分级口径**：`DbEvent` 事件来源、设备信息展示这类非写入用途可回落空串；
/// 任何会进 `cloud_sync_api` 的路径必须改用 [`require_device_id`]，绝不
/// 用 `unwrap_or_default()` 静默放行（`push_all_impl` 另有一道最终防线）。
pub fn get_device_id() -> Result<&'static str, String> {
    DEVICE_ID
        .get()
        .map(|s| s.as_str())
        .ok_or_else(|| "device_id not set".to_string())
}

/// 云端写入路径的 device_id：未初始化时返回带 `[config]` 的可操作错误。
///
/// 空标识会写进 `manifest.device_id` / `touch_device()` 的 DeviceCheckpoint，
/// 并让 `verify_manifest_write()` 的 CAS 比对退化成「所有未初始化设备共用
/// 同一个标识」。桥层与后台调度器必须在本机状态变更、云端写入之前调用。
pub fn require_device_id() -> Result<String, String> {
    get_device_id().map(str::to_string).map_err(|_| {
        "[config] 设备标识未初始化（启动期写入失败），请重启应用后再同步；\
         此状态下云端清单与设备检查点的标识会为空"
            .to_string()
    })
}

/// 生成系统设备名称（格式：`{OS 设备名}-{device_id 前 8 字符}`）
///
/// 同时保留人类可读性与跨设备唯一性，用于：
/// - 全量备份文件名（`backup_naming::generate_backup_filename_with_name` 优先使用）
/// - 备份 manifest 元数据（`BackupManifest.device_name`）
/// - .orsync 包 manifest（`source_device_name`）
///
/// **不参与**冲突检测、设备检查点、同步日志（这些只用 `device_id`）。
///
/// `device_id` 为空时仅返回 OS 设备名（兜底场景，理论上不会发生，
/// 因为调用前 `device_id` 已由 `load_or_create_device_id` 或 `sync_config_save` 生成）。
///
/// 示例：`MyLaptop-a3b2c1d9`、`android-abc12345-7f8e9d1a`、`iPhone-1b2c3d4e`
pub fn get_system_device_name(device_id: &str) -> String {
    let os_name = whoami::devicename();
    // 取 device_id 前 8 字符作为短哈希，保证跨设备唯一性
    // （OS 设备名可能重名，如多台默认名为 "DESKTOP-ABC123" 的 Windows）
    let short_id = if device_id.len() >= 8 {
        &device_id[..8]
    } else {
        device_id
    };
    if short_id.is_empty() {
        os_name
    } else {
        format!("{}-{}", os_name, short_id)
    }
}
