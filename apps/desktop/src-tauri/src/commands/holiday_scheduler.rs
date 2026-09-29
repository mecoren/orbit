//! holiday_scheduler — 节假日自动更新守护 + 范围补写进度泵
//!
//! 用户需求：日历联网更新节假日（每月自动一次 + 手动 + 按年补写）。
//!
//! ## 自动更新守护（60s tick，与 sync_scheduler 同模式）
//! - DB 未就绪（try_state 无 AppState）→ 静默跳过；
//! - `holiday_api::auto_update_holidays` 内部判定（[should_update_now] 每月口径：
//!   上次成功的日历月 ≠ 当前月即更新，含「跨月后首次启动/下轮 tick 补更」；
//!   总开关 `holiday_auto_enabled` 关闭时直接返回 false）；
//! - 网络失败：静默记账（failure_count+1，旧缓存保留），下一轮 tick 重试
//!   （本月未成功则判定持续为 true）；
//! - 启动即扫一轮：应用整月没开、月内首次打开时立即补更，不等下一分钟 tick。
//!
//! 首装冷启动：DB 空表时查询回落预置 2026 表（holiday_api），本轮拉取后
//! 替换为线上数据；离线/无网不影响 UI 基本可用。
//!
//! ## 范围补写进度泵
//! [holiday_progress_pump_start] 订阅 core 的节假日进度广播
//! （[holiday_api::subscribe_holiday_progress]）并转发为 `holiday-progress`
//! 事件给前端。进程级 once-guard；`Lagged` 不得终止转发（照 `db_cmd.rs`
//! 的 `start_event_forwarding` 约定，落后仅继续），`Closed` 才退出。

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::broadcast::error::RecvError;

use orbit_core::api::holiday_api;

use crate::AppState;

/// tick 周期：60s（与 sync_scheduler 一致；每月最多一次实际拉取，tick 只做判定）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);
static PROGRESS_PUMP_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动节假日自动更新守护（幂等；lib.rs setup 阶段调用）
pub fn holiday_scheduler_start(app: AppHandle) {
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

async fn tick(app: &AppHandle) {
    let Some(state) = app.try_state::<AppState>() else {
        return; // DB 未就绪（未初始化/迁移中），静默跳过
    };
    // 未到更新条件（本月已成功 / 开关关闭）时 Ok(false) 静默返回；
    // 网络失败仅记账，不打扰用户
    if let Err(e) = holiday_api::auto_update_holidays(&state.pool).await {
        eprintln!("[holiday-scheduler] 自动更新失败（下轮重试）: {e}");
    }
}

/// 启动范围补写进度泵（幂等；lib.rs setup 阶段调用）
///
/// core 侧进度广播是进程级 Lazy static（sender 永不 drop），`while let` 不会
/// 自然结束，故必须加 once-guard 防止重复 spawn 导致同一进度被 emit 多遍。
pub fn holiday_progress_pump_start(app: AppHandle) {
    if PROGRESS_PUMP_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let emit_handle = app;
    tauri::async_runtime::spawn(async move {
        let mut rx = holiday_api::subscribe_holiday_progress();
        loop {
            match rx.recv().await {
                Ok(progress) => {
                    let _ = emit_handle.emit("holiday-progress", progress);
                }
                // 落后不能终止转发（容量 64 远大于单次范围操作的事件数，
                // 出现即说明有心跳丢失；继续收后续事件即可）
                Err(RecvError::Lagged(skipped)) => {
                    eprintln!("[holiday-progress] 落后 {skipped} 条，继续转发");
                }
                Err(RecvError::Closed) => break,
            }
        }
    });
}
