//! sync_scheduler — 定时同步守护（06 任务 3.5，03 文档 §八「引擎与调度」）
//!
//! 60s tick 轮询（与 wait-home 桌面版口径一致）：
//! - DB 未就绪 / 未配置 / 总开关关 / interval=0 → 静默跳过
//! - 同步加密未解锁 → 跳过（CryptoLocked 语义前置）
//! - `距上次自动同步 ≥ sync_interval 分钟` 才触发（LAST_AUTO_SYNC_MS 单调记账）
//! - 引擎忙（is_running）→ 本轮跳过，下轮再试
//! - 触发即调 cloud_sync_api::sync_now(Background)；进度经 TauriProgressSender
//!   emit("sync-progress") 推送；key_mismatch 时 emit("sync-key-mismatch") 引导恢复页

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use tauri::{AppHandle, Emitter, Manager};

use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::context;
use orbit_core::db::repository::sync_config_repo::SyncConfigRepo;

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;
use crate::commands::sync_runtime;

/// tick 周期：60s（03 文档 §八 判据之一）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);
/// 上次自动同步时间戳（ms；0 = 从未同步过 → 立即满足间隔条件）
static LAST_AUTO_SYNC_MS: AtomicU64 = AtomicU64::new(0);

/// 启动定时同步守护（幂等；lib.rs setup 阶段调用）
pub fn sync_scheduler_start(app: AppHandle) {
    if SCHEDULER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        loop {
            tick(&app).await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

// ============================================================================
// 修改后立即同步（sync_on_change）
// ============================================================================

/// 启动 on-change 监听任务（幂等由 AtomicBool 保证；lib.rs setup 调用）
///
/// 订阅 EVENT_BUS 业务变更事件：5s 防抖合并连续编辑后，若配置开启
/// sync_on_change 且已解锁 → push_only(Background)。pull 合并产生的
/// db-change 也会触发 push，但指纹未变时引擎秒级跳过，无放大效应。
static ON_CHANGE_STARTED: AtomicBool = AtomicBool::new(false);

const ON_CHANGE_DEBOUNCE_SECS: u64 = 5;

pub fn sync_on_change_watcher_start(app: AppHandle) {
    if ON_CHANGE_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        let mut rx = orbit_core::eventbus::EVENT_BUS.subscribe();
        loop {
            // 等待首个业务变更事件；总线关闭则退出
            if rx.recv().await.is_err() {
                return;
            }
            // 防抖窗口：持续到来的事件不断重置等待
            while matches!(
                tokio::time::timeout(
                    std::time::Duration::from_secs(ON_CHANGE_DEBOUNCE_SECS),
                    rx.recv(),
                )
                .await,
                Ok(Ok(_))
            ) {}
            run_on_change_sync(&app).await;
        }
    });
}

/// 单次 on-change push（前置条件与定时 tick 相同）
async fn run_on_change_sync(app: &AppHandle) {
    if app.try_state::<AppState>().is_none() {
        return;
    }
    let Ok(Some(record)) = sync_runtime::get_active_config(app).await else {
        return;
    };
    if record.sync_on_change == 0 || record.is_auto_sync == 0 {
        return;
    }
    let Ok(crypto) = sync_runtime::sync_crypto(app) else {
        return;
    };
    if !crypto.has_sync_password() || !crypto.is_unlocked() {
        return;
    }
    let Ok(engine) = sync_runtime::sync_engine(app) else {
        return;
    };
    if cloud_sync_api::is_running(&engine).await {
        return; // 全量同步进行中，无需重复推
    }
    let Some(config) = sync_runtime::engine_config_of_record(&record) else {
        return;
    };
    let device_id = context::get_device_id().unwrap_or_default().to_string();
    let attachments = match resolve_app_data_dir(app) {
        Ok(dir) => sync_runtime::attachments_dir(&dir),
        Err(_) => return,
    };
    if let Err(e) = cloud_sync_api::push_only(
        &engine,
        &config,
        SyncOrigin::Background,
        &device_id,
        &attachments,
    )
    .await
    {
        eprintln!("[sync-on-change] push 失败: {e}");
        if e.is_key_mismatch_error() {
            let _ = app.emit("sync-key-mismatch", ());
        }
    }
}

/// 单轮判定与触发
async fn tick(app: &AppHandle) {
    // DB 未就绪静默跳过
    let Some(state) = app.try_state::<AppState>() else {
        return;
    };

    let Ok(record) = sync_runtime::get_active_config(app).await else {
        return;
    };
    let Some(record) = record else { return };
    // 总开关关闭或未启用定时 → 跳过
    if record.is_auto_sync == 0 || record.sync_interval <= 0 {
        return;
    }

    // 同步加密未解锁 → 跳过（不弹窗打扰；手动同步时才提示解锁）
    let Ok(crypto) = sync_runtime::sync_crypto(app) else {
        return;
    };
    if !crypto.has_sync_password() || !crypto.is_unlocked() {
        return;
    }

    // 间隔判据：now - last >= interval 分钟
    let now_ms = chrono::Utc::now().timestamp_millis() as u64;
    let last = LAST_AUTO_SYNC_MS.load(Ordering::Relaxed);
    if last != 0 && now_ms.saturating_sub(last) < (record.sync_interval as u64) * 60_000 {
        return;
    }

    // 引擎忙 → 下轮再试（不推进 LAST 时间戳）
    let Ok(engine) = sync_runtime::sync_engine(app) else {
        return;
    };
    if cloud_sync_api::is_running(&engine).await {
        return;
    }
    LAST_AUTO_SYNC_MS.store(now_ms, Ordering::Relaxed);

    // 组装并后台执行
    let Some(config) = sync_runtime::engine_config_of_record(&record) else {
        return;
    };
    let device_id = context::get_device_id().unwrap_or_default().to_string();
    let attachments = match resolve_app_data_dir(app) {
        Ok(dir) => sync_runtime::attachments_dir(&dir),
        Err(_) => return,
    };

    let result = cloud_sync_api::sync_now(
        &engine,
        &config,
        SyncOrigin::Background,
        &device_id,
        &attachments,
    )
    .await;
    match result {
        Ok(r) => {
            if !r.skipped {
                let pool = state.pool.clone();
                let _ = SyncConfigRepo::new(pool)
                    .update_last_synced_at(record.id, now_ms as i64)
                    .await;
            }
        }
        Err(e) => {
            eprintln!("[sync-scheduler] 自动同步失败: {e}");
            if e.is_key_mismatch_error() {
                let _ = app.emit("sync-key-mismatch", ());
            }
        }
    }
}
