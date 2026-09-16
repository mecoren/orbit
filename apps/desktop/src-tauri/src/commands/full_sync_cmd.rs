//! full_sync_cmd — .orfullsync 全量备份导出/导入/云端列举命令组（06 任务 3.4）
//!
//! 包装 orbit_core::api::full_sync_backup_api。密码不再由前端显式携带：
//! 全量备份复用 `SyncCryptoService` 已解锁态缓存（配合同步密码解锁后调用）。
//! 文件选择对话框由前端 tauri-plugin-dialog 完成，壳层只收发字节/路径。

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use orbit_core::api::full_sync_backup_api::{self, ExportResult, ImportResult};
use orbit_core::context;

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;
use crate::commands::sync_runtime;

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
/// 手动导出走 [`full_sync_backup_api::export_full_sync_backup`]（origin=Manual），
/// 不受定时自动备份的偏好开关（local/cloud_backup_enabled）约束；
/// upload_cloud=true 且存在激活云配置时才传 cloud_config。
/// 密码复用已解锁态缓存，前端须先完成同步密码解锁。
#[tauri::command]
pub async fn full_backup_export(
    app: AppHandle,
    upload_cloud: bool,
) -> Result<ExportResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let dir = resolve_app_data_dir(&app)?;
    // 复用进程级已解锁的 SyncCryptoService（含缓存的同步密码）
    let svc = sync_runtime::sync_crypto(&app)?;

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

    full_sync_backup_api::export_full_sync_backup(
        &pool,
        &dir,
        &svc,
        full_sync_backup_api::BackupOrigin::Manual,
        cloud_config,
        upload_cloud,
    )
    .await
    .map_err(|e| format!("[backup] 导出失败: {e}"))
}

/// 从 `.orfullsync` 文件全量覆盖恢复（兼容遗留 `.waitfullsync` / `.orsync`）
///
/// 警示语义：导入会清空当前业务表再写入备份内容（事务内原子完成）。
/// 成功后 emit("db-change") 触发前端全量刷新。
/// 密码复用已解锁态缓存，前端须先完成同步密码解锁。
#[tauri::command]
pub async fn full_backup_import(
    app: AppHandle,
    path: String,
    ignore_schema_mismatch: bool,
) -> Result<ImportResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let svc = sync_runtime::sync_crypto(&app)?;

    let bytes = std::fs::read(&path).map_err(|e| format!("[backup] 读取文件失败: {e}"))?;

    let result = full_sync_backup_api::import_full_sync_backup(&pool, &svc, &bytes, ignore_schema_mismatch)
        .await
        .map_err(|e| format!("[backup] 导入失败: {e}"))?;

    // 全量覆盖后通知前端失效全部业务缓存（useDbInvalidation 监听 db-change）
    let _ = app.emit(
        "db-change",
        serde_json::json!({ "table": "*", "kind": "import" }),
    );
    Ok(result)
}

/// 云端备份文件条目（备份恢复选源列表）
#[derive(Debug, Clone, Serialize)]
pub struct CloudBackupEntryView {
    pub name: String,
    pub cloud_path: String,
    pub size_bytes: u64,
    pub modified_at: i64,
}

/// 列出当前激活云空间 `backups/` 目录下的历史备份副本（最新在前）
#[tauri::command]
pub async fn full_backup_list_cloud(app: AppHandle) -> Result<Vec<CloudBackupEntryView>, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();

    let config = full_sync_backup_api::get_active_cloud_config_from_db(&pool)
        .await
        .map_err(|e| format!("[other] {e}"))?
        .ok_or_else(|| "[config] 尚未配置云同步，无法列出云端备份".to_string())?;

    let adapter = orbit_core::sync::engine::create_adapter(&config)
        .map_err(|e| format!("[backup] 创建云适配器失败: {e}"))?;
    let files = full_sync_backup_api::list_cloud_backups(&*adapter, &config.base_path)
        .await
        .map_err(|e| format!("[backup] 列出云端备份失败: {e}"))?;

    Ok(files
        .into_iter()
        .map(|f| {
            let cloud_path = format!(
                "{}/backups/{}",
                config.base_path.trim_end_matches('/'),
                f.name
            );
            CloudBackupEntryView {
                name: f.name,
                cloud_path,
                size_bytes: f.size,
                modified_at: f.last_modified,
            }
        })
        .collect())
}

/// 从云端备份副本全量覆盖恢复（先下载字节，再走与本地一致的导入路径）
///
/// `cloud_path` 为 list_cloud_backups 返回的完整云端对象路径。
/// 密码复用已解锁态缓存；成功后 emit("db-change") 触发前端全量刷新。
#[tauri::command]
pub async fn full_backup_restore_cloud(
    app: AppHandle,
    cloud_path: String,
    ignore_schema_mismatch: bool,
) -> Result<ImportResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let svc = sync_runtime::sync_crypto(&app)?;

    let config = full_sync_backup_api::get_active_cloud_config_from_db(&pool)
        .await
        .map_err(|e| format!("[other] {e}"))?
        .ok_or_else(|| "[config] 尚未配置云同步，无法读取云端备份".to_string())?;

    let adapter = orbit_core::sync::engine::create_adapter(&config)
        .map_err(|e| format!("[backup] 创建云适配器失败: {e}"))?;
    let bytes = full_sync_backup_api::download_cloud_backup(&*adapter, &cloud_path)
        .await
        .map_err(|e| format!("[backup] 下载云端备份失败: {e}"))?;

    let result = full_sync_backup_api::import_full_sync_backup(&pool, &svc, &bytes, ignore_schema_mismatch)
        .await
        .map_err(|e| format!("[backup] 导入失败: {e}"))?;

    let _ = app.emit(
        "db-change",
        serde_json::json!({ "table": "*", "kind": "import" }),
    );
    Ok(result)
}

/// 列出本地 backups 目录的历史备份（按文件名倒序，最新在前）
#[tauri::command]
pub async fn full_backup_list_local(app: AppHandle) -> Result<Vec<BackupEntryView>, String> {
    let dir = resolve_app_data_dir(&app)?;
    let backup_dir =
        dir.join(orbit_core::full_sync_backup::backup_repository::DEFAULT_BACKUP_DIR_NAME);
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
