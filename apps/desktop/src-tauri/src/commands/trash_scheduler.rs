//! trash_scheduler — 回收站 TTL 自动清理守护（回收站功能的过期清退）
//!
//! 60s tick 轮询（与 holiday_scheduler 同模式）：
//! - DB 未就绪（try_state 无 AppState）→ 静默跳过；
//! - maybe_purge_expired 内部判定：永久档跳过、24h 内已清跳过、
//!   过期墓碑受同步守卫（仅清已 push 到云端的删除，见 trash_api 模块头）；
//! - 清理失败静默（下一轮 tick 重试），成功无需提示（后台行为）；
//! - 启动即扫一轮：应用长时间未开时，打开即补清过期间隔的过期任务。
//!
//! 日志表 TTL（2026-09-15 接线）：notification_log / todo_activity_log
//! 30 天前记录同 tick 物理删除——两表是本地轨迹（不进同步白名单），
//! 只进不出会持续涨表拖慢查询与 VACUUM；core prune_old 30 天口径
//! 与本守护「过期清退」语义同档，命中 0 行的 DELETE 开销可忽略。

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::AppHandle;
use tauri::Manager;

use orbit_core::api::{
    activity_log_api, notification_log_api,
    trash_api::{self},
};

use crate::AppState;

/// tick 周期：60s（判定轻量；实际清理每日最多一次）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动回收站 TTL 清理守护（幂等；lib.rs setup 阶段调用）
pub fn trash_scheduler_start(app: AppHandle) {
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
    if let Err(e) = trash_api::maybe_purge_expired(&state.pool).await {
        eprintln!("[trash-scheduler] TTL 清理失败（下轮重试）: {e}");
    }
    // 日志表 TTL（30 天；notification/activity 两模块的 prune_old 已带测试）
    const LOG_TTL_DAYS: i64 = 30;
    if let Err(e) = notification_log_api::prune_old(&state.pool, LOG_TTL_DAYS).await {
        eprintln!("[trash-scheduler] 通知日志 TTL 清理失败（下轮重试）: {e}");
    }
    if let Err(e) = activity_log_api::prune_old(&state.pool, LOG_TTL_DAYS).await {
        eprintln!("[trash-scheduler] 活动日志 TTL 清理失败（下轮重试）: {e}");
    }
}
