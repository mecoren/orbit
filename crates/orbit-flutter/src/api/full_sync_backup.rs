//! full_sync_backup — 移动端桥接层全量备份域（.orfullsync 导出/导入/云端副本）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在
//! orbit_core::api::full_sync_backup_api）：
//! - [full_backup_export] / [full_backup_import] → 桌面 full_backup_export /
//!   full_backup_import；
//! - [full_backup_list_local] / [full_backup_delete_local] → 桌面
//!   full_backup_list_local（桌面删除走前端对话框，移动端需显式命令）；
//! - [full_backup_list_cloud] / [full_backup_restore_cloud] /
//!   [full_backup_peek_cloud] → 桌面同名命令；
//! - [full_backup_peek_local] → 桌面 full_backup_peek_local；
//! - [backup_prefs_get] / [backup_prefs_save] → 桌面 backup_prefs_get /
//!   backup_prefs_save。
//!
//! ## 与桌面的两处差异
//! 1. **文件字节而非路径**：移动端无 tauri-plugin-dialog，「另存为 / 选文件」
//!    由 Dart 侧 file_picker 完成，桥层只收发 bytes（与 [super::asset] 同口径）；
//!    导出结果的 `file_path` 指向应用数据目录下的备份文件，UI 展示用。
//! 2. **密码不经 FRB 传参**：复用 [super::sync] 的进程级已解锁
//!    `SyncCryptoService` 单例（`runtime_crypto()`），未解锁时 core 内部
//!    `ensure_unlocked` 返回可读错误，前端引导先解锁同步密码。
//!
//! ## 事件
//! 导出/列举/预览是只读或纯本地写文件，**不 emit db-change**；
//! 导入与云端恢复是全量覆盖写，成功后 emit `table="*"` 的 db-change，
//! 移动端未知表回退全量失效（`db_invalidation.dart::invalidateByTable`）。
//!
//! ## 自动备份调度（手机被杀后无 Dart 进程，与桌面常驻 tick 不同）
//! [start_backup_scheduler] 为 FRB 运行时上的 Rust 守护（同
//! [super::holiday] 的 start_holiday_scheduler 模式）：60s tick。关键时序：
//! - **启动补备**：应用多日没开 → 打开时 db_init 后 Dart 调本函数，
//!   首轮 tick 即补备当日缺额；
//! - **未解锁静默跳过**：移动端同步密码仅进程内会话缓存，未解锁时
//!   导出返回可读错误，守护只推进 next 不打扰用户；
//! - 触发成功 → `update_scheduler_state_after_trigger` 推进 last/next；
//!   失败 → 仅推进 next（last 保留「最近一次成功」语义）。

use std::sync::atomic::{AtomicBool, Ordering};

use orbit_core::api::full_sync_backup_api;
use orbit_core::context;
use orbit_core::eventbus::EVENT_BUS;
use orbit_core::eventbus::events::{DbEvent, DbOp};
use orbit_core::full_sync_backup::backup_prefs::{BackupPrefs, ScheduleType};
use orbit_core::full_sync_backup::manifest::BackupManifest;
use orbit_core::full_sync_backup::save_prefs;
use orbit_core::sync::engine::SyncConfig as EngineSyncConfig;
use serde::Serialize;

use super::state::with_state;
use super::sync::runtime_crypto;

// ============================================================================
// DTO 镜像（外部 crate 类型经 FRB 会被降级 opaque，见 [super::dto] 模块注释）
// ============================================================================

/// 备份内单表记录数（BTreeMap 展开为有序列表，避免 FRB 对 Map 的镜像限制）
#[derive(Debug, Clone, Serialize)]
pub struct BackupTableCount {
    pub table: String,
    pub count: i64,
}

impl BackupTableCount {
    fn from_map(map: &std::collections::BTreeMap<String, usize>) -> Vec<Self> {
        map.iter()
            .map(|(table, count)| Self {
                table: table.clone(),
                count: *count as i64,
            })
            .collect()
    }
}

