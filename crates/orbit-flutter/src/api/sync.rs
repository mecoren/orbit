//! sync — 同步域 FRB 桥接层（移动端 v1 手动同步）
//!
//! 把桌面壳三组同步命令一比一移植为 FRB 导出函数，业务全部委托 orbit_core：
//! - sync_cmd.rs        → [sync_config_get]/[sync_config_save]/[sync_test_connection]
//! - cloud_sync_cmd.rs  → [cloud_sync_now]/[cloud_sync_push_only]/
//!   [cloud_sync_pull_then_push]/[cloud_sync_get_state]/[cloud_sync_is_running]/
//!   [sync_disconnect]
//! - sync_crypto_cmd.rs → [sync_crypto_status]/[sync_crypto_init]/
//!   [sync_crypto_unlock]/[sync_crypto_lock]/[sync_crypto_change_password]/
//!   [sync_crypto_export_bundle]/[sync_crypto_import_bundle]/
//!   [sync_crypto_restore_session]/[sync_crypto_forget_session]
//!
//! ## v1 范围（明确不做）
//! 仅手动触发命令面。桌面端的后台 60s tick 调度器、sync_on_change watcher、
//! 定时备份均**不移植**——移动端自动同步由后续版本配合 OS 后台任务另行设计。
//!
//! ## keyring 降级策略（与桌面 sync_runtime.rs 的差异）
//! Android 无系统凭据库，本层**不注册** KeyringCekProvider /
//! register_global_encrypted_storage（桌面注册失败同样降级明文，故移动端直接
//! 不走注册路径）。由此产生的降级行为：
//! - 同步密码缓存退化为**进程内会话缓存**（SyncRuntime.session_password）：
//!   init/unlock/change/import 成功后记入槽位并挂载到引擎；lock /
//!   forget_session 时清除。重启 App 后需重输同步密码。
//! - [sync_crypto_restore_session] 因此恒返回 false（除非本就已解锁），仅为
//!   Dart 侧 API 面对齐桌面而保留。
//! - sync_config_save 的加密文件侧写（sync_config.enc / 明文 json 回退）整体
//!   跳过：未注册全局 EncryptedConfigStorage 时 core 的 get_global_storage()
//!   返回 None，DB `sync_configs` 表为唯一事实源（03 §八双存储中文件侧仅供
//!   松耦合读取，core 内读取方自带回退）。
//!
//! ## 其他与桌面的差异
//! - 桌面 run_sync 成功后 emit("sync-finished")、配置变更 emit("sync-config-changed")；
//!   移动端结果 JSON 直接经返回值交给调用方，广播事件待 events 模块接线后补。
//! - 引擎进度发送器用 NoopProgressSender（sync-progress 尚无 StreamSink 消费方），
//!   同步执行路径与桌面完全一致，仅 UI 实时进度暂缺。
//! - 云同步执行命令返回 Result<String,String>（JSON 字符串），Dart 自行 parse，
//!   与桌面 TS 侧契约一致，Dart DTO 无需镜像 SyncResult。
//! - 时间戳用 std::time 计算（本 crate 不直接依赖 chrono）。

use std::path::{Path, PathBuf};

use once_cell::sync::Lazy;
use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::engine::SyncEngine;
use orbit_core::cloud_sync::error::CloudSyncError;
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::cloud_sync::state::SyncStateStore;
use orbit_core::context;
use orbit_core::db::repository::sync_config_repo::SyncConfigRepo;
use orbit_core::models::sync_config::{SyncConfigRecord, SyncConfigSaveInput};
use orbit_core::sync_crypto::KEY_DERIVATION_V2;
use orbit_core::sync_crypto::SyncCryptoService;
use orbit_core::sync_crypto::error::SyncCryptoError;
use orbit_core::sync_crypto::meta_store::SyncCryptoMeta;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use super::state::with_state;

// ============================================================================
// 同步域进程级单例（替代桌面 app.manage(SyncRuntime::default())）
// ============================================================================

/// 同步运行时槽位：与 OrbitState.base_dir 绑定
///
/// - `crypto`：SyncCryptoService（meta 文件位于 base_dir，克隆共享 Data Key 内存态）
/// - `engine`：SyncEngine 懒创建（依赖连接池就绪）；Clone 共享内部 Arc，
///   同步互斥锁与 sync_password 缓存跨命令持久（禁止按命令临时构造）
/// - `session_password`：同步密码会话缓存（keyring 降级，见模块注释）
struct SyncRuntime {
    base_dir: PathBuf,
    crypto: SyncCryptoService,
    engine: Option<SyncEngine>,
    session_password: Option<String>,
}

