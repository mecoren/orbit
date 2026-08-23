//! full_sync_cmd — .orsync 全量备份导出/导入命令组（06 任务 3.4）
//!
//! 包装 orbit_core::api::full_sync_backup_api；sync_password 每次由前端显式携带
//! （api 层即用即毁：unlock → 编解码 → lock，不驻留）。
//! 文件选择对话框由前端 tauri-plugin-dialog 完成，壳层只收发字节/路径。

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use orbit_core::api::full_sync_backup_api::{self, ExportResult, ImportResult};
use orbit_core::context;

use crate::commands::data_dir::resolve_app_data_dir;
use crate::AppState;

/// 备份文件条目（本地 backups 目录列表项）
#[derive(Debug, Clone, Serialize)]
pub struct BackupEntryView {
    pub filename: String,
    pub file_path: String,
    pub modified_at: i64,
    pub size_bytes: i64,
}

/// 导出全量备份到本地 `{data_dir}/backups/{filename}`，可选上传云端副本
///
/// cloud_backup_enabled 偏好由 core 内 backup_prefs 控制；upload_cloud=true
/// 且存在激活云配置时才传 cloud_config。
#[tauri::command]
pub async fn full_backup_export(
    app: AppHandle,
    password: String,
    upload_cloud: bool,
) -> Result<ExportResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let dir = resolve_app_data_dir(&app)?;

    let cloud_config = if upload_cloud {
        Some(
            full_sync_backup_api::get_active_cloud_config_from_db(&pool)
                .await
                .map_err(|e| format!("[other] {e}"))?
                .ok_or_else(|| "[config] 尚未配置云同步，无法上传云端副本".to_string())?,
        )
    } else {
        None
    };

    full_sync_backup_api::export_full_sync_backup_with_cloud(&pool, &dir, &password, cloud_config)
        .await
        .map_err(|e| format!("[backup] 导出失败: {e}"))
}

/// 从 .waitfullsync 文件全量覆盖恢复
///
/// 警示语义：导入会清空当前业务表再写入备份内容（事务内原子完成）。
/// 成功后 emit("db-change") 触发前端全量刷新。
#[tauri::command]
pub async fn full_backup_import(
    app: AppHandle,
    path: String,
    password: String,
    ignore_schema_mismatch: bool,
) -> Result<ImportResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();

    let bytes = std::fs::read(&path).map_err(|e| format!("[backup] 读取文件失败: {e}"))?;

    let result = full_sync_backup_api::import_full_sync_backup(
        &pool,
        &password,
        &bytes,
        ignore_schema_mismatch,
    )
    .await
    .map_err(|e| format!("[backup] 导入失败: {e}"))?;

    // 全量覆盖后通知前端失效全部业务缓存（useDbInvalidation 监听 db-change）
    let _ = app.emit("db-change", serde_json::json!({ "table": "*", "kind": "import" }));
    Ok(result)
}

/// 列出本地 backups 目录的历史备份（按文件名倒序，最新在前）
#[tauri::command]
pub async fn full_backup_list_local(app: AppHandle) -> Result<Vec<BackupEntryView>, String> {
    let dir = resolve_app_data_dir(&app)?;
    let backup_dir = dir.join(orbit_core::full_sync_backup::backup_repository::DEFAULT_BACKUP_DIR_NAME);
    let entries = orbit_core::full_sync_backup::backup_repository::list_backups(&backup_dir)
        .map_err(|e| format!("[backup] {e}"))?;
    Ok(entries
        .into_iter()
        .map(|e| BackupEntryView {
            filename: e.filename,
            file_path: e.file_path.to_string_lossy().to_string(),
            modified_at: e.modified_at,
            size_bytes: e.file_size as i64,
        })
        .collect())
}

/// 当前设备信息（导出预览展示用）
#[derive(Serialize)]
pub struct DeviceInfo {
    pub device_id: String,
}

/// 读取设备 ID（未初始化返回空串）
#[tauri::command]
pub async fn full_backup_device_info() -> Result<DeviceInfo, String> {
    Ok(DeviceInfo {
        device_id: context::get_device_id().unwrap_or_default().to_string(),
    })
}
