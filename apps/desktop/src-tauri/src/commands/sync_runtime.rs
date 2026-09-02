//! sync_runtime — M3 同步域壳层运行时（Orbit 裁剪版，06 任务 3.3/3.5）
//!
//! 职责（不含业务逻辑，业务全部在 orbit_core）：
//! - [`SyncRuntime`]：SyncCryptoService / SyncEngine 进程级单例（Tauri managed
//!   state）。Data Key 内存态与引擎互斥锁必须跨命令持久，禁止按命令临时构造。
//! - [`KeyringCekProvider`]：CEK 由系统钥匙串保管（service=`orbit.sync-crypto`，
//!   account=`config-cek`），供全局 EncryptedConfigStorage 加密落盘同步配置。
//! - [`TauriProgressSender`]：cloud_sync ProgressSender → emit("sync-progress")。
//! - 同步密码钥匙串缓存（account=`sync-password`）：解锁成功后缓存，支持下次
//!   启动静默恢复会话；用户主动"忘记密码缓存"时清除。
//! - 错误通道约定：`[tag] message` 前缀字符串，前端按 tag 路由
//!   （key_mismatch → 恢复页 / wrong_password → 解锁 / local_meta_exists → 确认覆盖）。

use std::path::Path;
use std::sync::{Arc, OnceLock};

#[cfg(desktop)]
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::engine::SyncEngine;
use orbit_core::cloud_sync::progress::{ProgressSender, SyncProgress};
#[cfg(desktop)]
use orbit_core::config_enc::cek::generate_cek;
use orbit_core::config_enc::cek::{CEK_LEN, CekProvider};
use orbit_core::config_enc::error::ConfigEncError;
use orbit_core::context;
use orbit_core::db::repository::sync_config_repo::SyncConfigRepo;
use orbit_core::models::sync_config::SyncConfigRecord;
use orbit_core::sync_crypto::SyncCryptoService;
use tauri::{AppHandle, Emitter, Manager};

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;

/// 钥匙串 service 名（03 文档 §七：service=orbit.sync-crypto）
#[cfg(desktop)]
const KEYRING_SERVICE: &str = "orbit.sync-crypto";
/// CEK 在钥匙串中的条目名
#[cfg(desktop)]
const KEYRING_CEK_ACCOUNT: &str = "config-cek";
/// 同步密码在钥匙串中的条目名
#[cfg(desktop)]
const KEYRING_PASSWORD_ACCOUNT: &str = "sync-password";

// ============================================================================
// 单例运行时
// ============================================================================

/// 同步域进程级单例（setup 阶段 manage，此后只读）
#[derive(Default)]
pub struct SyncRuntime {
    crypto: OnceLock<SyncCryptoService>,
    engine: OnceLock<SyncEngine>,
}

impl SyncRuntime {
    pub fn engine_get(&self) -> Option<&SyncEngine> {
        self.engine.get()
    }
}

/// 取同步加密服务单例（懒初始化；仅数据目录解析失败时报错）
pub fn sync_crypto(app: &AppHandle) -> Result<SyncCryptoService, String> {
    let runtime = app.state::<SyncRuntime>();
    if let Some(svc) = runtime.crypto.get() {
        return Ok(svc.clone());
    }
    let dir = resolve_app_data_dir(app)?;
    let svc = SyncCryptoService::new(&dir);
    // 并发竞争时以先写入者为准（OnceLock 语义）
    Ok(runtime.crypto.get_or_init(|| svc).clone())
}

/// 取同步引擎单例（懒初始化；依赖 AppState 连接池已就绪）
pub fn sync_engine(app: &AppHandle) -> Result<SyncEngine, String> {
    let runtime = app.state::<SyncRuntime>();
    if let Some(engine) = runtime.engine.get() {
        return Ok(engine.clone());
    }
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let crypto = sync_crypto(app)?;
    let dir = resolve_app_data_dir(app)?;
    let sender = Arc::new(TauriProgressSender { app: app.clone() });
    let engine = cloud_sync_api::create_engine(pool, crypto.clone(), &dir, sender);
    // 引擎懒创建晚于解锁的场景（如设置密码后才首次触发云同步命令）：
    // 从钥匙串缓存回填同步密码，否则引擎内"同步前自动备份"会静默跳过
    if crypto.is_unlocked()
        && let Some(password) = read_cached_sync_password()
    {
        engine.set_sync_password(password);
    }
    Ok(runtime.engine.get_or_init(|| engine).clone())
}

// ============================================================================
// 进度事件桥
// ============================================================================

/// ProgressSender 的 Tauri 实现：emit("sync-progress", tagged JSON)
///
/// `SyncProgress` 带 `#[serde(tag="phase")]` 且全字段 Serialize，直接 emit 即为
/// 前端友好的 tagged JSON；发送失败静默忽略（trait 契约：不阻塞同步主流程）。
struct TauriProgressSender {
    app: AppHandle,
}

impl ProgressSender for TauriProgressSender {
    fn send(&self, progress: SyncProgress) {
        let _ = self.app.emit("sync-progress", &progress);
    }
}

// ============================================================================
// CEK 提供者（桌面系统钥匙串保管；移动端无凭据库 → 明文降级）
// ============================================================================

/// CEK 提供者：32B 随机密钥存于 OS 钥匙串（桌面），首次访问自动生成；
/// 移动端无系统凭据库，上报不可用由上层走明文降级
pub struct KeyringCekProvider;

