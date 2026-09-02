//! full_sync_backup_api — 全量同步备份业务编排层
//!
//! 桥接 `full_sync_backup` 核心模块与 `business_api` / `sync_crypto` 服务，
//! 提供 Tauri / FRB 可直接调用的 async API。
//!
//! 主要功能：
//! - `export_full_sync_backup`：导出全量备份到本地文件
//! - `import_full_sync_backup`：从 .waitfullsync 文件全量覆盖恢复
//! - `peek_full_sync_manifest`：读取备份清单（不解密整个 ZIP）
//! - `list_backups` / `delete_backup` / `keep_latest_backup`：备份文件管理
//! - `get_backup_prefs` / `save_backup_prefs`：偏好设置
//! - `calculate_next_backup_at`：调度时间计算（v4）

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::api::business_api;
use crate::context;
use crate::db::repository::import_type_validator::{
    ColumnMeta, load_table_columns_in_tx, normalize_fields_with_columns,
};
use crate::db::repository::sync_config_repo::SyncConfigRepo;
use crate::full_sync_backup::backup_naming::generate_backup_filename_with_name;
use crate::full_sync_backup::backup_prefs::BackupPrefs;
use crate::full_sync_backup::backup_repository::{
    BackupEntry, delete_backup as repo_delete_backup, keep_latest_backup as repo_keep_latest,
    list_backups as repo_list_backups, resolve_backup_dir,
};
use crate::full_sync_backup::decoder::decode_backup;
use crate::full_sync_backup::encoder::{EncodeParams, encode_backup};
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};
use crate::full_sync_backup::manifest::BackupManifest;
use crate::full_sync_backup::scheduler::calculate_next_backup_at;
use crate::full_sync_backup::{load_prefs, save_prefs};
use crate::models::sync_config::SyncConfigRecord;
use crate::sync::engine::{self, SyncConfig as EngineSyncConfig};
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter};
use crate::sync_crypto::SyncCryptoService;

/// 导出结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportResult {
    pub file_path: String,
    pub file_size: u64,
    pub table_counts: BTreeMap<String, usize>,
    pub manifest: BackupManifest,
    /// 云端备份路径（仅上传成功时有值）
    pub cloud_path: Option<String>,
    /// 是否成功上传到云端
    pub cloud_uploaded: bool,
    /// 云端上传错误信息（上传失败时有值，不阻塞本地备份）
    pub cloud_error: Option<String>,
    /// 本地备份文件路径（写入成功时有值）
    #[serde(default)]
    pub local_path: Option<String>,
    /// 本地写入错误信息（写入失败时有值）
    #[serde(default)]
    pub local_error: Option<String>,
}

/// 导入结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    pub success_count: i64,
    pub error_count: i64,
    pub errors: Vec<String>,
    pub manifest: BackupManifest,
    pub needs_restart: bool,
}

/// schema 版本号（来自 schema_migrations 表）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaVersion {
    pub version: i64,
}

/// 导出全量同步备份到本地文件（不触发云端上传）
///
/// 两阶段开关取自备份偏好（`local_backup_enabled` / `cloud_backup_enabled`，
/// 均关时返回错误）。供同步前自动备份等"偏好驱动"场景使用；
/// 如需同时上传到云端，请使用 [`export_full_sync_backup_with_cloud`]。
pub async fn export_full_sync_backup(
    pool: &SqlitePool,
    app_data_dir: &Path,
    sync_password: &str,
) -> FullSyncBackupResult<ExportResult> {
    let prefs = load_prefs(app_data_dir)?;
    ensure_any_switch_enabled(&prefs)?;
    export_full_sync_backup_inner(
        pool,
        app_data_dir,
        sync_password,
        None,
        prefs.local_backup_enabled,
        prefs.cloud_backup_enabled,
    )
    .await
}

