//! holiday — 移动端桥接层节假日域（用户需求：日历视图联网更新节假日）
//!
//! 与桌面壳命令一一对应（业务全部在 orbit_core::api::holiday_api）：
//! - holiday_list / holiday_is_on → 桌面 holidays_list / holiday_is_on；
//! - holiday_update（手动，强制拉取）→ 桌面 holidays_update；
//! - holiday_meta / holiday_set_fixed_hour → 桌面同名命令。
//!
//! ## DTO 镜像模式
//! HolidayInfo / HolidayMeta / HolidayMeta 内嵌布尔（is_holiday）为本模块
//! 本地 DTO（[super::dto] 定义），避免 core 类型过桥被 FRB 降级 opaque
//! （同 [super::todo] 模块注释的规则）。
//!
//! ## 移动端调度（手机被杀后无 Dart 进程，与桌面常驻 tick 不同）
//! `start_holiday_scheduler` 为 FRB 运行时上的 Rust 守护（同
//! [super::events] 的 start_reminder_poller 模式）：60s tick +
//! should_update_now 判定。关键时序：
//! - **启动补更**：应用白天没开 → 晚上打开时 db_init 后 Dart 调本函数，
//!   首轮 tick 即补当日缺额（错过固定时刻的自动更新）；
//! - **每日一次**：当天成功过则 tick 静默跳过（记账在 cfg_kv，重启不丢）；
//! - 网络失败静默重试（failure_count 记账，不打扰用户）。

use std::sync::atomic::{AtomicBool, Ordering};

use orbit_core::api::holiday_api;

pub use super::dto::{HolidayInfo, HolidayMeta};

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// tick 周期：60s（判定轻量；实际拉取每天最多一次）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动节假日自动更新守护（幂等；Dart 在 DB 就绪后调用一次，BootGate 接线）
///
/// 每日固定时刻（默认 08:00 本地）一次；错过时刻后下次启动首轮 tick 即补更。
pub fn start_holiday_scheduler() {
    if SCHEDULER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    super::events::spawn_on_bridge_runtime(async {
        loop {
            tick_once().await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

async fn tick_once() {
    let Ok(pool) = pool() else {
        return; // DB 未就绪，静默跳过（下轮 tick 自动开始工作）
    };
    // 未到每日更新条件时 Ok(false) 静默返回；网络失败仅记账
    if let Err(e) = holiday_api::auto_update_holidays(&pool).await {
        eprintln!("[holiday-scheduler] 自动更新失败（下轮重试）: {e}");
    }
}

// ── FRB 导出 ──

/// 全部节假日（date 升序；空库回落预置 2026 表，冷启动可用）
pub async fn holiday_list() -> Result<Vec<HolidayInfo>, String> {
    let pool = pool()?;
    let items = holiday_api::list_holidays(&pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(HolidayInfo::from).collect())
}

/// 判定某日期：Some(true) 放假 / Some(false) 调休补班 / None 普通日
pub async fn holiday_is_on(date: String) -> Result<Option<bool>, String> {
    let pool = pool()?;
    holiday_api::is_holiday_on(&pool, &date)
        .await
        .map_err(|e| e.to_string())
}

/// 手动更新（强制拉取；网络失败错误文案给 Dart toast，旧缓存保留）
pub async fn holiday_update() -> Result<HolidayMeta, String> {
    let pool = pool()?;
    holiday_api::update_holidays(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(HolidayMeta::from)
}

/// 更新记账（上次成功/尝试、连续失败次数、固定时刻）
pub async fn holiday_meta() -> Result<HolidayMeta, String> {
    let pool = pool()?;
    holiday_api::holiday_meta(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(HolidayMeta::from)
}

/// 设置每日固定更新时刻（0-23，越界 clamp）
pub async fn holiday_set_fixed_hour(hour: u32) -> Result<(), String> {
    let pool = pool()?;
    holiday_api::set_holiday_fixed_hour(&pool, hour)
        .await
        .map_err(|e| e.to_string())
}