static SYNC_RUNTIME: Lazy<Mutex<Option<SyncRuntime>>> = Lazy::new(|| Mutex::new(None));

/// 访问运行时槽位（不存在或 base_dir 变化——如迁移重开数据库——时重建）
///
/// 注意：先经 with_state 取 base_dir 并释放 ORBIT_STATE 锁，再获取
/// SYNC_RUNTIME 锁，两把锁永不嵌套持有。
fn with_runtime<T>(f: impl FnOnce(&mut SyncRuntime) -> Result<T, String>) -> Result<T, String> {
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let mut guard = SYNC_RUNTIME.lock();
    if !matches!(guard.as_ref(), Some(rt) if rt.base_dir == base_dir) {
        *guard = Some(SyncRuntime {
            crypto: SyncCryptoService::new(&base_dir),
            base_dir,
            engine: None,
            session_password: None,
        });
    }
    f(guard.as_mut().expect("槽位刚被插入"))
}

/// 取同步加密服务单例（对齐桌面 sync_runtime::sync_crypto）
///
/// pub(crate)：全量备份域（[super::full_sync_backup]）复用同一已解锁实例，
/// 避免备份导出/导入另起一份 Data Key 内存态。
pub(crate) fn runtime_crypto() -> Result<SyncCryptoService, String> {
    with_runtime(|rt| Ok(rt.crypto.clone()))
}

/// 取同步引擎单例，懒创建（对齐桌面 sync_runtime::sync_engine）
///
/// 差异：进度发送器用 NoopProgressSender（见模块注释）；引擎懒创建晚于解锁时，
/// 从会话缓存回填同步密码（桌面从钥匙串读缓存，移动端无持久凭据库）。
fn runtime_engine() -> Result<SyncEngine, String> {
    let (pool, base_dir) = with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    with_runtime(move |rt| {
        if let Some(engine) = rt.engine.as_ref() {
            return Ok(engine.clone());
        }
        let engine = cloud_sync_api::create_engine_noop(pool, rt.crypto.clone(), &base_dir);
        if rt.crypto.is_unlocked()
            && let Some(password) = &rt.session_password
        {
            engine.set_sync_password(password.clone());
        }
        // 引擎 Clone 共享互斥锁与密码缓存；重复插入以最后写入者为准（幂等语义）
        Ok(rt.engine.insert(engine).clone())
    })
}

// ============================================================================
// 内部辅助（错误标记 / 配置读取 / 记录转换）
// ============================================================================

/// CloudSyncError → `[tag] message`（key_mismatch 前端跳恢复页；
/// payload_version = 云端由更新版本客户端写出，前端只需 toast 出「升级应用」文案）
fn err_tagged_cloud(e: CloudSyncError) -> String {
    format!("[{}] {}", e.category_tag(), e)
}

/// SyncCryptoError → `[tag] message`（前端按 tag 路由 UI 分支）
fn err_tagged_crypto(e: SyncCryptoError) -> String {
    match &e {
        SyncCryptoError::WrongPassword => format!("[wrong_password] {e}"),
        SyncCryptoError::NotInitialized => format!("[not_initialized] {e}"),
        SyncCryptoError::NotUnlocked => format!("[not_unlocked] {e}"),
        SyncCryptoError::LocalMetaExists => format!("[local_meta_exists] {e}"),
        other => format!("[sync_crypto] {other}"),
    }
}

/// 读取激活的同步配置记录（未配置返回 None）（对齐 sync_cmd::sync_config_active）
async fn active_config() -> Result<Option<SyncConfigRecord>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    SyncConfigRepo::new(pool)
        .get_active_config()
        .await
        .map_err(|e| format!("[database] 读取同步配置失败: {e}"))
}