/// 备份清单（镜像 orbit_core::full_sync_backup::manifest::BackupManifest）
#[derive(Debug, Clone, Serialize)]
pub struct BackupManifestView {
    pub format_version: u32,
    /// RFC3339 字符串
    pub created_at: String,
    pub created_at_ts: i64,
    pub app_version: String,
    pub device_id: String,
    pub device_name: Option<String>,
    pub schema_version: i64,
    pub table_counts: Vec<BackupTableCount>,
}

impl From<BackupManifest> for BackupManifestView {
    fn from(m: BackupManifest) -> Self {
        Self {
            format_version: m.format_version,
            created_at: m.created_at,
            created_at_ts: m.created_at_ts,
            app_version: m.app_version,
            device_id: m.device_id,
            device_name: m.device_name,
            table_counts: BackupTableCount::from_map(&m.table_counts),
            schema_version: m.schema_version,
        }
    }
}

/// 导出结果（镜像 full_sync_backup_api::ExportResult）
#[derive(Debug, Clone, Serialize)]
pub struct BackupExportResult {
    pub file_path: String,
    pub file_size: i64,
    pub table_counts: Vec<BackupTableCount>,
    pub manifest: BackupManifestView,
    /// 云端备份路径（仅上传成功时有值）
    pub cloud_path: Option<String>,
    pub cloud_uploaded: bool,
    /// 云端上传错误（上传失败时有值，不阻塞本地备份）
    pub cloud_error: Option<String>,
    /// 本地备份文件路径（写入成功时有值）
    pub local_path: Option<String>,
    /// 本地写入错误（写入失败时有值）
    pub local_error: Option<String>,
}

impl From<full_sync_backup_api::ExportResult> for BackupExportResult {
    fn from(r: full_sync_backup_api::ExportResult) -> Self {
        Self {
            file_path: r.file_path,
            file_size: r.file_size as i64,
            table_counts: BackupTableCount::from_map(&r.table_counts),
            manifest: BackupManifestView::from(r.manifest),
            cloud_path: r.cloud_path,
            cloud_uploaded: r.cloud_uploaded,
            cloud_error: r.cloud_error,
            local_path: r.local_path,
            local_error: r.local_error,
        }
    }
}

/// 导入结果（镜像 full_sync_backup_api::ImportResult）
#[derive(Debug, Clone, Serialize)]
pub struct BackupImportResult {
    pub success_count: i64,
    pub error_count: i64,
    pub errors: Vec<String>,
    pub manifest: BackupManifestView,
    pub needs_restart: bool,
}

impl From<full_sync_backup_api::ImportResult> for BackupImportResult {
    fn from(r: full_sync_backup_api::ImportResult) -> Self {
        Self {
            success_count: r.success_count,
            error_count: r.error_count,
            errors: r.errors,
            manifest: BackupManifestView::from(r.manifest),
            needs_restart: r.needs_restart,
        }
    }
}

/// 备份内单条任务预览（镜像 full_sync_backup_api::PreviewTask）
#[derive(Debug, Clone, Serialize)]
pub struct BackupPreviewTask {
    pub title: String,
    pub status: String,
    pub done: bool,
    pub due_date: Option<i64>,
    pub priority: i64,
    /// 所属项目名（备份内解析不到为 None）
    pub project: Option<String>,
    pub is_deleted: bool,
}

impl From<full_sync_backup_api::PreviewTask> for BackupPreviewTask {
    fn from(t: full_sync_backup_api::PreviewTask) -> Self {
        Self {
            title: t.title,
            status: t.status,
            done: t.done,
            due_date: t.due_date,
            priority: t.priority,
            project: t.project,
            is_deleted: t.is_deleted,
        }
    }
}

/// 备份内任务统计（镜像 full_sync_backup_api::TaskPreviewStats）
#[derive(Debug, Clone, Serialize)]
pub struct BackupTaskStats {
    pub total: i64,
    pub alive: i64,
    pub done: i64,
    pub deleted: i64,
}

/// 恢复预览（镜像 full_sync_backup_api::BackupPreview）
#[derive(Debug, Clone, Serialize)]
pub struct BackupPreviewView {
    pub manifest: BackupManifestView,
    pub sample_tasks: Vec<BackupPreviewTask>,
    pub task_stats: BackupTaskStats,
    /// 与当前库 schema 不一致（恢复需强制二次确认）
    pub schema_mismatch: bool,
    pub current_schema_version: i64,
}

