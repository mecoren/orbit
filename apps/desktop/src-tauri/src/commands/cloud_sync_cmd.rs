//! cloud_sync_cmd — 云端增量同步执行命令组（06 任务 3.5）
//!
//! 全部走 orbit_core::api::cloud_sync_api 高阶函数（BasePathAdapter、重试退避、
//! Data Key 对账守卫均在 core 内闭环）；壳层只做：引擎/配置获取 → 执行 →
//! last_synced_at 记账 → 错误 `[category] message` 前缀化。

use tauri::{AppHandle, Emitter, Manager};

use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::db::repository::sync_config_repo::SyncConfigRepo;

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;
use crate::commands::sync_runtime;

/// CloudSyncError → `[tag] message`（key_mismatch 前端跳恢复页）
fn err_tagged(e: orbit_core::cloud_sync::error::CloudSyncError) -> String {
    format!("[{}] {}", e.category_tag(), e)
}

/// 解析 origin 字符串（前端传 "manual" | "background" | "exit"）
fn parse_origin(origin: &str) -> SyncOrigin {
    match origin {
        "background" => SyncOrigin::Background,
        "exit" => SyncOrigin::Exit,
        _ => SyncOrigin::Manual,
    }
}

enum SyncAction {
    Now,
    PushOnly,
    PullThenPush,
}

/// 同步执行公共骨架：配置 + 引擎 + 附件目录 → 动作 → last_synced_at 记账
async fn run_sync(
    app: &AppHandle,
    origin: SyncOrigin,
    action: SyncAction,
) -> Result<String, String> {
    let record = sync_runtime::get_active_config(app)
        .await?
        .ok_or_else(|| "[config] 尚未配置同步，请先在设置中填写连接信息".to_string())?;
    let config = sync_runtime::engine_config_of_record(&record)
        .ok_or_else(|| "[config] 当前为本地同步配置，不参与云同步".to_string())?;

    let engine = sync_runtime::sync_engine(app)?;
    let crypto = sync_runtime::sync_crypto(app)?;
    if !crypto.is_unlocked() {
        return Err("[not_unlocked] 同步加密未解锁，请先输入同步密码".to_string());
    }

    let dir = resolve_app_data_dir(app)?;
    let attachments = sync_runtime::attachments_dir(&dir);
    let device_id = orbit_core::context::get_device_id()
        .unwrap_or_default()
        .to_string();

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
    .map_err(err_tagged)?;

    // 成功（含 skipped）后记账 last_synced_at 并通知前端刷新
    let now_ms = chrono::Utc::now().timestamp_millis();
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let _ = SyncConfigRepo::new(pool)
        .update_last_synced_at(record.id, now_ms)
        .await;

    app.emit("sync-finished", &result)
        .map_err(|e| format!("[other] 事件发送失败: {e}"))?;

    cloud_sync_api::result_to_json(&result).map_err(err_tagged)
}

/// 完整同步（Pull → Push + 附件）——「立即同步」唯一入口；忙时返回 skipped 结果
#[tauri::command]
pub async fn cloud_sync_now(app: AppHandle, origin: String) -> Result<String, String> {
    run_sync(&app, parse_origin(&origin), SyncAction::Now).await
}

/// 仅 Push（修改后立即同步场景预留）
#[tauri::command]
pub async fn cloud_sync_push_only(app: AppHandle, origin: String) -> Result<String, String> {
    run_sync(&app, parse_origin(&origin), SyncAction::PushOnly).await
}

/// 先 Pull 再 Push（启动场景预留）
#[tauri::command]
pub async fn cloud_sync_pull_then_push(app: AppHandle, origin: String) -> Result<String, String> {
    run_sync(&app, parse_origin(&origin), SyncAction::PullThenPush).await
}

/// rekey 全量重传：用当前 Data Key 重加密覆盖云端（恢复页「以本机为准」）
///
/// 危险操作，UI 必须二次确认后调用。v2 改密与 v1→v2 迁移场景由
/// `sync_crypto_change_password` 内部编排，不经此命令。
#[tauri::command]
pub async fn cloud_sync_rekey(app: AppHandle) -> Result<String, String> {
    let record = sync_runtime::get_active_config(&app)
        .await?
        .ok_or_else(|| "[config] 尚未配置同步，请先在设置中填写连接信息".to_string())?;
    let config = sync_runtime::engine_config_of_record(&record)
        .ok_or_else(|| "[config] 当前为本地同步配置，不参与云同步".to_string())?;

    let engine = sync_runtime::sync_engine(&app)?;
    let crypto = sync_runtime::sync_crypto(&app)?;
    if !crypto.is_unlocked() {
        return Err("[not_unlocked] 同步加密未解锁，请先输入同步密码".to_string());
    }

    let dir = resolve_app_data_dir(&app)?;
    let attachments = sync_runtime::attachments_dir(&dir);
    let device_id = orbit_core::context::get_device_id()
        .unwrap_or_default()
        .to_string();

    let result = cloud_sync_api::rekey_cloud(
        &engine,
        &config,
        SyncOrigin::Manual,
        &device_id,
        &attachments,
    )
    .await
    .map_err(err_tagged)?;

    app.emit("sync-finished", &result)
        .map_err(|e| format!("[other] 事件发送失败: {e}"))?;
    cloud_sync_api::result_to_json(&result).map_err(err_tagged)
}

/// 本地同步状态账本（sync_state.json；指纹元数据，不含业务数据）
#[tauri::command]
pub async fn cloud_sync_get_state(app: AppHandle) -> Result<String, String> {
    let engine = sync_runtime::sync_engine(&app)?;
    let state = cloud_sync_api::get_state(&engine).map_err(err_tagged)?;
    cloud_sync_api::state_to_json(&state).map_err(err_tagged)
}

/// 是否有同步任务正在运行
#[tauri::command]
pub async fn cloud_sync_is_running(app: AppHandle) -> Result<bool, String> {
    let engine = sync_runtime::sync_engine(&app)?;
    Ok(cloud_sync_api::is_running(&engine).await)
}

/// 断开云同步：软删激活配置 + 清空本地指纹账本（下次配置后触发全量重推）
///
/// 不删除云端数据与本地 crypto meta（Data Key 保留，重新接入同一路径可续用）。
#[tauri::command]
pub async fn sync_disconnect(app: AppHandle) -> Result<(), String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let repo = SyncConfigRepo::new(pool);
    let record = sync_runtime::get_active_config(&app).await?;
    if let Some(r) = record {
        repo.soft_delete_config(r.id)
            .await
            .map_err(|e| format!("[database] 断开失败: {e}"))?;
    }
    let dir = resolve_app_data_dir(&app)?;
    orbit_core::cloud_sync::state::SyncStateStore::new(&dir)
        .clear()
        .map_err(|e| format!("[other] 清空同步状态失败: {e}"))?;

    app.emit("sync-config-changed", ())
        .map_err(|e| format!("[other] 事件发送失败: {e}"))?;
    Ok(())
}