/// 导出全量同步备份到本地文件，并可选上传到云端
///
/// 与 [`export_full_sync_backup`] 相同的偏好开关门控；差异仅在可携带云端配置
/// （仍受 `cloud_backup_enabled` 门控）。供定时自动备份守护使用。
pub async fn export_full_sync_backup_with_cloud(
    pool: &SqlitePool,
    app_data_dir: &Path,
    sync_password: &str,
    cloud_config: Option<EngineSyncConfig>,
) -> FullSyncBackupResult<ExportResult> {
    let prefs = load_prefs(app_data_dir)?;
    ensure_any_switch_enabled(&prefs)?;
    export_full_sync_backup_inner(
        pool,
        app_data_dir,
        sync_password,
        cloud_config,
        prefs.local_backup_enabled,
        prefs.cloud_backup_enabled,
    )
    .await
}

/// 手动导出全量备份（不受备份偏好开关约束）
///
/// 用户在 UI 显式点击导出时调用：
/// - 始终尝试写入本地 backups 目录
/// - `upload_cloud=true` 且提供 `cloud_config` 时额外上传云端副本
///
/// `local_path` / `keep_latest` 等目录偏好仍然生效。
pub async fn export_full_sync_backup_manual(
    pool: &SqlitePool,
    app_data_dir: &Path,
    sync_password: &str,
    cloud_config: Option<EngineSyncConfig>,
    upload_cloud: bool,
) -> FullSyncBackupResult<ExportResult> {
    export_full_sync_backup_inner(
        pool,
        app_data_dir,
        sync_password,
        cloud_config,
        true,
        upload_cloud,
    )
    .await
}

/// 偏好驱动导出的前置校验：云端与本地开关均为关闭时拒绝执行
fn ensure_any_switch_enabled(prefs: &BackupPrefs) -> FullSyncBackupResult<()> {
    if !prefs.cloud_backup_enabled && !prefs.local_backup_enabled {
        return Err(FullSyncBackupError::InvalidState(
            "云端备份与本地备份开关均为关闭，请至少开启一项后再执行备份".to_string(),
        ));
    }
    Ok(())
}