impl From<full_sync_backup_api::BackupPreview> for BackupPreviewView {
    fn from(p: full_sync_backup_api::BackupPreview) -> Self {
        Self {
            manifest: BackupManifestView::from(p.manifest),
            sample_tasks: p
                .sample_tasks
                .into_iter()
                .map(BackupPreviewTask::from)
                .collect(),
            task_stats: BackupTaskStats {
                total: p.task_stats.total as i64,
                alive: p.task_stats.alive as i64,
                done: p.task_stats.done as i64,
                deleted: p.task_stats.deleted as i64,
            },
            schema_mismatch: p.schema_mismatch,
            current_schema_version: p.current_schema_version,
        }
    }
}

/// 本地备份文件条目（镜像 full_sync_backup::backup_repository::BackupEntry）
#[derive(Debug, Clone, Serialize)]
pub struct BackupEntryView {
    pub filename: String,
    pub file_path: String,
    /// Unix 秒
    pub modified_at: i64,
    pub size_bytes: i64,
}

/// 云端备份条目（Desktop CloudBackupEntryView 同口径）
#[derive(Debug, Clone, Serialize)]
pub struct CloudBackupEntryView {
    pub name: String,
    /// 完整云端对象路径（peek / restore 回传用）
    pub cloud_path: String,
    pub size_bytes: i64,
    pub modified_at: i64,
}

/// 备份偏好（镜像 full_sync_backup::backup_prefs::BackupPrefs；
/// schedule_type 用字符串承载以保持 Dart 侧可读）
#[derive(Debug, Clone, Serialize)]
pub struct BackupPrefsView {
    pub local_path: Option<String>,
    pub keep_latest: bool,
    pub cloud_backup_enabled: bool,
    pub local_backup_enabled: bool,
    /// off / hourly / daily / weekly / monthly / yearly
    pub schedule_type: String,
    /// "HH:mm"
    pub schedule_time: String,
    pub schedule_minute: u32,
    pub schedule_weekday: u32,
    pub schedule_day_of_month: u32,
    pub schedule_month: u32,
    pub last_backup_at: i64,
    pub next_backup_at: i64,
}

fn schedule_type_str(t: ScheduleType) -> &'static str {
    match t {
        ScheduleType::Off => "off",
        ScheduleType::Hourly => "hourly",
        ScheduleType::Daily => "daily",
        ScheduleType::Weekly => "weekly",
        ScheduleType::Monthly => "monthly",
        ScheduleType::Yearly => "yearly",
    }
}

fn parse_schedule_type(s: &str) -> Result<ScheduleType, String> {
    match s.to_lowercase().as_str() {
        "" | "off" => Ok(ScheduleType::Off),
        "hourly" => Ok(ScheduleType::Hourly),
        "daily" => Ok(ScheduleType::Daily),
        "weekly" => Ok(ScheduleType::Weekly),
        "monthly" => Ok(ScheduleType::Monthly),
        "yearly" => Ok(ScheduleType::Yearly),
        other => Err(format!(
            "[backup] 不支持的调度类型：{other}（off/hourly/daily/weekly/monthly/yearly）"
        )),
    }
}

impl From<&BackupPrefs> for BackupPrefsView {
    fn from(p: &BackupPrefs) -> Self {
        Self {
            local_path: p.local_path.clone(),
            keep_latest: p.keep_latest,
            cloud_backup_enabled: p.cloud_backup_enabled,
            local_backup_enabled: p.local_backup_enabled,
            schedule_type: schedule_type_str(p.schedule_type).to_string(),
            schedule_time: p.schedule_time.clone(),
            schedule_minute: p.schedule_minute,
            schedule_weekday: p.schedule_weekday,
            schedule_day_of_month: p.schedule_day_of_month,
            schedule_month: p.schedule_month,
            last_backup_at: p.last_backup_at,
            next_backup_at: p.next_backup_at,
        }
    }
}

