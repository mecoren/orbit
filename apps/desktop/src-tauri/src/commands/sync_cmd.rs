//! sync_cmd — 同步连接配置命令组（06 任务 3.2/3.5）
//!
//! 配置双存储（03 文档 §八）：DB `sync_configs` 表（激活互斥、last_synced_at 记账）
//! + `sync_config.enc` 加密文件（03 §八最小字段契约，供备份命名等松耦合读取）。
//!
//! 列复用约定（沿袭 wait-home 移动端，engine_config_of_record 同口径）：
//! - WebDAV：endpoint=服务器 URL，device_id 列=用户名，credential 列=密码
//! - S3：endpoint/bucket/region 直取，device_id 列=access_key，credential 列=secret_key

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

use orbit_core::db::repository::sync_config_repo::SyncConfigRepo;
use orbit_core::models::sync_config::{SyncConfigRecord, SyncConfigSaveInput};

use crate::AppState;

/// 前端提交的同步配置输入（03 文档 §八 sync_config.json 字段契约的 UI 面）
#[derive(Debug, Clone, Deserialize)]
pub struct SyncConfigInput {
    /// "webdav" | "s3"
    pub engine: String,
    /// WebDAV 服务器 URL / S3 endpoint
    pub endpoint: String,
    /// S3 bucket（WebDAV 留空）
    #[serde(default)]
    pub bucket: String,
    /// S3 region（WebDAV 留空）
    #[serde(default)]
    pub region: String,
    /// WebDAV 用户名 / S3 access_key_id
    #[serde(default)]
    pub username: String,
    /// WebDAV 密码 / S3 secret_access_key
    #[serde(default)]
    pub password: String,
    /// 云端根路径（默认 "orbit"）
    #[serde(default = "default_base_path")]
    pub base_path: String,
    /// 定时同步间隔分钟；0 = 关闭定时
    #[serde(default)]
    pub interval_minutes: i64,
    /// 总开关（自动同步）
    #[serde(default = "default_true")]
    pub auto_sync_enabled: bool,
    /// 修改后立即同步（防抖 5s 合并连续编辑）
    #[serde(default)]
    pub sync_on_change: bool,
    /// 跳过 TLS 证书校验（自签名证书）
    #[serde(default)]
    pub skip_tls_verify: bool,
    /// 请求超时秒数；0 = 默认 30
    #[serde(default = "default_timeout")]
    pub timeout_seconds: i64,
}

fn default_base_path() -> String {
    "orbit".to_string()
}
fn default_true() -> bool {
    true
}
fn default_timeout() -> i64 {
    30
}

/// 前端展示用配置视图（凭据打码返回）
#[derive(Debug, Clone, Serialize)]
pub struct SyncConfigView {
    pub id: i64,
    pub engine: String,
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub username: String,
    /// 打码：仅提示已设置
    pub password_set: bool,
    pub base_path: String,
    pub interval_minutes: i64,
    pub auto_sync_enabled: bool,
    pub sync_on_change: bool,
    pub skip_tls_verify: bool,
    pub timeout_seconds: i64,
    pub last_synced_at: Option<i64>,
}

impl SyncConfigView {
    fn from_record(r: &SyncConfigRecord) -> Self {
        Self {
            id: r.id,
            engine: r.protocol.clone(),
            endpoint: r.endpoint.clone(),
            bucket: r.bucket.clone(),
            region: r.region.clone(),
            username: r.device_id.clone(),
            password_set: !r.credential.is_empty(),
            base_path: r.path.clone(),
            interval_minutes: r.sync_interval,
            auto_sync_enabled: r.is_auto_sync != 0,
            sync_on_change: r.sync_on_change != 0,
            skip_tls_verify: r.skip_tls_verify != 0,
            timeout_seconds: if r.timeout == 0 { 30 } else { r.timeout },
            last_synced_at: r.last_synced_at,
        }
    }
}

/// 读取当前激活配置（未配置返回 null）
#[tauri::command]
pub async fn sync_config_get(app: AppHandle) -> Result<Option<SyncConfigView>, String> {
    Ok(sync_config_active(&app)
        .await?
        .as_ref()
        .map(SyncConfigView::from_record))
}

async fn sync_config_active(app: &AppHandle) -> Result<Option<SyncConfigRecord>, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    SyncConfigRepo::new(pool)
        .get_active_config()
        .await
        .map_err(|e| format!("[database] 读取同步配置失败: {e}"))
}

