//! sync_crypto_cmd — 同步密码 / Data Key 命令组（06 任务 3.3）
//!
//! 一比一包装 orbit_core::sync_crypto::SyncCryptoService 单例；
//! unlock 成功后联动 engine.set_sync_password（同步前自动备份依赖），
//! lock 时 clear_sync_password。错误统一 `[tag] message` 前缀字符串。

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use orbit_core::cloud_sync::engine::SyncEngine;
use orbit_core::sync_crypto::error::SyncCryptoError;
use orbit_core::sync_crypto::meta_store::SyncCryptoMeta;
use tauri::{AppHandle, Manager};

use crate::commands::sync_runtime;

/// SyncCryptoError → `[tag] message`（前端按 tag 路由 UI 分支）
fn err_tagged(e: SyncCryptoError) -> String {
    match &e {
        SyncCryptoError::WrongPassword => format!("[wrong_password] {e}"),
        SyncCryptoError::NotInitialized => format!("[not_initialized] {e}"),
        SyncCryptoError::NotUnlocked => format!("[not_unlocked] {e}"),
        SyncCryptoError::LocalMetaExists => format!("[local_meta_exists] {e}"),
        other => format!("[sync_crypto] {other}"),
    }
}

#[derive(serde::Serialize)]
pub struct SyncCryptoStatus {
    pub has_password: bool,
    pub is_unlocked: bool,
}

/// 同步加密状态查询（设置页状态卡数据源）
#[tauri::command]
pub async fn sync_crypto_status(app: AppHandle) -> Result<SyncCryptoStatus, String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    Ok(SyncCryptoStatus {
        has_password: svc.has_sync_password(),
        is_unlocked: svc.is_unlocked(),
    })
}

/// 首次设置同步密码（生成 Data Key 并持久化 meta；成功即解锁）
///
/// remember=true 时同时缓存到系统钥匙串（service=orbit.sync-crypto）。
#[tauri::command]
pub async fn sync_crypto_init(app: AppHandle, password: String, remember: bool) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    svc.init(&password).map_err(err_tagged)?;
    attach_password_to_engine(&app, &password);
    if remember {
        sync_runtime::cache_sync_password(&password);
    }
    Ok(())
}

/// 解锁同步加密（验证密码并将 Data Key 载入内存）
#[tauri::command]
pub async fn sync_crypto_unlock(app: AppHandle, password: String, remember: bool) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    svc.unlock(&password).map_err(err_tagged)?;
    attach_password_to_engine(&app, &password);
    if remember {
        sync_runtime::cache_sync_password(&password);
    }
    Ok(())
}

/// 锁定同步加密（清除内存 Data Key；钥匙串缓存保留，下次可静默恢复）
#[tauri::command]
pub async fn sync_crypto_lock(app: AppHandle) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    svc.lock();
    if let Some(engine) = engine_opt(&app) {
        engine.clear_sync_password();
    }
    Ok(())
}

/// 修改同步密码（只换包装不换 Data Key）
#[tauri::command]
pub async fn sync_crypto_change_password(
    app: AppHandle,
    old_password: String,
    new_password: String,
) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    svc.change_sync_password(&old_password, &new_password)
        .map_err(err_tagged)?;
    attach_password_to_engine(&app, &new_password);
    sync_runtime::cache_sync_password(&new_password);
    Ok(())
}

/// 轮换 Data Key 并重置云端（完整流程，危险操作，UI 二次确认后调用）
/// 导出 crypto bundle（跨设备 Data Key 分发的本地侧载体）
#[tauri::command]
pub async fn sync_crypto_export_bundle(app: AppHandle) -> Result<SyncCryptoMeta, String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    svc.export_crypto_bundle().map_err(err_tagged)
}

/// 导入手动提供的 crypto bundle
///
/// 返回值：data_key 的 base64。`[local_meta_exists]` 前缀表示 Fix-10 守卫拒绝，
/// 前端确认后以 force=true 重试。
#[tauri::command]
pub async fn sync_crypto_import_bundle(
    app: AppHandle,
    bundle: SyncCryptoMeta,
    password: String,
    force: bool,
) -> Result<String, String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    let key = svc
        .import_crypto_bundle(&bundle, &password, force)
        .map_err(err_tagged)?;
    attach_password_to_engine(&app, &password);
    Ok(BASE64.encode(key))
}

/// 启动静默恢复会话：用钥匙串缓存的同步密码尝试解锁
///
/// 成功返回 true（已解锁并挂载引擎密码）；无缓存/密码已变返回 false。
#[tauri::command]
pub async fn sync_crypto_restore_session(app: AppHandle) -> Result<bool, String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    // 未设置同步密码时无需恢复；已解锁直接成功
    if !svc.has_sync_password() || svc.is_unlocked() {
        return Ok(svc.is_unlocked());
    }
    let Some(password) = sync_runtime::read_cached_sync_password() else {
        return Ok(false);
    };
    match svc.unlock(&password) {
        Ok(_) => {
            attach_password_to_engine(&app, &password);
            Ok(true)
        }
        Err(e) => {
            eprintln!("[sync-crypto] 会话恢复失败（缓存密码可能已失效）: {e}");
            sync_runtime::clear_cached_sync_password();
            Ok(false)
        }
    }
}

/// 清除钥匙串中的同步密码缓存（"忘记此设备的同步密码"）
#[tauri::command]
pub async fn sync_crypto_forget_session() -> Result<(), String> {
    sync_runtime::clear_cached_sync_password();
    Ok(())
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

/// 引擎若已创建则挂载同步密码（同步前自动备份的数据源）
fn attach_password_to_engine(app: &AppHandle, password: &str) {
    if let Some(engine) = engine_opt(app) {
        engine.set_sync_password(password.to_string());
    }
}

fn engine_opt(app: &AppHandle) -> Option<SyncEngine> {
    let rt = app.try_state::<sync_runtime::SyncRuntime>()?;
    rt.engine_get().cloned()
}
