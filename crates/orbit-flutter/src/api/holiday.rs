//! holiday — 移动端桥接层节假日域（用户需求：日历视图联网更新节假日）
//!
//! 与桌面壳命令一一对应（业务全部在 orbit_core::api::holiday_api）：
//! - holiday_list / holiday_is_on → 桌面 holidays_list / holiday_is_on；
//! - holiday_update（手动，强制拉取）→ 桌面 holidays_update；
//! - holiday_meta / holiday_set_auto_enabled → 桌面同名命令；
//! - holiday_fetch_year → 桌面 holiday_fetch_year（「更新该年」，返回行数）；
//! - holiday_fetch_range → 桌面 holiday_fetch_range（按年份范围补写）；
//! - holiday_cancel_fetch → 桌面 holiday_cancel_fetch；
//! - subscribe_holiday_progress → 桌面 `holiday-progress` 事件（范围补写进度流）。
//!
//! ## DTO 镜像模式
//! HolidayInfo / HolidayMeta / HolidayYearOutcome / HolidayRangeSummary /
//! HolidayProgressDto 为本模块本地 DTO（[super::dto] 定义），避免 core 类型过桥
//! 被 FRB 降级 opaque（同 [super::todo] 模块注释的规则）。
//!
//! ## 移动端调度（手机被杀后无 Dart 进程，与桌面常驻 tick 不同）
//! `start_holiday_scheduler` 为 FRB 运行时上的 Rust 守护（同
//! [super::events] 的 start_reminder_poller 模式）：60s tick +
//! should_update_now **每月一次** 判定。关键时序：
//! - **启动补更**：整月没开应用 → 月内首次打开时 db_init 后 Dart 调本函数，
//!   首轮 tick 即补拉（跨月判定为真）；
//! - **每月一次**：本月成功过则 tick 静默跳过（记账在 cfg_kv，重启不丢）；
//!   总开关 `holiday_auto_enabled` 关闭时彻底不跑；
//! - 网络失败静默重试（failure_count 记账，不打扰用户）。
//!
//! ## 进度订阅的生命周期
//! 与 `subscribe_db_changes` 的「进程级单播 + once-guard」不同：范围补写进度
//! 只在设置页发起补写期间产生，订阅随页面挂载/卸载反复创建。故此处**不加
//! once-guard**，改为在 `sink.add` 失败（Dart 侧已取消订阅）时主动退出循环，
//! 避免任务常驻泄漏。

use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::broadcast::error::RecvError;

use orbit_core::api::holiday_api;

// StreamSink 由 codegen 生成的模块提供（FRB 2.x 约定，同 [super::events]）
use crate::frb_generated::StreamSink;

pub use super::dto::{
    HolidayInfo, HolidayMeta, HolidayProgressDto, HolidayRangeSummary, HolidayYearOutcome,
};

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// tick 周期：60s（判定轻量；实际拉取每月最多一次）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动节假日自动更新守护（幂等；Dart 在 DB 就绪后调用一次，BootGate 接线）
///
/// 每月一次（跨月后首轮 tick 即拉）；总开关关闭时 core 侧直接跳过。
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
    // 未到每月更新条件（本月已成功 / 开关关闭）时 Ok(false) 静默返回；
    // 网络失败仅记账
    if let Err(e) = holiday_api::auto_update_holidays(&pool).await {
        eprintln!("[holiday-scheduler] 自动更新失败（下轮重试）: {e}");
    }
}

// ── FRB 导出 ──

/// 全部节假日（date 升序；按年合并：DB 已覆盖年份为准，预置表兜底其余年份）
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

/// 按单年补写（年份需在 2013 ~ 明年；整年替换，历史年份不写自动更新记账）
///
/// 返回记账 + 该年实际行数（`row_count == 0` = 该年线上无数据，UI 提示用）
pub async fn holiday_fetch_year(year: i32) -> Result<HolidayYearOutcome, String> {
    let pool = pool()?;
    holiday_api::fetch_holiday_year(&pool, year)
        .await
        .map_err(|e| e.to_string())
        .map(HolidayYearOutcome::from)
}

/// 按年份范围补写（分片并发 + 熔断；进度经 [subscribe_holiday_progress] 回传）
pub async fn holiday_fetch_range(start: i32, end: i32) -> Result<HolidayRangeSummary, String> {
    let pool = pool()?;
    holiday_api::fetch_holiday_range(&pool, start, end)
        .await
        .map_err(|e| e.to_string())
        .map(HolidayRangeSummary::from)
}

/// 请求取消进行中的范围补写（幂等；无进行中操作时无害）
pub fn holiday_cancel_fetch() {
    holiday_api::cancel_holiday_range_fetch();
}

/// 更新记账（上次成功/尝试、连续失败次数、自动更新开关）
pub async fn holiday_meta() -> Result<HolidayMeta, String> {
    let pool = pool()?;
    holiday_api::holiday_meta(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(HolidayMeta::from)
}

/// 设置自动更新总开关（关闭后调度器不再联网，仅保留手动与按年补写）
pub async fn holiday_set_auto_enabled(enabled: bool) -> Result<(), String> {
    let pool = pool()?;
    holiday_api::set_holiday_auto_enabled(&pool, enabled)
        .await
        .map_err(|e| e.to_string())
}

/// 订阅范围补写进度（Dart 侧 `StreamProvider` 单点消费）
///
/// 每次调用新建一条 Rust→Dart 流；Dart 取消订阅后 `sink.add` 失败即自行退出。
pub fn subscribe_holiday_progress(sink: StreamSink<HolidayProgressDto>) {
    super::events::spawn_on_bridge_runtime(async move {
        let mut rx = holiday_api::subscribe_holiday_progress();
        loop {
            match rx.recv().await {
                Ok(p) => {
                    if sink.add(HolidayProgressDto::from(p)).is_err() {
                        break; // Dart 侧已取消订阅
                    }
                }
                Err(RecvError::Lagged(skipped)) => {
                    eprintln!("[holiday-progress] 落后 {skipped} 条，继续转发");
                }
                Err(RecvError::Closed) => break,
            }
        }
    });
}