impl BackupPrefsView {
    fn to_core(&self) -> Result<BackupPrefs, String> {
        Ok(BackupPrefs {
            local_path: self.local_path.clone(),
            keep_latest: self.keep_latest,
            cloud_backup_enabled: self.cloud_backup_enabled,
            local_backup_enabled: self.local_backup_enabled,
            schedule_type: parse_schedule_type(&self.schedule_type)?,
            schedule_time: self.schedule_time.clone(),
            schedule_minute: self.schedule_minute,
            schedule_weekday: self.schedule_weekday,
            schedule_day_of_month: self.schedule_day_of_month,
            schedule_month: self.schedule_month,
            last_backup_at: self.last_backup_at,
            next_backup_at: self.next_backup_at,
        })
    }
}

/// 设备信息（导出预览展示用）
#[derive(Debug, Clone, Serialize)]
pub struct BackupDeviceInfo {
    pub device_id: String,
}

// ============================================================================
// 内部辅助
// ============================================================================

fn base_dir() -> Result<String, String> {
    with_state(|s| Ok(s.base_dir.to_string_lossy().to_string()))
}

/// 读取激活云配置（未配置或本地配置时返回可读错误）
async fn active_cloud_config(
    pool: &sqlx::SqlitePool,
    action: &str,
) -> Result<EngineSyncConfig, String> {
    full_sync_backup_api::get_active_cloud_config_from_db(pool)
        .await
        .map_err(|e| format!("[backup] {e}"))?
        .ok_or_else(|| format!("[config] 尚未配置云同步，无法{action}"))
}

/// 全量覆盖写成功后广播 db-change（table="*"；前端未知表回退全量失效）
fn emit_full_change() {
    EVENT_BUS.emit(DbEvent {
        table: "*".to_string(),
        op: DbOp::Sync,
        record_id: 0,
        record_uuid: String::new(),
        payload: None,
        device_id: context::get_device_id().unwrap_or_default().to_string(),
        timestamp: chrono::Utc::now().timestamp_millis(),
    });
}

// ============================================================================
// FRB 导出：导出 / 导入
// ============================================================================

/// 导出全量备份到 `{base_dir}/backups/`，`upload_cloud` 时额外上传云端副本
///
/// 手动导出（origin=Manual）不受自动备份偏好开关约束；密码复用已解锁态缓存，
/// 前端须先完成同步密码解锁。
pub async fn full_backup_export(upload_cloud: bool) -> Result<BackupExportResult, String> {
    let (pool, dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let svc = runtime_crypto()?;

    let cloud_config = if upload_cloud {
        Some(active_cloud_config(&pool, "上传云端副本").await?)
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
    .map(BackupExportResult::from)
}

/// 从 `.orfullsync` 字节全量覆盖恢复（兼容遗留 `.waitfullsync` / `.orsync`）
///
/// 警示语义：导入会清空当前业务表再写入备份内容（事务内原子完成）。
/// 成功后广播 db-change（table="*"）触发前端全量刷新。
pub async fn full_backup_import(
    bytes: Vec<u8>,
    ignore_schema_mismatch: bool,
) -> Result<BackupImportResult, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let svc = runtime_crypto()?;

    let result =
        full_sync_backup_api::import_full_sync_backup(&pool, &svc, &bytes, ignore_schema_mismatch)
            .await
            .map_err(|e| format!("[backup] 导入失败: {e}"))?;

    emit_full_change();
    Ok(BackupImportResult::from(result))
}

/// 从云端备份副本全量覆盖恢复（先下载字节，再走与本地一致的导入路径）
pub async fn full_backup_restore_cloud(
    cloud_path: String,
    ignore_schema_mismatch: bool,
) -> Result<BackupImportResult, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let svc = runtime_crypto()?;

    let config = active_cloud_config(&pool, "读取云端备份").await?;
    let adapter = orbit_core::sync::engine::create_adapter(&config)
        .map_err(|e| format!("[backup] 创建云适配器失败: {e}"))?;
    let bytes = full_sync_backup_api::download_cloud_backup(&*adapter, &cloud_path)
        .await
        .map_err(|e| format!("[backup] 下载云端备份失败: {e}"))?;

    let result =
        full_sync_backup_api::import_full_sync_backup(&pool, &svc, &bytes, ignore_schema_mismatch)
            .await
            .map_err(|e| format!("[backup] 导入失败: {e}"))?;

    emit_full_change();
    Ok(BackupImportResult::from(result))
}