/// 保存同步配置（DB + 加密文件双写；激活互斥由仓储层保证）
///
/// 成功后 emit("sync-config-changed")；调度器在下个 60s tick 读取新配置生效。
#[tauri::command]
pub async fn sync_config_save(
    app: AppHandle,
    input: SyncConfigInput,
) -> Result<SyncConfigView, String> {
    let engine = input.engine.to_lowercase();
    if engine != "webdav" && engine != "s3" {
        return Err("[config] 不支持的引擎类型，仅支持 webdav/s3".to_string());
    }
    if input.endpoint.trim().is_empty() {
        return Err("[config] 服务器地址不能为空".to_string());
    }
    if engine == "s3" && input.bucket.trim().is_empty() {
        return Err("[config] S3 存储桶不能为空".to_string());
    }

    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();

    // 沿袭既有记录 id（更新而非新建），保持 last_synced_at 记账连续
    let existing = SyncConfigRepo::new(pool.clone())
        .get_active_config()
        .await
        .map_err(|e| format!("[database] 读取现有配置失败: {e}"))?;

    // 密码留空且已有配置 → 沿用原凭据（前端不回显已存密码）
    let credential = if !input.password.is_empty() {
        input.password.clone()
    } else {
        existing
            .as_ref()
            .map(|r| r.credential.clone())
            .unwrap_or_default()
    };

    let save_input = SyncConfigSaveInput {
        id: existing.as_ref().map(|r| r.id),
        protocol: engine.clone(),
        endpoint: input.endpoint.trim().to_string(),
        bucket: input.bucket.trim().to_string(),
        region: input.region.trim().to_string(),
        path: input.base_path.trim().trim_matches('/').to_string(),
        device_id: input.username.clone(),
        credential,
        encryption_key_id: String::new(),
        merge_strategy: "lww".to_string(),
        sync_mode: "two_way".to_string(),
        max_update_age_hours: 0,
        is_encrypted: 1,
        is_active: 1,
        is_auto_sync: if input.auto_sync_enabled { 1 } else { 0 },
        sync_interval: input.interval_minutes.clamp(0, 24 * 60),
        sync_on_change: if input.sync_on_change { 1 } else { 0 },
        concurrent_reqs: 8,
        timeout: input.timeout_seconds.clamp(0, 600),
        skip_tls_verify: if input.skip_tls_verify { 1 } else { 0 },
        targets: "todo".to_string(),
        local_path: None,
        schedule_type: "interval".to_string(),
        schedule_time: None,
        schedule_weekday: None,
        sync_scope: "all".to_string(),
        full_sync_interval: 0,
        history_keep_count: 5,
        notify_progress: 1,
    };

    let record = SyncConfigRepo::new(pool)
        .save_config(&save_input)
        .await
        .map_err(|e| format!("[database] 保存同步配置失败: {e}"))?;

    write_config_file(&input, &engine)?;

    app.emit("sync-config-changed", ())
        .map_err(|e| format!("[other] 事件发送失败: {e}"))?;

    Ok(SyncConfigView::from_record(&record))
}

/// 写入加密文件侧（03 §八契约字段；写入失败不阻断 DB 已保存的事实，仅告警）
///
/// ADR 0001 §七-① 方案 (a)：CEK 不可用（移动端）时降级写明文 sync_config.json，
/// 与 backup_prefs「加密优先、明文降级」模式对称；桌面 CEK 可用恒走加密分支，行为不变。
fn write_config_file(input: &SyncConfigInput, engine: &str) -> Result<(), String> {
    let device_name = whoami::fallible::hostname().unwrap_or_default();
    let cfg = if engine == "webdav" {
        serde_json::json!({
            "engine": "webdav",
            "webdav": {
                "base_url": input.endpoint.trim(),
                "username": input.username,
                "password": input.password,
                "base_path": input.base_path.trim(),
            },
            "interval_minutes": input.interval_minutes,
            "auto_sync_enabled": input.auto_sync_enabled,
            "device_name": device_name,
        })
    } else {
        serde_json::json!({
            "engine": "s3",
            "s3": {
                "endpoint": input.endpoint.trim(),
                "region": input.region.trim(),
                "bucket": input.bucket.trim(),
                "access_key_id": input.username,
                "secret_access_key": input.password,
                "base_path": input.base_path.trim(),
            },
            "interval_minutes": input.interval_minutes,
            "auto_sync_enabled": input.auto_sync_enabled,
            "device_name": device_name,
        })
    };
    if let Some(storage) = orbit_core::config_enc::get_global_storage() {
        storage
            .save_with_plaintext_fallback("sync_config", &cfg)
            .map_err(|e| {
                eprintln!("[sync-cmd] 配置文件写入失败（DB 已保存）: {e}");
                format!("[other] 配置文件写入失败: {e}")
            })?;
    }
    Ok(())
}

/// 测试连接（不落盘）：validate → 构造适配器 → list 探测
///
/// 密码/用户名留空且已有激活配置时，沿用已存凭据（前端不回显密码）。
/// 返回云端根目录发现的条目数；网络/认证错误统一 `[network]` 前缀。
#[tauri::command]
pub async fn sync_test_connection(app: AppHandle, input: SyncConfigInput) -> Result<u32, String> {
    let engine = input.engine.to_lowercase();
    if engine != "webdav" && engine != "s3" {
        return Err("[config] 不支持的引擎类型，仅支持 webdav/s3".to_string());
    }

    // 凭据补齐：留空字段从已存激活配置回填
    let mut username = input.username.clone();
    let mut password = input.password.clone();
    if (username.is_empty() || password.is_empty())
        && let Some(saved) = sync_config_active(&app).await?
        && saved.protocol.to_lowercase() == engine
    {
        if username.is_empty() {
            username = saved.device_id.clone();
        }
        if password.is_empty() {
            password = saved.credential.clone();
        }
    }
    if username.is_empty() || password.is_empty() {
        return Err("[config] 请填写用户名与密码".to_string());
    }

    let config = orbit_core::sync::engine::SyncConfig {
        adapter_type: engine,
        endpoint: input.endpoint.trim().to_string(),
        bucket: input.bucket.trim().to_string(),
        region: input.region.trim().to_string(),
        access_key: username,
        secret_key: password,
        base_path: String::new(),
        device_id: "test-device".to_string(),
        device_name: "test".to_string(),
        timeout_secs: input.timeout_seconds.max(0) as u64,
        skip_tls_verify: input.skip_tls_verify,
    };
    orbit_core::sync::engine::validate_config(&config).map_err(|e| format!("[config] {e}"))?;
    let adapter =
        orbit_core::sync::engine::create_adapter(&config).map_err(|e| format!("[network] {e}"))?;
    let files = adapter
        .list_all_files("")
        .await
        .map_err(|e| format!("[network] 连接失败: {e}"))?;
    Ok(files.len() as u32)
}
