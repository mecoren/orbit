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

/// 强制同步（进入 / 退出应用专用）
///
/// 与 `cloud_sync_now` 的差别只在**前提判定**：不检查自动同步开关、同步间隔、
/// 修改后立即同步等设置——「是否该同步」由调用方（生命周期钩子）判定。
/// `wait_for_idle_ms`：引擎忙时最多等待多久再执行（进入 ~3s / 退出 ~15s）。
#[tauri::command]
pub async fn cloud_sync_force(
    app: AppHandle,
    origin: String,
    wait_for_idle_ms: u64,
) -> Result<String, String> {
    let record = sync_runtime::get_active_config(&app)
        .await?
        .ok_or_else(|| "[config] 尚未配置同步".to_string())?;
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

    let result = cloud_sync_api::force_sync(
        &engine,
        &config,
        parse_origin(&origin),
        &device_id,
        &attachments,
        wait_for_idle_ms,
    )
    .await
    .map_err(err_tagged)?;

    // 记账（与 run_sync 同口径；skipped 也记账，表示"本轮已尝试"）
    let now_ms = chrono::Utc::now().timestamp_millis();
    if let Some(state) = app.try_state::<AppState>() {
        let _ = SyncConfigRepo::new(state.pool.clone())
            .update_last_synced_at(record.id, now_ms)
            .await;
    }

    let _ = app.emit("sync-finished", &result);
    cloud_sync_api::result_to_json(&result).map_err(err_tagged)
}

/// 退出前强制同步（阻塞调用方，带超时安全阀）
///
/// ## 为什么阻塞
/// 进程退出后后台协程会被销毁，"不阻塞等于不执行"。因此这里在 Tauri runtime
/// 上 spawn 同步任务，调用线程用 `recv_timeout` 等待：超时即放行退出（网络
/// 异常时不能把退出卡死），超时事实写入日志供诊断。
///
/// 本函数**同步**（不 async）：`quit_app` 运行在托盘菜单的同步回调里，
/// 直接阻塞等待即可，避免在非 runtime 线程上 `block_on` 的嵌套风险。
pub fn run_exit_sync(app: &AppHandle, timeout: std::time::Duration) {
    let (tx, rx) = std::sync::mpsc::channel::<Result<String, String>>();
    let app_for_task = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = cloud_sync_force(app_for_task, "exit".to_string(), 5_000).await;
        let _ = tx.send(result);
    });
    match rx.recv_timeout(timeout) {
        Ok(Ok(_)) => log::info!("[exit-sync] 退出前同步完成"),
        Ok(Err(e)) => log::warn!("[exit-sync] 退出前同步失败（继续退出）: {e}"),
        Err(_) => log::warn!(
            "[exit-sync] 退出前同步超时（{}s），放行退出",
            timeout.as_secs()
        ),
    }
}

/// 查询增量同步历史（P1-17：sync_history 表只读展示）
///
/// `scope`：all | incremental | push_only | pull_only（口径见 core API 文档）；
/// 只读聚合不 emit 事件；limit 由前端夹紧。
#[tauri::command]
pub async fn cloud_sync_history(
    app: AppHandle,
    scope: String,
    limit: i64,
) -> Result<Vec<orbit_core::models::business::SyncHistory>, String> {
    let pool = app
        .state::<crate::AppState>()
        .pool
        .clone();
    let limit = limit.clamp(1, 200);
    cloud_sync_api::incremental_history(&pool, &scope, limit)
        .await
        .map_err(err_tagged)
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
    Ok(cloud_sync_api::is_running(&engine))
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