/// 导出公共实现
///
/// v6 重构流程（云端 → 本地 两阶段，分别记录 sync_history）：
/// 1. 用 SyncCryptoService::unlock 校验同步密码（失败立即返回）
/// 2. 立即 lock，不持久化解锁状态
/// 3. 读取 device_id / device_name（device_name 来自 sync_config.json）
/// 4. 遍历 FULL_BACKUP_TABLES 读取业务表数据
/// 5. 查 schema_migrations 当前版本
/// 6. 构造 manifest（填充 device_name）+ encode_backup（单次编码）
/// 7. 生成文件名（device_name 优先，device_id 回退）
/// 8. 【云端阶段】`cloud_enabled` 且提供 cloud_config 时上传字节到云端
///    - 记录 sync_history(sync_type="cloud_full_backup", status=success/failed)
///    - 失败不中断，继续执行本地阶段
/// 9. 【本地阶段】`local_enabled` 时写入 `{backup_dir}/{filename}`（自动覆盖）
///    - 记录 sync_history(sync_type="local_full_backup", status=success/failed)
///    - 若 keep_latest=true，扫描删除其他备份
///
/// 云端上传失败不会阻塞本地备份，错误信息会写入 `ExportResult.cloud_error`。
#[allow(clippy::too_many_arguments)]
async fn export_full_sync_backup_inner(
    pool: &SqlitePool,
    app_data_dir: &Path,
    sync_password: &str,
    cloud_config_in: Option<EngineSyncConfig>,
    local_enabled: bool,
    cloud_enabled: bool,
) -> FullSyncBackupResult<ExportResult> {
    // 1. 校验同步密码
    let svc = SyncCryptoService::new(app_data_dir);
    svc.unlock(sync_password)?;
    svc.lock();

    // 2. 读取 device_id / device_name
    let device_id = context::get_device_id().unwrap_or_default().to_string();
    let device_name = read_device_name_from_config(app_data_dir);

    // 3. 遍历业务表，读取 JSON 数据
    let mut table_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut table_data: BTreeMap<String, String> = BTreeMap::new();

    for table in business_api::FULL_BACKUP_TABLES {
        match business_api::list_records_as_json(pool, table).await {
            Ok(json_str) => {
                let count = serde_json::from_str::<Vec<serde_json::Value>>(&json_str)
                    .map(|v| v.len())
                    .unwrap_or(0);
                table_counts.insert(table.to_string(), count);
                table_data.insert(table.to_string(), json_str);
            }
            Err(e) => {
                // 表不存在或其他查询错误：跳过此表，不加入 manifest
                // 这样 import 阶段不会尝试 DELETE 不存在的表
                eprintln!("[export_full_sync_backup] table {} skipped: {}", table, e);
            }
        }
    }

    // 4. 查 schema_migrations 当前版本
    let schema_version = query_schema_version(pool).await?;

    // 5. 构造 manifest（v6: 填充 device_name，原 None 字段修复）
    let now_ts = Utc::now().timestamp();
    let app_version = env!("CARGO_PKG_VERSION").to_string();
    let manifest = BackupManifest::new(
        device_id.clone(),
        Some(device_name.clone()),
        schema_version,
        table_counts.clone(),
        now_ts,
        app_version,
    );

    // 6. 编码（ZIP + AES-GCM + 容器封装，单次编码供云端+本地共用）
    let schema_version_json = serde_json::to_string(&SchemaVersion {
        version: schema_version,
    })?;
    let encoded = encode_backup(EncodeParams {
        sync_password,
        manifest: &manifest,
        table_data: &table_data,
        schema_version_json: &schema_version_json,
    })?;

    // 7. 解析备份目录 + 生成文件名
    let prefs = load_prefs(app_data_dir)?;

    let backup_dir = resolve_backup_dir(app_data_dir, prefs.local_path.as_deref());
    // 仅在启用本地备份时创建目录，避免残留空目录
    if local_enabled {
        std::fs::create_dir_all(&backup_dir)?;
    }
    let filename = generate_backup_filename_with_name(&device_name, &device_id, Utc::now());

    // ===== 8. 云端阶段 =====
    // 根据开关屏蔽 cloud_config：关闭云端备份时视为无云端配置
    let cloud_config = if cloud_enabled { cloud_config_in } else { None };

    // 提前记录是否有云端配置（cloud_config 在 if let Some(config) 中会被部分 move，
    // 后续无法再调用 cloud_config.is_some()，故用独立布尔变量记录）
    let has_cloud_config = cloud_config.is_some();
    let mut cloud_path: Option<String> = None;
    let mut cloud_uploaded = false;
    let mut cloud_error: Option<String> = None;
    if let Some(config) = cloud_config {
        match engine::create_adapter(&config) {
            Ok(adapter) => {
                match upload_backup_bytes(&*adapter, &config.base_path, &encoded.bytes, &filename)
                    .await
                {
                    Ok(path) => {
                        cloud_path = Some(path);
                        cloud_uploaded = true;
                    }
                    Err(e) => {
                        cloud_error = Some(e.to_string());
                    }
                }
            }
            Err(e) => {
                cloud_error = Some(format!("创建云端适配器失败: {}", e));
            }
        }
    }
    // 记录云端阶段历史（无 cloud_config 时跳过云端阶段，不写历史）
    if has_cloud_config {
        let cloud_status = if cloud_uploaded { "success" } else { "failed" };
        let _ = insert_sync_history(
            pool,
            "cloud_full_backup",
            cloud_status,
            now_ts,
            0,
            0,
            0,
            cloud_error.as_deref(),
        )
        .await;
    }

    // ===== 9. 本地阶段（受 local_enabled 开关控制）=====
    // 关闭本地备份时跳过文件写入与历史记录，仅保留云端阶段结果
    let target_path = backup_dir.join(&filename);
    let mut local_path: Option<String> = None;
    let mut local_error: Option<String> = None;
    if local_enabled {
        match std::fs::write(&target_path, &encoded.bytes) {
            Ok(()) => {
                local_path = Some(target_path.to_string_lossy().to_string());
                if prefs.keep_latest {
                    let _ = repo_keep_latest(&backup_dir, &target_path);
                }
            }
            Err(e) => {
                local_error = Some(e.to_string());
            }
        }
        let local_status = if local_error.is_none() {
            "success"
        } else {
            "failed"
        };
        let _ = insert_sync_history(
            pool,
            "local_full_backup",
            local_status,
            now_ts,
            0,
            0,
            0,
            local_error.as_deref(),
        )
        .await;
    }
    // 本地备份关闭时：跳过文件写入与历史记录，backup_dir 留空亦无副作用

    let file_size = encoded.bytes.len() as u64;
    Ok(ExportResult {
        file_path: local_path.clone().unwrap_or_default(),
        file_size,
        table_counts,
        manifest,
        cloud_path,
        cloud_uploaded,
        cloud_error,
        local_path,
        local_error,
    })
}