impl CekProvider for KeyringCekProvider {
    /// 桌面端：CEK 存钥匙串 service=orbit.sync-crypto / account=config-cek
    #[cfg(desktop)]
    fn get_or_create(&self) -> Result<[u8; CEK_LEN], ConfigEncError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_CEK_ACCOUNT)
            .map_err(|e| ConfigEncError::CekUnavailable(format!("钥匙串不可用: {e}")))?;

        match entry.get_password() {
            Ok(b64) => {
                let bytes = BASE64
                    .decode(b64)
                    .map_err(|e| ConfigEncError::Corrupted(format!("CEK 解码失败: {e}")))?;
                let len = bytes.len();
                match bytes.try_into() {
                    Ok(cek) => Ok(cek),
                    Err(_) => Err(ConfigEncError::Corrupted(format!(
                        "CEK 长度异常: {len} != {CEK_LEN}"
                    ))),
                }
            }
            Err(keyring::Error::NoEntry) => {
                // 首次：生成并写入钥匙串
                let cek = generate_cek();
                entry
                    .set_password(&BASE64.encode(cek))
                    .map_err(|e| ConfigEncError::CekUnavailable(format!("CEK 写入失败: {e}")))?;
                Ok(cek)
            }
            Err(e) => Err(ConfigEncError::CekUnavailable(format!("CEK 读取失败: {e}"))),
        }
    }

    /// 移动端：无持久凭据库，CEK 永远不可用（配置存储自动降级，不 panic）
    #[cfg(not(desktop))]
    fn get_or_create(&self) -> Result<[u8; CEK_LEN], ConfigEncError> {
        Err(ConfigEncError::CekUnavailable(
            "移动端无系统凭据库，CEK 不可用".to_string(),
        ))
    }

    #[cfg(desktop)]
    fn is_available(&self) -> bool {
        keyring::Entry::new(KEYRING_SERVICE, KEYRING_CEK_ACCOUNT)
            .map(|entry| matches!(entry.get_password(), Ok(_) | Err(keyring::Error::NoEntry)))
            .unwrap_or(false)
    }

    /// 移动端恒不可用（启动诊断据此降级明文）
    #[cfg(not(desktop))]
    fn is_available(&self) -> bool {
        false
    }
}

/// 注册全局加密配置存储（lib.rs setup 早期调用一次）
///
/// 注册后 orbit_core 内部（备份 device_name 读取等）自动走"加密优先、明文降级"。
pub fn register_global_encrypted_storage(app: &AppHandle) -> Result<(), String> {
    let dir = resolve_app_data_dir(app)?;
    let storage = orbit_core::config_enc::storage::EncryptedConfigStorage::new(
        Arc::new(KeyringCekProvider),
        dir,
    );
    let _ = orbit_core::config_enc::registry::set_global_storage(storage);
    Ok(())
}

// ============================================================================
// 同步密码钥匙串缓存（session 恢复；移动端无持久缓存，会话内有效）
// ============================================================================

/// 同步密码钥匙串条目（service=orbit.sync-crypto / account=sync-password）
#[cfg(desktop)]
fn password_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_PASSWORD_ACCOUNT)
        .map_err(|e| format!("[other] 钥匙串不可用: {e}"))
}

/// 缓存同步密码到钥匙串（解锁成功后调用；失败仅告警不阻断）
#[cfg(desktop)]
pub fn cache_sync_password(password: &str) {
    match password_entry().and_then(|e| e.set_password(password).map_err(|e| e.to_string())) {
        Ok(()) => {}
        Err(e) => eprintln!("[sync-runtime] 同步密码缓存失败（不影响本次会话）: {e}"),
    }
}

/// 移动端：无系统凭据库，不做持久缓存（静默跳过；重启后需重输同步密码）
#[cfg(not(desktop))]
pub fn cache_sync_password(_password: &str) {}

/// 清除钥匙串中的同步密码缓存（尽力而为）
#[cfg(desktop)]
pub fn clear_cached_sync_password() {
    if let Ok(entry) = password_entry() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(e) => eprintln!("[sync-runtime] 同步密码缓存清除失败: {e}"),
        }
    }
}

/// 移动端：无缓存可清（静默跳过）
#[cfg(not(desktop))]
pub fn clear_cached_sync_password() {}

/// 读取缓存的同步密码（无缓存返回 None）
#[cfg(desktop)]
pub fn read_cached_sync_password() -> Option<String> {
    let entry = password_entry().ok()?;
    match entry.get_password() {
        Ok(pw) => Some(pw),
        Err(keyring::Error::NoEntry) => None,
        Err(e) => {
            eprintln!("[sync-runtime] 同步密码缓存读取失败: {e}");
            None
        }
    }
}

/// 移动端：无持久缓存（读恒未命中）
#[cfg(not(desktop))]
pub fn read_cached_sync_password() -> Option<String> {
    None
}

// ============================================================================
// 配置读取与引擎配置转换（配置双存储的 DB 侧）
// ============================================================================

/// 读取激活的同步配置记录（未配置返回 None）
pub async fn get_active_config(app: &AppHandle) -> Result<Option<SyncConfigRecord>, String> {
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

/// 将 DB 记录转换为引擎配置（桌面语义，不复用移动端遗留映射）
///
/// 与 full_sync_backup_api::engine_config_from_record 的差异：
/// access_key/secret_key 直接取 credential 语义对（WebDAV 用户名/S3 AK 存
/// record.device_id 列——沿袭 wait-home 移动端列复用约定），device_id 取进程上下文。
pub fn engine_config_of_record(
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

/// 附件目录占位（MVP：todos has_attachments=false，仅满足引擎签名）
pub fn attachments_dir(dir: &Path) -> String {
    dir.join("attachments").to_string_lossy().to_string()
}
