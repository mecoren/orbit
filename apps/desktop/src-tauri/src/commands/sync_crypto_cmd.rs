//! sync_crypto_cmd — 同步密码 / Data Key 命令组（06 任务 3.3）
//!
//! 一比一包装 orbit_core::sync_crypto::SyncCryptoService 单例；
//! unlock 成功后联动 engine.set_sync_password（同步前自动备份依赖），
//! lock 时 clear_sync_password。错误统一 `[tag] message` 前缀字符串。

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use orbit_core::cloud_sync::engine::SyncEngine;
use orbit_core::cloud_sync::progress::SyncOrigin;
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

/// 查询本机密钥方案版本（"v1" | "v2"；未设置密码返回 null）
///
/// 设置页/恢复页据此显示 v1→v2 迁移入口。
#[derive(serde::Serialize)]
pub struct SyncCryptoVersion {
    pub version: Option<String>,
}

#[tauri::command]
pub async fn sync_crypto_meta_version(app: AppHandle) -> Result<SyncCryptoVersion, String> {
    let svc = sync_runtime::sync_crypto(&app)?;
    let version = svc.meta_version().map_err(err_tagged)?;
    Ok(SyncCryptoVersion { version })
}

/// 首次设置同步密码（生成 Data Key 并持久化 meta；成功即解锁）
///
/// remember=true 时同时缓存到系统钥匙串（service=orbit.sync-crypto）。
#[tauri::command]
pub async fn sync_crypto_init(
    app: AppHandle,
    password: String,
    remember: bool,
) -> Result<(), String> {
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
pub async fn sync_crypto_unlock(
    app: AppHandle,
    password: String,
    remember: bool,
) -> Result<(), String> {
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

/// 修改同步密码
///
/// - v1 meta：只换包装不换 Data Key（云端数据不受影响，无需重传）
/// - v2 meta：改密即换 Key——本命令内部编排 rekey 全量重传（云端旧密码 Key
///   密文全部用新 Key 重加密覆盖 + 上传新 config），失败时回滚本机 meta
///   到旧密码（保持本机与云端一致，用户可重试）。
///   无激活同步配置时返回错误（重传无处执行）。
#[tauri::command]
pub async fn sync_crypto_change_password(
    app: AppHandle,
    old_password: String,
    new_password: String,
) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;

    // v2 判定需在改密前读取 meta
    let is_v2 = svc
        .meta_version()
        .map(|v| v.as_deref() == Some(orbit_core::sync_crypto::KEY_DERIVATION_V2))
        .unwrap_or(false);

    // v1：本机改包装即可（Key 不变）
    if !is_v2 {
        svc.change_sync_password(&old_password, &new_password)
            .map_err(err_tagged)?;
        attach_password_to_engine(&app, &new_password);
        sync_runtime::cache_sync_password(&new_password);
        return Ok(());
    }

    // v2：改密 → rekey 全量重传 → 失败回滚
    let record = sync_runtime::get_active_config(&app)
        .await?
        .ok_or_else(|| {
            "[config] v2 改密需要重传云端数据：尚未配置云同步，请先配置连接信息".to_string()
        })?;
    let config = sync_runtime::engine_config_of_record(&record)
        .ok_or_else(|| "[config] v2 改密需要重传云端数据：当前为本地同步配置".to_string())?;
    let engine = sync_runtime::sync_engine(&app)?;

    svc.change_sync_password(&old_password, &new_password)
        .map_err(err_tagged)?;
    attach_password_to_engine(&app, &new_password);

    let dir = crate::commands::data_dir::resolve_app_data_dir(&app)?;
    let attachments = sync_runtime::attachments_dir(&dir);
    let device_id = orbit_core::context::get_device_id()
        .unwrap_or_default()
        .to_string();

    if let Err(e) = orbit_core::api::cloud_sync_api::rekey_cloud(
        &engine,
        &config,
        SyncOrigin::Manual,
        &device_id,
        &attachments,
    )
    .await
    {
        // 回滚本机 meta 到旧密码（改密内部会重新包装/派生，回滚即恢复旧 Key）
        let rollback = svc.change_sync_password(&new_password, &old_password);
        if let Err(rb) = rollback {
            eprintln!(
                "[sync-crypto] v2 改密回滚失败（本机与云端 Key 可能不一致，\
                 建议在恢复页「以本机为准」重置云端）: {rb}"
            );
        } else {
            attach_password_to_engine(&app, &old_password);
        }
        return Err(format!(
            "[{}] v2 改密后全量重传失败，已回滚本机密码：{}",
            e.category_tag(),
            e
        ));
    }

    sync_runtime::cache_sync_password(&new_password);
    Ok(())
}

/// v1 → v2 密钥方案迁移（一次性，危险操作，UI 二次确认后调用）
///
/// 流程：验证旧密码 → 前置 rekey 前先确认云端可达（用 v1 Key 正常 pull 一次
/// 可选）→ 升级本机 meta 到 v2（同密码确定性派生）→ rekey 全量重传。
///
/// 迁移后：本机与所有其他设备输入**同一密码**即可同步（不再需要 bundle 分发）。
/// 失败处理：meta 已写 v2 但重传失败时，本机新 Key 与云端 v1 Key 不一致——
/// 回滚 v1 meta 需要旧密码重新包装原 Key，此处直接回滚并提示重试。
#[tauri::command]
pub async fn sync_crypto_upgrade_v2(app: AppHandle, sync_password: String) -> Result<(), String> {
    let svc = sync_runtime::sync_crypto(&app)?;

    if svc
        .meta_version()
        .map(|v| v.as_deref() == Some(orbit_core::sync_crypto::KEY_DERIVATION_V2))
        .unwrap_or(false)
    {
        return Err("[sync_crypto] 当前已是 v2 密钥方案，无需迁移".to_string());
    }
    if !svc.has_sync_password() {
        return Err("[not_initialized] 尚未设置同步密码".to_string());
    }

    let record = sync_runtime::get_active_config(&app)
        .await?
        .ok_or_else(|| "[config] 迁移需要重传云端数据：尚未配置云同步".to_string())?;
    let config = sync_runtime::engine_config_of_record(&record)
        .ok_or_else(|| "[config] 迁移需要重传云端数据：当前为本地同步配置".to_string())?;

    // 验证密码并升级本机 meta 到 v2
    svc.upgrade_to_v2(&sync_password).map_err(err_tagged)?;
    attach_password_to_engine(&app, &sync_password);

    let engine = sync_runtime::sync_engine(&app)?;
    let dir = crate::commands::data_dir::resolve_app_data_dir(&app)?;
    let attachments = sync_runtime::attachments_dir(&dir);
    let device_id = orbit_core::context::get_device_id()
        .unwrap_or_default()
        .to_string();

    match orbit_core::api::cloud_sync_api::rekey_cloud(
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
            "[{}] 本机已升级 v2，但云端全量重传失败：下次「立即同步」将自动重试重传；\
             其他设备在此期间请勿同步",
            e.category_tag(),
        )),
    }
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