/// 将数据库中的同步配置记录转换为同步引擎配置
///
/// - `protocol` 为 `local` 时返回 `None`（本地同步不上传云端）
/// - 移动端：`device_id` 字段复用为 access_key，`credential` 复用为 secret_key
/// - `region` 直接取自 DB 记录；`device_name` 使用 device_id 兜底
pub fn engine_config_from_record(record: &SyncConfigRecord) -> Option<EngineSyncConfig> {
    let adapter_type = record.protocol.to_lowercase();
    if adapter_type == "local" {
        return None;
    }
    let device_id = context::get_device_id().unwrap_or_default().to_string();
    Some(EngineSyncConfig {
        adapter_type,
        endpoint: record.endpoint.clone(),
        bucket: record.bucket.clone(),
        region: record.region.clone(),
        access_key: record.device_id.clone(),
        secret_key: record.credential.clone(),
        base_path: record.path.clone(),
        device_id: device_id.clone(),
        device_name: device_id,
        timeout_secs: record.timeout.max(0) as u64,
        skip_tls_verify: record.skip_tls_verify != 0,
    })
}

/// 从数据库读取激活同步配置，并转换为云端备份所需的引擎配置
///
/// 未配置或仅配置本地同步时返回 `None`。
pub async fn get_active_cloud_config_from_db(
    pool: &SqlitePool,
) -> FullSyncBackupResult<Option<EngineSyncConfig>> {
    let repo = SyncConfigRepo::new(pool.clone());
    let record = repo
        .get_active_config()
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("读取同步配置失败: {}", e)))?;
    Ok(record.as_ref().and_then(engine_config_from_record))
}

/// 将备份字节直接上传到云端
///
/// 云端路径为 `{base_path}/backups/{filename}`，与同步包 `{base_path}/*.waitsync` 区分存放。
/// 上传失败返回错误，不阻塞本地备份已成功的事实。
///
/// 供 `export_full_sync_backup_with_cloud` 在「云端 → 本地」两阶段流程中复用编码字节，
/// 避免先写本地文件再读取的开销。
pub async fn upload_backup_bytes(
    adapter: &dyn SyncAdapter,
    base_path: &str,
    bytes: &[u8],
    filename: &str,
) -> FullSyncBackupResult<String> {
    let cloud_path = format!("{}/backups/{}", base_path.trim_end_matches('/'), filename);
    adapter
        .upload(&cloud_path, bytes)
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("云端上传失败: {}", e)))?;
    Ok(cloud_path)
}

/// v7: 列出云端备份目录下所有 .waitfullsync 文件
///
/// 云端路径为 `{base_path}/backups/`，与同步包 `{base_path}/*.waitsync` 区分存放。
/// 仅返回文件名以 `.waitfullsync` 结尾的条目，按最后修改时间倒序排列。
/// RemoteFile 的 name 字段为相对 `{base_path}/backups/` 的文件名。
pub async fn list_cloud_backups(
    adapter: &dyn SyncAdapter,
    base_path: &str,
) -> FullSyncBackupResult<Vec<RemoteFile>> {
    let cloud_dir = format!("{}/backups", base_path.trim_end_matches('/'));
    // v7: 必须使用 list_all_files，list_files 会过滤掉 .waitfullsync 后缀
    let mut files = adapter
        .list_all_files(&cloud_dir)
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("列出云端备份失败: {}", e)))?;
    // 仅保留 .waitfullsync 文件
    files.retain(|f| f.name.ends_with(".waitfullsync"));
    // 按最后修改时间倒序（最新在前）
    files.sort_by_key(|f| std::cmp::Reverse(f.last_modified));
    Ok(files)
}

