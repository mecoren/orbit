//! holiday_scheduler — 节假日自动更新守护（用户需求：定时每天固定时间更新一次，
//! 错过更新时间下次开启自动补更）
//!
//! 60s tick 轮询（与 sync_scheduler 同模式）：
//! - DB 未就绪（try_state 无 AppState）→ 静默跳过；
//! - 到达「每日固定时刻（默认 08:00）且今日尚未成功更新」→ 调
//!   holiday_api::auto_update_holidays（内部 should_update_now 判定：
//!   上次成功在今日之前且已过固定时刻即补更——含「到点未开应用，下次启动
//!   首轮 tick 补上」的场景）；
//! - 网络失败：静默记账（failure_count+1，旧缓存保留），下一轮 tick 重试
//!   （今日未成功则 should_update 持续为 true）；
//! - 启动即扫一轮：应用白天没开、晚上打开时立即补更，不等下一分钟 tick。
//!
//! 首装冷启动：DB 空表时查询回落预置 2026 表（holiday_api），本轮拉取后
//! 替换为线上数据；离线/无网不影响 UI 基本可用。

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::AppHandle;
use tauri::Manager;

use orbit_core::api::holiday_api;

use crate::AppState;

/// tick 周期：60s（与 sync_scheduler 一致；每天最多一次实际拉取，tick 只做判定）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

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
    // 未到每日更新条件时 Ok(false) 静默返回；网络失败仅记账，不打扰用户
    if let Err(e) = holiday_api::auto_update_holidays(&state.pool).await {
        eprintln!("[holiday-scheduler] 自动更新失败（下轮重试）: {e}");
    }
}