// ============================================================================
// FRB 导出：清单列举 / 预览 / 删除 / 设备信息
// ============================================================================

/// 列出本地 backups 目录的历史备份（最新在前）
pub async fn full_backup_list_local() -> Result<Vec<BackupEntryView>, String> {
    let dir = base_dir()?;
    full_sync_backup_api::list_backups(std::path::Path::new(&dir))
        .await
        .map_err(|e| format!("[backup] {e}"))
        .map(|entries| {
            entries
                .into_iter()
                .map(|e| BackupEntryView {
                    filename: e.filename,
                    file_path: e.file_path.to_string_lossy().to_string(),
                    modified_at: e.modified_at,
                    size_bytes: e.file_size as i64,
                })
                .collect()
        })
}

/// 删除指定本地备份文件
pub async fn full_backup_delete_local(file_path: String) -> Result<(), String> {
    full_sync_backup_api::delete_backup(std::path::Path::new(&file_path))
        .await
        .map_err(|e| format!("[backup] 删除失败: {e}"))
}

/// 列出当前激活云空间 `backups/` 目录下的历史备份副本（最新在前）
pub async fn full_backup_list_cloud() -> Result<Vec<CloudBackupEntryView>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let config = active_cloud_config(&pool, "列出云端备份").await?;

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
                size_bytes: f.size as i64,
                modified_at: f.last_modified,
            }
        })
        .collect())
}

/// 读取本地备份恢复预览（解密 + 前 10 条任务抽样 + 统计，不写库）
pub async fn full_backup_peek_local(bytes: Vec<u8>) -> Result<BackupPreviewView, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let svc = runtime_crypto()?;
    full_sync_backup_api::peek_backup_preview(&pool, &svc, &bytes)
        .await
        .map_err(|e| format!("[backup] 预览失败: {e}"))
        .map(BackupPreviewView::from)
}

/// 读取云端备份恢复预览（先下载字节，再走与本地一致的预览路径，不写库）
pub async fn full_backup_peek_cloud(cloud_path: String) -> Result<BackupPreviewView, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let svc = runtime_crypto()?;

    let config = active_cloud_config(&pool, "读取云端备份").await?;
    let adapter = orbit_core::sync::engine::create_adapter(&config)
        .map_err(|e| format!("[backup] 创建云适配器失败: {e}"))?;
    let bytes = full_sync_backup_api::download_cloud_backup(&*adapter, &cloud_path)
        .await
        .map_err(|e| format!("[backup] 下载云端备份失败: {e}"))?;

    full_sync_backup_api::peek_backup_preview(&pool, &svc, &bytes)
        .await
        .map_err(|e| format!("[backup] 预览失败: {e}"))
        .map(BackupPreviewView::from)
}

/// 当前设备 ID（导出预览展示用；未初始化返回空串）
pub async fn full_backup_device_info() -> Result<BackupDeviceInfo, String> {
    Ok(BackupDeviceInfo {
        device_id: context::get_device_id().unwrap_or_default().to_string(),
    })
}

// ============================================================================
// FRB 导出：自动备份偏好读写
// ============================================================================

/// 读取备份偏好（无文件返回默认值：off + 本地开关开 + 云端开关开）
pub async fn backup_prefs_get() -> Result<BackupPrefsView, String> {
    let dir = base_dir()?;
    full_sync_backup_api::get_backup_prefs(std::path::Path::new(&dir))
        .await
        .map_err(|e| format!("[backup] {e}"))
        .map(|p| BackupPrefsView::from(&p))
}

/// 保存备份偏好（校验调度配置；返回回填 next_backup_at 后的完整偏好）
///
/// 调度变更时统一重算 next_backup_at：off → 0（取消调度），
/// 其余 → 从当前时间起算的下一次触发点（与桌面 backup_prefs_save 同口径）。
pub async fn backup_prefs_save(prefs: BackupPrefsView) -> Result<BackupPrefsView, String> {
    let dir = base_dir()?;
    let mut core_prefs = prefs.to_core()?;
    core_prefs.next_backup_at = if core_prefs.schedule_type == ScheduleType::Off {
        0
    } else {
        full_sync_backup_api::calculate_next_backup(chrono::Utc::now().timestamp(), &core_prefs)
    };

    full_sync_backup_api::save_backup_prefs(std::path::Path::new(&dir), &core_prefs)
        .await
        .map_err(|e| format!("[backup] {e}"))?;
    Ok(BackupPrefsView::from(&core_prefs))
}