/// v7: 从云端下载指定备份文件
///
/// `cloud_path` 为云端绝对路径（来自 list_cloud_backups 返回的 RemoteFile.path）。
/// 返回文件字节内容，供 peek_manifest / import 使用。
pub async fn download_cloud_backup(
    adapter: &dyn SyncAdapter,
    cloud_path: &str,
) -> FullSyncBackupResult<Vec<u8>> {
    adapter
        .download(cloud_path)
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("下载云端备份失败: {}", e)))
}

/// 从 `sync_config.json` 读取 device_name（仅供备份文件名联动使用）
///
/// 桌面端 sync_config 由 `desktop/src-tauri/src/commands/sync_cmd.rs::SyncConfigData` 管理，
/// 本函数以松耦合方式读取（仅取 device_name 字段），避免 rust_core 反向依赖 desktop 代码。
/// 文件不存在或字段缺失时返回空串（由调用方回退到 device_id）。
///
/// 加密优先：若全局 `EncryptedConfigStorage` 已注册，从 `sync_config.enc` 读取；
/// 否则降级到明文 `sync_config.json`。
fn read_device_name_from_config(app_data_dir: &Path) -> String {
    // 加密存储优先
    if let Some(storage) = crate::config_enc::get_global_storage()
        && let Ok(Some(cfg)) = storage.load::<serde_json::Value>("sync_config")
        && let Some(name) = cfg.get("device_name").and_then(|v| v.as_str())
    {
        return name.to_string();
    }
    // 降级：明文 sync_config.json
    let path = app_data_dir.join("sync_config.json");
    if let Ok(content) = std::fs::read_to_string(&path)
        && let Ok(cfg) = serde_json::from_str::<serde_json::Value>(&content)
        && let Some(name) = cfg.get("device_name").and_then(|v| v.as_str())
    {
        return name.to_string();
    }
    String::new()
}

/// 内部便捷函数：插入一条同步历史并立即更新状态
///
/// 供 `export_full_sync_backup_with_cloud` 在云端阶段和本地阶段分别调用，
/// 记录 `cloud_full_backup` / `local_full_backup` 两条历史。
#[allow(clippy::too_many_arguments)] // 与 sync_history_repo::update_status 同列集
async fn insert_sync_history(
    pool: &SqlitePool,
    sync_type: &str,
    status: &str,
    ts: i64,
    pulled: i64,
    pushed: i64,
    conflict: i64,
    error: Option<&str>,
) -> FullSyncBackupResult<()> {
    use crate::db::repository::sync_history_repo;
    let id = sync_history_repo::insert(pool, sync_type, status, ts)
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("写入同步历史失败: {}", e)))?;
    sync_history_repo::update_status(pool, id, status, ts, pulled, pushed, conflict, error)
        .await
        .map_err(|e| FullSyncBackupError::Other(format!("更新同步历史失败: {}", e)))?;
    Ok(())
}

