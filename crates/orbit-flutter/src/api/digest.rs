//! digest — 移动端桥接层每日摘要域（对标 TickTick Daily Reminder）
//!
//! 与桌面壳命令一一对应（业务全部在 `orbit_core::api::digest_api`）：
//! - digest_prefs / digest_set_prefs / digest_summary → 桌面同名命令；
//! - digest_body → 摘要通知文案（core `summary_body` 单一真相源的过桥口）。
//!
//! ## 为什么移动端不调 take_due_digest
//! 桌面是常驻进程，靠 60s tick 判定「到点 + 当天未处置」；移动端应用会被
//! 系统杀死，Dart 进程不在时什么 tick 都跑不了。因此移动端走
//! **系统闹钟的每日重复本地通知**（`flutter_local_notifications` 的
//! `zonedSchedule` + `DateTimeComponents.time`）：由 AlarmManager 持有，
//! 应用被杀/Doze 均准时到达。
//!
//! 由此职责切分：
//! - 本模块只提供**偏好与文案**（配什么时刻、通知说什么）；
//! - 「到点发送」由 Dart 侧 `NotificationService.syncDailyDigest` 排程承担；
//! - core 的 `take_due_digest` 每日记账键 **不参与移动端**（系统闹钟本就
//!   每天恰好一次，不需要去重记账；两张账混用反而会互相压制）。
//!
//! ## DTO 镜像模式
//! [DigestPrefs] / [DigestSummary] 为本模块本地 DTO（同 [super::trash] 的
//! TrashMeta 规则：显式镜像 core 的 Serialize 结构，不直接暴露 core 类型）。

use orbit_core::api::digest_api;
use serde::Serialize;

/// 摘要偏好（镜像 core digest_api::DigestPrefs）
#[derive(Debug, Clone, Serialize)]
pub struct DigestPrefs {
    /// 总开关（默认 false：打扰型功能需显式开启）
    pub enabled: bool,
    /// 目标小时（0–23）
    pub hour: i64,
    /// 目标分钟（0–59）
    pub minute: i64,
}

impl From<digest_api::DigestPrefs> for DigestPrefs {
    fn from(p: digest_api::DigestPrefs) -> Self {
        Self {
            enabled: p.enabled,
            hour: p.hour,
            minute: p.minute,
        }
    }
}

/// 摘要计数（镜像 core digest_api::DigestSummary）
#[derive(Debug, Clone, Serialize)]
pub struct DigestSummary {
    pub due_today: i64,
    pub overdue: i64,
    pub done_today: i64,
}

impl From<digest_api::DigestSummary> for DigestSummary {
    fn from(s: digest_api::DigestSummary) -> Self {
        Self {
            due_today: s.due_today,
            overdue: s.overdue,
            done_today: s.done_today,
        }
    }
}

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

// ── FRB 导出 ──

/// 读摘要偏好（对应桌面 digest_prefs）
pub async fn digest_prefs() -> Result<DigestPrefs, String> {
    let pool = pool()?;
    digest_api::digest_prefs(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(DigestPrefs::from)
}

/// 设置摘要偏好（hour 0–23 / minute 0–59；对应桌面 digest_set_prefs）
pub async fn digest_set_prefs(enabled: bool, hour: i64, minute: i64) -> Result<(), String> {
    let pool = pool()?;
    digest_api::set_digest_prefs(&pool, enabled, hour, minute)
        .await
        .map_err(|e| e.to_string())
}

/// 当前时刻摘要计数（设置页预览；对应桌面 digest_summary）
pub async fn digest_summary() -> Result<DigestSummary, String> {
    let pool = pool()?;
    let now = chrono::Utc::now().timestamp_millis();
    digest_api::digest_summary(&pool, now)
        .await
        .map_err(|e| e.to_string())
        .map(DigestSummary::from)
}

/// 摘要通知文案（core `summary_body` 过桥；Dart 排程时取一次作为通知正文）
///
/// 排程时快照：系统闹钟的正文在排程那一刻固化，应用被杀后无法再算。
/// 因此正文携带的是「排程时刻」的计数，重排（启动/db 变更）时刷新。
pub async fn digest_body() -> Result<String, String> {
    let pool = pool()?;
    let now = chrono::Utc::now().timestamp_millis();
    let summary = digest_api::digest_summary(&pool, now)
        .await
        .map_err(|e| e.to_string())?;
    Ok(digest_api::summary_body(&summary))
}