// ============================================================================
// FRB 导出：自动备份调度守护
// ============================================================================

/// tick 周期：60s（与桌面 backup_scheduler 一致）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);
/// 防重入：备份导出较重，重叠触发直接跳过
static RUNNING: AtomicBool = AtomicBool::new(false);

/// 启动定时全量备份守护（幂等；Dart 在 DB 就绪后调用一次，BootGate 接线）
///
/// 移动端无跨重启用持久凭据，未解锁同步密码时导出返回可读错误——
/// 守护仅推进 next_backup_at，不打扰用户。
pub fn start_backup_scheduler() {
    if SCHEDULER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    super::events::spawn_on_bridge_runtime(async {
        loop {
            tick_once().await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

/// 单轮判定与触发（对齐桌面 backup_scheduler::tick，AppHandle 换全局状态）
async fn tick_once() {
    let Ok((pool, dir)) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone()))) else {
        return; // DB 未就绪静默跳过
    };

    let Ok(mut prefs) = full_sync_backup_api::get_backup_prefs(&dir).await else {
        return;
    };
    if prefs.schedule_type == ScheduleType::Off {
        return;
    }

    let now_ts = chrono::Utc::now().timestamp();
    // 首次启用：初始化 next_backup_at 后等待到点
    if prefs.next_backup_at == 0 {
        prefs.next_backup_at = full_sync_backup_api::calculate_next_backup(now_ts, &prefs);
        let _ = save_prefs(&dir, &prefs);
        return;
    }
    if now_ts < prefs.next_backup_at || prefs.validate_schedule().is_err() {
        return;
    }
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }

    // 云端配置按开关取用；未配置云同步时 None（云端阶段静默跳过）
    let cloud_config = if prefs.cloud_backup_enabled {
        full_sync_backup_api::get_active_cloud_config_from_db(&pool)
            .await
            .unwrap_or(None)
    } else {
        None
    };

    let svc = match runtime_crypto() {
        Ok(svc) => svc,
        Err(e) => {
            eprintln!("[backup-scheduler] 同步加密不可用，跳过本轮: {e}");
            RUNNING.store(false, Ordering::SeqCst);
            return;
        }
    };

    // origin=Auto 受偏好开关约束；upload_cloud 仅对 Manual 有意义
    let result = full_sync_backup_api::export_full_sync_backup(
        &pool,
        &dir,
        &svc,
        full_sync_backup_api::BackupOrigin::Auto,
        cloud_config,
        true,
    )
    .await;

    match result {
        Ok(r) => {
            // 本地写入失败（磁盘满等）不算成功：不推进 last_backup_at
            //（next 照常推进避免风暴）
            let local_failed = prefs.local_backup_enabled && r.local_error.is_some();
            if local_failed {
                eprintln!(
                    "[backup-scheduler] 定时备份本地写入失败: {}",
                    r.local_error.as_deref().unwrap_or("未知")
                );
                if let Ok(mut p) = full_sync_backup_api::get_backup_prefs(&dir).await {
                    p.next_backup_at = full_sync_backup_api::calculate_next_backup(now_ts, &p);
                    let _ = save_prefs(&dir, &p);
                }
            } else if let Err(e) =
                full_sync_backup_api::update_scheduler_state_after_trigger(&dir, now_ts).await
            {
                eprintln!("[backup-scheduler] 推进调度状态失败: {e}");
            }
        }
        Err(e) => {
            eprintln!("[backup-scheduler] 定时备份失败: {e}");
            // 仅推进 next，避免同一时刻反复重试；last_backup_at 保留成功语义
            if let Ok(mut p) = full_sync_backup_api::get_backup_prefs(&dir).await {
                p.next_backup_at = full_sync_backup_api::calculate_next_backup(now_ts, &p);
                let _ = save_prefs(&dir, &p);
            }
        }
    }
    RUNNING.store(false, Ordering::SeqCst);
}