/// 从 .waitfullsync 文件全量覆盖恢复
///
/// 流程：
/// 1. 读取文件字节
/// 2. decode_backup 解密 + 解压（密码错误立即返回）
/// 3. 校验 manifest format_version
/// 4. 校验 schema_version（可选忽略不匹配）
/// 5. 开启事务：遍历业务表 DELETE FROM <table>
/// 6. 遍历 business/*.json，直接 INSERT 保留备份原始字段（含 uuid/created_at 等）
/// 7. 事务提交
///
/// 与 `business_api::create_record_void` 的关键差异：
/// - 不生成新 uuid，保留备份原始 uuid（保证跨设备同步一致性）
/// - 不重置 created_at/updated_at/version，保留备份原始值
/// - 在事务中执行，支持全量覆盖恢复的原子性
pub async fn import_full_sync_backup(
    pool: &SqlitePool,
    sync_password: &str,
    bytes: &[u8],
    ignore_schema_mismatch: bool,
) -> FullSyncBackupResult<ImportResult> {
    // 1. 解码（密码错误立即返回，不进入清空阶段）
    let decoded = decode_backup(bytes, sync_password)?;

    // 2. 校验 manifest format_version
    decoded.manifest.validate_format_version()?;

    // 3. 校验 schema_version
    let current_schema = query_schema_version(pool).await?;
    if decoded.manifest.schema_version != current_schema && !ignore_schema_mismatch {
        return Err(FullSyncBackupError::SchemaVersionMismatch {
            backup: decoded.manifest.schema_version,
            current: current_schema,
        });
    }

    // 4. 开启事务：全量覆盖恢复
    let mut tx = pool.begin().await?;

    let mut total_success: i64 = 0;
    let mut total_errors: Vec<String> = Vec::new();

    // 遍历 manifest 中的所有业务表，先 DELETE 再 INSERT
    for table_name in decoded.manifest.table_counts.keys() {
        // 校验表名在白名单内（防 SQL 注入）
        if !business_api::FULL_BACKUP_TABLES.contains(&table_name.as_str()) {
            total_errors.push(format!("{}: 表名不在白名单", table_name));
            continue;
        }

        // 检查表是否存在（schema 变更场景：备份时的表在当前库可能已不存在）
        let table_exists: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?")
                .bind(table_name)
                .fetch_one(&mut *tx)
                .await
                .map_err(FullSyncBackupError::Db)?;

        if table_exists.0 == 0 {
            total_errors.push(format!("{}: 表不存在，跳过", table_name));
            continue;
        }

        // DELETE FROM <table>（物理删除，包括软删除的）
        let delete_sql = format!("DELETE FROM \"{}\"", table_name);
        if let Err(e) = sqlx::query(&delete_sql).execute(&mut *tx).await {
            return Err(FullSyncBackupError::Db(e));
        }
    }

    // 遍历 business/*.json，逐条直接 INSERT（保留备份原始字段）
    for (table_name, json_str) in &decoded.table_data {
        // 校验表名在白名单内
        if !business_api::FULL_BACKUP_TABLES.contains(&table_name.as_str()) {
            continue;
        }

        let records: Vec<serde_json::Map<String, serde_json::Value>> =
            match serde_json::from_str(json_str) {
                Ok(v) => v,
                Err(e) => {
                    total_errors.push(format!("{}: JSON 解析失败: {}", table_name, e));
                    continue;
                }
            };

        // 加载该表列元数据，用于对导入字段按声明类型规范化
        let columns = match load_table_columns_in_tx(&mut tx, table_name).await {
            Ok(cols) => cols,
            Err(e) => {
                total_errors.push(format!("{}: 加载表结构失败: {}", table_name, e));
                continue;
            }
        };

        for (idx, record) in records.iter().enumerate() {
            match insert_record_raw_in_tx(&mut tx, table_name, record, &columns).await {
                Ok(()) => total_success += 1,
                Err(e) => {
                    total_errors.push(format!("{} 第 {} 条: {}", table_name, idx + 1, e));
                }
            }
        }
    }

    // 提交事务
    tx.commit().await?;

    let error_count = total_errors.len() as i64;
    Ok(ImportResult {
        success_count: total_success,
        error_count,
        errors: total_errors,
        manifest: decoded.manifest,
        needs_restart: false,
    })
}