/// 将 DB 记录转换为引擎配置（照抄桌面 sync_runtime::engine_config_of_record）
///
/// 列复用约定（沿袭 wait-home 移动端）：WebDAV 用户名 / S3 access_key 存
/// record.device_id 列；credential 列存 WebDAV 密码 / S3 secret_key。
fn engine_config_of_record(
    record: &SyncConfigRecord,
) -> Option<orbit_core::sync::engine::SyncConfig> {
    let adapter_type = record.protocol.to_lowercase();
    if adapter_type == "local" || adapter_type.is_empty() {
        return None;
    }
    let device_id = context::get_device_id().unwrap_or_default().to_string();
    Some(orbit_core::sync::engine::SyncConfig {
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

/// 附件目录（照抄桌面 sync_runtime::attachments_dir；MVP 占位实现）
fn attachments_dir(dir: &Path) -> String {
    dir.join("attachments").to_string_lossy().to_string()
}

/// 解析 origin 字符串（前端传 "manual" | "background" | "exit"）
fn parse_origin(origin: &str) -> SyncOrigin {
    match origin {
        "background" => SyncOrigin::Background,
        "exit" => SyncOrigin::Exit,
        _ => SyncOrigin::Manual,
    }
}

// ============================================================================
// 配置命令组（对应桌面 sync_cmd.rs）
// ============================================================================

/// 前端提交的同步配置输入（镜像桌面 sync_cmd::SyncConfigInput）
///
/// 桌面用 serde(default) 补默认值；FRB 参数面改为 Option 字段，
/// 由 [sync_config_save]/[sync_test_connection] 按桌面默认值展开。
#[derive(Debug, Clone, Deserialize)]
pub struct SyncConfigInput {
    /// "webdav" | "s3"
    pub engine: String,
    /// WebDAV 服务器 URL / S3 endpoint
    pub endpoint: String,
    /// S3 bucket（WebDAV 留空/null）
    pub bucket: Option<String>,
    /// S3 region（WebDAV 留空/null）
    pub region: Option<String>,
    /// WebDAV 用户名 / S3 access_key_id
    pub username: Option<String>,
    /// WebDAV 密码 / S3 secret_access_key（留空/null 表示沿用已存凭据）
    pub password: Option<String>,
    /// 云端根路径（null 时默认 "orbit"）
    pub base_path: Option<String>,
    /// 定时同步间隔分钟；0 = 关闭定时
    pub interval_minutes: Option<i64>,
    /// 总开关（自动同步）；null 时默认 true
    pub auto_sync_enabled: Option<bool>,
    /// 修改后立即同步（v1 移动端不启用 watcher，仅存档）
    pub sync_on_change: Option<bool>,
    /// 跳过 TLS 证书校验（自签名证书）
    pub skip_tls_verify: Option<bool>,
    /// 请求超时秒数；0 = 默认 30
    pub timeout_seconds: Option<i64>,
}

impl SyncConfigInput {
    fn username_str(&self) -> &str {
        self.username.as_deref().unwrap_or("")
    }
    fn password_str(&self) -> &str {
        self.password.as_deref().unwrap_or("")
    }
    fn bucket_trimmed(&self) -> String {
        self.bucket.as_deref().unwrap_or("").trim().to_string()
    }
    fn region_trimmed(&self) -> String {
        self.region.as_deref().unwrap_or("").trim().to_string()
    }
    fn base_path_normalized(&self) -> String {
        self.base_path
            .as_deref()
            .unwrap_or("orbit")
            .trim()
            .trim_matches('/')
            .to_string()
    }
    fn interval_clamped(&self) -> i64 {
        self.interval_minutes.unwrap_or(0).clamp(0, 24 * 60)
    }
    fn auto_sync_flag(&self) -> i64 {
        i64::from(self.auto_sync_enabled.unwrap_or(true))
    }
    fn sync_on_change_flag(&self) -> i64 {
        i64::from(self.sync_on_change.unwrap_or(false))
    }
    fn timeout_clamped(&self) -> i64 {
        self.timeout_seconds.unwrap_or(30).clamp(0, 600)
    }
    fn skip_tls_flag(&self) -> i64 {
        i64::from(self.skip_tls_verify.unwrap_or(false))
    }
}

/// 前端展示用配置视图（凭据打码返回；镜像桌面 sync_cmd::SyncConfigView）
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
///
/// 对齐桌面 `sync_config_get`。
pub async fn sync_config_get() -> Result<Option<SyncConfigView>, String> {
    Ok(active_config()
        .await?
        .as_ref()
        .map(SyncConfigView::from_record))
}

/// 保存同步配置（DB 单写；激活互斥由仓储层保证）
///
/// 对齐桌面 `sync_config_save`。差异：
/// - 加密文件侧写（write_config_file）跳过：移动端未注册全局
///   EncryptedConfigStorage，DB 为唯一事实源（keyring 降级策略见模块注释）；
/// - emit("sync-config-changed") 不广播，Dart 保存成功后自行刷新状态。
pub async fn sync_config_save(input: SyncConfigInput) -> Result<SyncConfigView, String> {
    let engine = input.engine.to_lowercase();
    if engine != "webdav" && engine != "s3" {
        return Err("[config] 不支持的引擎类型，仅支持 webdav/s3".to_string());
    }
    if input.endpoint.trim().is_empty() {
        return Err("[config] 服务器地址不能为空".to_string());
    }
    if engine == "s3" && input.bucket_trimmed().is_empty() {
        return Err("[config] S3 存储桶不能为空".to_string());
    }

    let pool = with_state(|s| Ok(s.pool.clone()))?;

    // 沿袭既有记录 id（更新而非新建），保持 last_synced_at 记账连续
    let existing = SyncConfigRepo::new(pool.clone())
        .get_active_config()
        .await
        .map_err(|e| format!("[database] 读取现有配置失败: {e}"))?;

    // 密码留空且已有配置 → 沿用原凭据（前端不回显已存密码）
    let credential = if !input.password_str().is_empty() {
        input.password_str().to_string()
    } else {
        existing
            .as_ref()
            .map(|r| r.credential.clone())
            .unwrap_or_default()
    };

    let save_input = SyncConfigSaveInput {
        id: existing.as_ref().map(|r| r.id),
        protocol: engine,
        endpoint: input.endpoint.trim().to_string(),
        bucket: input.bucket_trimmed(),
        region: input.region_trimmed(),
        path: input.base_path_normalized(),
        device_id: input.username_str().to_string(),
        credential,
        encryption_key_id: String::new(),
        merge_strategy: "lww".to_string(),
        sync_mode: "two_way".to_string(),
        max_update_age_hours: 0,
        is_encrypted: 1,
        is_active: 1,
        is_auto_sync: input.auto_sync_flag(),
        sync_interval: input.interval_clamped(),
        sync_on_change: input.sync_on_change_flag(),
        concurrent_reqs: 8,
        timeout: input.timeout_clamped(),
        skip_tls_verify: input.skip_tls_flag(),
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

    Ok(SyncConfigView::from_record(&record))
}

/// 测试连接（不落盘）：validate → 构造适配器 → list 探测
///
/// 对齐桌面 `sync_test_connection`。用户名/密码留空且已有激活配置时沿用已存
/// 凭据（同协议才回填）；返回云端根目录发现的条目数，网络错误统一 `[network]` 前缀。
pub async fn sync_test_connection(input: SyncConfigInput) -> Result<u32, String> {
    let engine = input.engine.to_lowercase();
    if engine != "webdav" && engine != "s3" {
        return Err("[config] 不支持的引擎类型，仅支持 webdav/s3".to_string());
    }

    // 凭据补齐：留空字段从已存激活配置回填
    let mut username = input.username_str().to_string();
    let mut password = input.password_str().to_string();
    if (username.is_empty() || password.is_empty())
        && let Some(saved) = active_config().await?
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
        bucket: input.bucket_trimmed(),
        region: input.region_trimmed(),
        access_key: username,
        secret_key: password,
        base_path: String::new(),
        device_id: "test-device".to_string(),
        device_name: "test".to_string(),
        timeout_secs: input.timeout_seconds.unwrap_or(30).max(0) as u64,
        skip_tls_verify: input.skip_tls_verify.unwrap_or(false),
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

// ============================================================================
// 云同步执行命令组（对应桌面 cloud_sync_cmd.rs）
// ============================================================================

enum SyncAction {
    Now,
    PushOnly,
    PullThenPush,
}

/// 同步执行公共骨架（照抄桌面 cloud_sync_cmd::run_sync，AppHandle 换全局状态）
///
/// 配置 + 引擎 + 附件目录 → 动作 → 结果 JSON 字符串（last_synced_at 由 core 漏斗回写）。
/// 差异：成功后不再 emit("sync-finished")——结果已经由返回值直达调用方，
/// 广播给其他监听方待 events 模块提供 sync 事件流后再补。
async fn run_sync(origin: SyncOrigin, action: SyncAction) -> Result<String, String> {
    let record = active_config()
        .await?
        .ok_or_else(|| "[config] 尚未配置同步，请先在设置中填写连接信息".to_string())?;
    let config = engine_config_of_record(&record)
        .ok_or_else(|| "[config] 当前为本地同步配置，不参与云同步".to_string())?;

    let crypto = runtime_crypto()?;
    if !crypto.is_unlocked() {
        return Err("[not_unlocked] 同步加密未解锁，请先输入同步密码".to_string());
    }

    let engine = runtime_engine()?;
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let attachments = attachments_dir(&base_dir);
    let device_id = context::get_device_id().unwrap_or_default().to_string();

    let result = match action {
        SyncAction::Now => {
            cloud_sync_api::sync_now(&engine, &config, origin, &device_id, &attachments).await
        }
        SyncAction::PushOnly => {
            cloud_sync_api::push_only(&engine, &config, origin, &device_id, &attachments).await
        }
        SyncAction::PullThenPush => {
            cloud_sync_api::pull_then_push(&engine, &config, origin, &device_id, &attachments).await
        }
    }
    .map_err(err_tagged_cloud)?;

    // F24：last_synced_at 由 core 引擎漏斗按「干净轮次」判据回写，桥层不记账
    cloud_sync_api::result_to_json(&result).map_err(err_tagged_cloud)
}

/// 完整同步（Pull → Push + 附件）——「立即同步」唯一入口；忙时返回 skipped 结果
///
/// 对齐桌面 `cloud_sync_now`；返回 SyncResult 的 JSON 字符串。
pub async fn cloud_sync_now(origin: String) -> Result<String, String> {
    run_sync(parse_origin(&origin), SyncAction::Now).await
}

/// 仅 Push（修改后立即同步场景预留）
///
/// 对齐桌面 `cloud_sync_push_only`。
pub async fn cloud_sync_push_only(origin: String) -> Result<String, String> {
    run_sync(parse_origin(&origin), SyncAction::PushOnly).await
}

/// 先 Pull 再 Push（启动场景预留）
///
/// 对齐桌面 `cloud_sync_pull_then_push`。
pub async fn cloud_sync_pull_then_push(origin: String) -> Result<String, String> {
    run_sync(parse_origin(&origin), SyncAction::PullThenPush).await
}

/// 强制同步（进入 / 退出应用专用，对齐桌面 `cloud_sync_force`）
///
/// 与 `cloud_sync_now` 的差别只在前提判定：不检查自动同步开关/间隔，
/// 是否该同步由调用方（生命周期钩子）判定。引擎忙时最多等待
/// `wait_for_idle_ms` 毫秒再执行；返回 SyncResult 的 JSON 字符串。
pub async fn cloud_sync_force(origin: String, wait_for_idle_ms: u64) -> Result<String, String> {
    let record = active_config()
        .await?
        .ok_or_else(|| "[config] 尚未配置同步，请先在设置中填写连接信息".to_string())?;
    let config = engine_config_of_record(&record)
        .ok_or_else(|| "[config] 当前为本地同步配置，不参与云同步".to_string())?;

    let crypto = runtime_crypto()?;
    if !crypto.is_unlocked() {
        return Err("[not_unlocked] 同步加密未解锁，请先输入同步密码".to_string());
    }

    let engine = runtime_engine()?;
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let attachments = attachments_dir(&base_dir);
    let device_id = context::get_device_id().unwrap_or_default().to_string();

    let result = cloud_sync_api::force_sync(
        &engine,
        &config,
        parse_origin(&origin),
        &device_id,
        &attachments,
        wait_for_idle_ms,
    )
    .await
    .map_err(err_tagged_cloud)?;

    cloud_sync_api::result_to_json(&result).map_err(err_tagged_cloud)
}

/// 本地同步状态账本（sync_state.json；指纹元数据，不含业务数据）
///
/// 对齐桌面 `cloud_sync_get_state`；返回 SyncState 的 JSON 字符串。
pub async fn cloud_sync_get_state() -> Result<String, String> {
    let engine = runtime_engine()?;
    let state = cloud_sync_api::get_state(&engine).map_err(err_tagged_cloud)?;
    cloud_sync_api::state_to_json(&state).map_err(err_tagged_cloud)
}

/// 是否有同步任务正在运行
///
/// 对齐桌面 `cloud_sync_is_running`。
pub async fn cloud_sync_is_running() -> Result<bool, String> {
    let engine = runtime_engine()?;
    Ok(cloud_sync_api::is_running(&engine))
}

/// 增量同步历史行（镜像 orbit_core::models::business::SyncHistory）
///
/// 只读聚合（sync_history 表），不 emit 事件、不进同步白名单。
#[derive(Debug, Clone, Serialize)]
pub struct SyncHistoryView {
    pub id: i64,
    /// sync_now / push_only / pull_then_push
    pub sync_type: String,
    /// success / failed / conflict 等
    pub status: String,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub pulled_count: i64,
    pub pushed_count: i64,
    pub conflict_count: i64,
    pub error_message: Option<String>,
}

impl From<orbit_core::models::business::SyncHistory> for SyncHistoryView {
    fn from(h: orbit_core::models::business::SyncHistory) -> Self {
        Self {
            id: h.id,
            sync_type: h.sync_type,
            status: h.status,
            started_at: h.started_at,
            finished_at: h.finished_at,
            pulled_count: h.pulled_count,
            pushed_count: h.pushed_count,
            conflict_count: h.conflict_count,
            error_message: h.error_message,
        }
    }
}

/// 查询增量同步历史（P1-17 展示面；设置页「同步历史」卡数据源）
///
/// `scope`：all | incremental | push_only | pull_only（口径见 core API 文档）；
/// 只读聚合不 emit 事件；limit 由前端夹紧（1..=200）。
///
/// 对齐桌面 `cloud_sync_history`。
pub async fn cloud_sync_history(scope: String, limit: i64) -> Result<Vec<SyncHistoryView>, String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    cloud_sync_api::incremental_history(&pool, &scope, limit.clamp(1, 200))
        .await
        .map_err(err_tagged_cloud)
        .map(|rows| rows.into_iter().map(SyncHistoryView::from).collect())
}

/// 断开云同步：软删激活配置 + 清空本地指纹账本（下次配置后触发全量重推）
///
/// 对齐桌面 `sync_disconnect`。不删除云端数据与本地 crypto meta
/// （Data Key 保留，重新接入同一路径可续用）。
/// 差异：emit("sync-config-changed") 不广播，Dart 调用成功后自行刷新。
pub async fn sync_disconnect() -> Result<(), String> {
    let pool = with_state(|s| Ok(s.pool.clone()))?;
    let repo = SyncConfigRepo::new(pool);
    if let Some(r) = active_config().await? {
        repo.soft_delete_config(r.id)
            .await
            .map_err(|e| format!("[database] 断开失败: {e}"))?;
    }
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    SyncStateStore::new(&base_dir)
        .clear()
        .map_err(|e| format!("[other] 清空同步状态失败: {e}"))?;
    Ok(())
}

// ============================================================================
// 同步加密命令组（对应桌面 sync_crypto_cmd.rs）
// ============================================================================

/// 同步加密状态查询载荷（镜像桌面 sync_crypto_cmd::SyncCryptoStatus）
#[derive(Debug, Clone, Serialize)]
pub struct SyncCryptoStatus {
    pub has_password: bool,
    pub is_unlocked: bool,
}

/// 会话缓存同步密码并挂载到已创建的引擎（对齐桌面 attach_password_to_engine +
/// cache_sync_password；keyring 降级为进程内会话缓存，见模块注释）
fn attach_password_to_runtime(password: &str) {
    let _ = with_runtime(|rt| {
        rt.session_password = Some(password.to_string());
        if let Some(engine) = rt.engine.as_ref() {
            engine.set_sync_password(password.to_string());
        }
        Ok(())
    });
}

/// 清除会话密码缓存并从引擎卸载（对齐桌面 clear_cached_sync_password +
/// engine.clear_sync_password）
fn detach_password_from_runtime() {
    let _ = with_runtime(|rt| {
        rt.session_password = None;
        if let Some(engine) = rt.engine.as_ref() {
            engine.clear_sync_password();
        }
        Ok(())
    });
}

/// 同步加密状态查询（设置页状态卡数据源）
///
/// 对齐桌面 `sync_crypto_status`。
pub async fn sync_crypto_status() -> Result<SyncCryptoStatus, String> {
    let svc = runtime_crypto()?;
    Ok(SyncCryptoStatus {
        has_password: svc.has_sync_password(),
        is_unlocked: svc.is_unlocked(),
    })
}

/// 本机密钥方案版本（"v1" | "v2"；未设置密码返回 null）
///
/// 对齐桌面 `sync_crypto_meta_version`；设置页/恢复页据此显示 v1→v2 迁移入口。
pub async fn sync_crypto_meta_version() -> Result<Option<String>, String> {
    let svc = runtime_crypto()?;
    svc.meta_version().map_err(err_tagged_crypto)
}

/// v1 → v2 密钥方案迁移（同密码确定性派生 + 云端全量重传；UI 二次确认后调用）
///
/// 对齐桌面 `sync_crypto_upgrade_v2`。迁移后所有设备输入同一密码即可同步。
pub async fn sync_crypto_upgrade_v2(sync_password: String) -> Result<(), String> {
    let svc = runtime_crypto()?;
    if !svc.has_sync_password() {
        return Err("[not_initialized] 尚未设置同步密码".to_string());
    }
    let record = active_config()
        .await?
        .ok_or_else(|| "[config] 迁移需要重传云端数据：尚未配置云同步".to_string())?;
    let config = engine_config_of_record(&record)
        .ok_or_else(|| "[config] 迁移需要重传云端数据：当前为本地同步配置".to_string())?;

    svc.upgrade_to_v2(&sync_password)
        .map_err(err_tagged_crypto)?;
    attach_password_to_runtime(&sync_password);

    let engine = runtime_engine()?;
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let attachments = attachments_dir(&base_dir);
    let device_id = context::get_device_id().unwrap_or_default().to_string();

    match cloud_sync_api::rekey_cloud(
        &engine,
        &config,
        SyncOrigin::Manual,
        &device_id,
        &attachments,
    )
    .await
    {
        Ok(_) => Ok(()),
        Err(e) => Err(format!(
            "[{}] 本机已升级 v2，但云端全量重传失败：下次「立即同步」将自动重试；\
             其他设备在此期间请勿同步",
            e.category_tag(),
        )),
    }
}

/// rekey 全量重传：用当前 Data Key 重加密覆盖云端（恢复「以本机为准」）
///
/// 对齐桌面 `cloud_sync_rekey`。危险操作，UI 必须二次确认后调用。
pub async fn cloud_sync_rekey() -> Result<String, String> {
    let record = active_config()
        .await?
        .ok_or_else(|| "[config] 尚未配置同步，请先在设置中填写连接信息".to_string())?;
    let config = engine_config_of_record(&record)
        .ok_or_else(|| "[config] 当前为本地同步配置，不参与云同步".to_string())?;

    let crypto = runtime_crypto()?;
    if !crypto.is_unlocked() {
        return Err("[not_unlocked] 同步加密未解锁，请先输入同步密码".to_string());
    }

    let engine = runtime_engine()?;
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let attachments = attachments_dir(&base_dir);
    let device_id = context::get_device_id().unwrap_or_default().to_string();

    let result = cloud_sync_api::rekey_cloud(
        &engine,
        &config,
        SyncOrigin::Manual,
        &device_id,
        &attachments,
    )
    .await
    .map_err(err_tagged_cloud)?;

    cloud_sync_api::result_to_json(&result).map_err(err_tagged_cloud)
}

/// 首次设置同步密码（生成 Data Key 并持久化 meta；成功即解锁）
///
/// 对齐桌面 `sync_crypto_init`。`remember` 仅保留参数面对齐：移动端无系统
/// 凭据库，缓存退化为进程内会话缓存，重启后需重输。
pub async fn sync_crypto_init(password: String, remember: bool) -> Result<(), String> {
    let _ = remember; // v1 无持久缓存，仅会话缓存（下方统一写入槽位）
    let svc = runtime_crypto()?;
    svc.init(&password).map_err(err_tagged_crypto)?;
    attach_password_to_runtime(&password);
    Ok(())
}

/// 解锁同步加密（验证密码并将 Data Key 载入内存）
///
/// 对齐桌面 `sync_crypto_unlock`；remember 语义同 [sync_crypto_init]。
pub async fn sync_crypto_unlock(password: String, remember: bool) -> Result<(), String> {
    let _ = remember;
    let svc = runtime_crypto()?;
    svc.unlock(&password).map_err(err_tagged_crypto)?;
    attach_password_to_runtime(&password);
    Ok(())
}

/// 锁定同步加密（清除内存 Data Key 与会话密码缓存）
///
/// 对齐桌面 `sync_crypto_lock`。差异：无钥匙串缓存可保留，会话内一并清除。
pub async fn sync_crypto_lock() -> Result<(), String> {
    let svc = runtime_crypto()?;
    svc.lock();
    detach_password_from_runtime();
    Ok(())
}

/// 修改同步密码
///
/// 对齐桌面 `sync_crypto_change_password`。v2 密钥方案下改密即换 Key，
/// 命令内部编排云端全量重传（rekey），失败回滚本机密码；无激活云同步配置时
/// v2 改密报错（重传无处执行）。
pub async fn sync_crypto_change_password(
    old_password: String,
    new_password: String,
) -> Result<(), String> {
    let svc = runtime_crypto()?;
    let is_v2 = svc
        .meta_version()
        .map(|v| v.as_deref() == Some(KEY_DERIVATION_V2))
        .map_err(err_tagged_crypto)?
        && svc.has_sync_password();

    // v1：只换包装（Key 不变），与桌面命令一致
    if !is_v2 {
        svc.change_sync_password(&old_password, &new_password)
            .map_err(err_tagged_crypto)?;
        attach_password_to_runtime(&new_password);
        return Ok(());
    }

    // v2：改密 → rekey 全量重传 → 失败回滚
    let record = active_config()
        .await?
        .ok_or_else(|| "[config] v2 改密需要重传云端数据：尚未配置云同步".to_string())?;
    let config = engine_config_of_record(&record)
        .ok_or_else(|| "[config] v2 改密需要重传云端数据：当前为本地同步配置".to_string())?;

    svc.change_sync_password(&old_password, &new_password)
        .map_err(err_tagged_crypto)?;
    attach_password_to_runtime(&new_password);

    let engine = runtime_engine()?;
    let base_dir = with_state(|s| Ok(s.base_dir.clone()))?;
    let attachments = attachments_dir(&base_dir);
    let device_id = context::get_device_id().unwrap_or_default().to_string();

    if let Err(e) = cloud_sync_api::rekey_cloud(
        &engine,
        &config,
        SyncOrigin::Manual,
        &device_id,
        &attachments,
    )
    .await
    {
        // 回滚本机密码（恢复旧 Key 与云端一致）
        if let Err(rb) = svc.change_sync_password(&new_password, &old_password) {
            eprintln!("[sync-crypto] v2 改密回滚失败: {rb}");
        } else {
            attach_password_to_runtime(&old_password);
        }
        return Err(format!(
            "[{}] v2 改密后全量重传失败，已回滚本机密码：{}",
            e.category_tag(),
            e
        ));
    }
    Ok(())
}

/// 导出 crypto bundle（跨设备 Data Key 分发的本地侧载体）
///
/// 对齐桌面 `sync_crypto_export_bundle`；返回 SyncCryptoMeta 的 JSON 字符串
/// （避免跨 crate 结构体直接过 FRB），Dart 侧透传给 [sync_crypto_import_bundle]。
pub async fn sync_crypto_export_bundle() -> Result<String, String> {
    let svc = runtime_crypto()?;
    let bundle = svc.export_crypto_bundle().map_err(err_tagged_crypto)?;
    serde_json::to_string(&bundle).map_err(|e| format!("[other] bundle 序列化失败: {e}"))
}

/// 导入手动提供的 crypto bundle（JSON 字符串，字段同 core SyncCryptoMeta）
///
/// 对齐桌面 `sync_crypto_import_bundle`。返回 data_key 的 base64；
/// `[local_meta_exists]` 前缀表示 Fix-10 守卫拒绝，前端确认后以 force=true 重试。
pub async fn sync_crypto_import_bundle(
    bundle_json: String,
    password: String,
    force: bool,
) -> Result<String, String> {
    let bundle: SyncCryptoMeta = serde_json::from_str(&bundle_json)
        .map_err(|e| format!("[invalid_input] bundle 解析失败: {e}"))?;
    let svc = runtime_crypto()?;
    svc.import_crypto_bundle(&bundle, &password, force)
        .map_err(err_tagged_crypto)?;
    attach_password_to_runtime(&password);
    // 服务刚导入成功、Data Key 已在内存，直接取 base64（与桌面 BASE64.encode 等价）
    Ok(svc.get_data_key_base64().unwrap_or_default())
}

/// 启动静默恢复会话：尝试用缓存的同步密码解锁
///
/// 对齐桌面 `sync_crypto_restore_session`。移动端 keyring 降级：无跨重启的
/// 持久缓存（会话密码随 lock 一并清除），故除「本就已解锁」外恒返回 false，
/// Dart 侧引导用户手动输入。
pub async fn sync_crypto_restore_session() -> Result<bool, String> {
    let svc = runtime_crypto()?;
    if !svc.has_sync_password() || svc.is_unlocked() {
        return Ok(svc.is_unlocked());
    }
    Ok(false)
}

/// 忘记本机同步密码：清除会话缓存与引擎挂载（对齐桌面 `sync_crypto_forget_session`；
/// 桌面另清钥匙串，移动端无持久缓存可清）
pub async fn sync_crypto_forget_session() -> Result<(), String> {
    detach_password_from_runtime();
    Ok(())
}