/// 在事务中直接 INSERT 记录，保留 JSON 中的原始字段
///
/// 与 `generic_repo::create_record_by_json_void` 的区别：
/// - 不生成新 uuid，保留备份原始 uuid（跨设备同步一致性）
/// - 不重置 created_at/updated_at/version，保留备份原始值
/// - 在事务中执行，支持全量覆盖恢复的原子性
/// - 按目标表列声明类型对字段值进行规范化，防止字符串写入 INTEGER 列等类型不匹配问题
///
/// 列名经 `validate_column_name` 校验（只允许字母/数字/下划线），防 SQL 注入。
async fn insert_record_raw_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
    columns: &HashMap<String, ColumnMeta>,
) -> Result<(), String> {
    use crate::db::repository::generic_repo::{push_json_value, validate_column_name};

    // 按目标表列声明类型规范化字段值，strict=true 确保非法类型直接失败
    let normalized =
        normalize_fields_with_columns(fields, columns, true).map_err(|e| e.to_string())?;

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
    q.push(table);
    q.push(" (");

    let mut first = true;
    for key in normalized.keys() {
        validate_column_name(key).map_err(|e| e.to_string())?;
        if !first {
            q.push(", ");
        }
        q.push(key);
        first = false;
    }
    q.push(") VALUES (");

    let mut first = true;
    for val in normalized.values() {
        if !first {
            q.push(", ");
        }
        push_json_value(&mut q, val);
        first = false;
    }
    q.push(")");

    q.build()
        .execute(&mut **tx)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// 读取备份清单（不解密整个 ZIP，仅用于预览）
///
/// 注意：当前实现仍调用 decode_backup（需要密码才能解密），
/// 因为 manifest 在加密的 ZIP 内部，无法不解密直接读取。
pub async fn peek_full_sync_manifest(
    bytes: &[u8],
    sync_password: &str,
) -> FullSyncBackupResult<BackupManifest> {
    let decoded = decode_backup(bytes, sync_password)?;
    Ok(decoded.manifest)
}

/// 列出备份目录下的所有 .waitfullsync 文件
pub async fn list_backups(app_data_dir: &Path) -> FullSyncBackupResult<Vec<BackupEntry>> {
    let prefs = load_prefs(app_data_dir)?;
    let backup_dir = resolve_backup_dir(app_data_dir, prefs.local_path.as_deref());
    repo_list_backups(&backup_dir)
}

/// 删除指定备份文件
pub async fn delete_backup(file_path: &Path) -> FullSyncBackupResult<()> {
    repo_delete_backup(file_path)
}

/// 仅保留最新备份：删除 keep_file 之外的所有备份
pub async fn keep_latest_backup(
    app_data_dir: &Path,
    keep_file: &Path,
) -> FullSyncBackupResult<Vec<PathBuf>> {
    let prefs = load_prefs(app_data_dir)?;
    let backup_dir = resolve_backup_dir(app_data_dir, prefs.local_path.as_deref());
    repo_keep_latest(&backup_dir, keep_file)
}

/// 读取备份偏好设置
pub async fn get_backup_prefs(app_data_dir: &Path) -> FullSyncBackupResult<BackupPrefs> {
    load_prefs(app_data_dir)
}

/// 保存备份偏好设置（含 v4 调度字段）
///
/// 保存前自动校验调度配置有效性
pub async fn save_backup_prefs(
    app_data_dir: &Path,
    prefs: &BackupPrefs,
) -> FullSyncBackupResult<()> {
    prefs.validate_schedule()?;
    save_prefs(app_data_dir, prefs)
}

/// 计算下一次备份时间戳（v4 调度器核心入口）
///
/// 桌面端 Tauri managed state 与移动端 Riverpod provider 共用此函数
pub fn calculate_next_backup(now_ts: i64, prefs: &BackupPrefs) -> i64 {
    calculate_next_backup_at(now_ts, prefs)
}

/// 更新调度器状态：触发后调用，更新 last_backup_at 与 next_backup_at
pub async fn update_scheduler_state_after_trigger(
    app_data_dir: &Path,
    triggered_at: i64,
) -> FullSyncBackupResult<BackupPrefs> {
    let mut prefs = load_prefs(app_data_dir)?;
    prefs.last_backup_at = triggered_at;
    prefs.next_backup_at = calculate_next_backup_at(triggered_at, &prefs);
    save_prefs(app_data_dir, &prefs)?;
    Ok(prefs)
}

/// 查询当前数据库 schema 版本
///
/// sqlx::migrate! 在 SQLite 中维护 `_sqlx_migrations` 元表，
/// 本函数读取其中 `success = 1` 的最大 version 作为当前 schema 版本。
/// 若该表尚不存在（例如尚未运行过迁移），则返回 0，避免首次备份即报错。
pub async fn query_schema_version(pool: &SqlitePool) -> FullSyncBackupResult<i64> {
    // 先检查元表是否存在，避免在旧库/空库上直接查询不存在的表
    let table_exists: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_sqlx_migrations'",
    )
    .fetch_one(pool)
    .await
    .map_err(|e| FullSyncBackupError::Other(format!("查询 schema_migrations 失败: {}", e)))?;

    if table_exists.0 == 0 {
        return Ok(0);
    }

    let row: (Option<i64>,) =
        sqlx::query_as("SELECT MAX(version) FROM _sqlx_migrations WHERE success = 1")
            .fetch_one(pool)
            .await
            .map_err(|e| {
                FullSyncBackupError::Other(format!("查询 schema_migrations 失败: {}", e))
            })?;
    Ok(row.0.unwrap_or(0))
}
