//! digest_api — 每日摘要提醒（对标 TickTick Daily Reminder）
//!
//! 用户需求：每天固定时刻一条汇总提示——「今日 N 项 / 逾期 M 项」。
//!
//! ## 只读聚合，无新增表
//! 计数全部落在 `todo_tasks` 上（今日截止 / 逾期 / 今日完成三档），不新增结构、
//! 不改 `sync_registry.rs`（与 stats_api 同边界：统计类只读路径不进同步白名单）。
//!
//! ## 配置落 cfg_kv（本机偏好，不同步）
//! - `digest_enabled`：总开关（缺省 **0 = 关**）。摘要提醒是**打扰型**功能，
//!   与「回收站保留时间」「节假日自动更新」不同，不默认开启——需用户显式打开。
//! - `digest_time`：目标时刻 `"HH:mm"`（缺省 `08:00`）。小时档位 0–23、分钟
//!   0–59，校验口径与 `full_sync_backup::backup_prefs` 同源（时刻可配先例）。
//! - `digest_last_day`：上次**已处置**的本地日 index（天）。注意语义是「已处置」
//!   而非「已发送」：超出补弹窗口而静默跳过当天时同样记账，否则每轮 tick 都
//!   会重新判定一次。
//!
//! `cfg_kv` 是纯本地表（migration 0001，不进 SYNCABLE_TABLES）：摘要时刻是
//! 各端各自的偏好，双端各自设置（与 holiday_auto_enabled / trash_retention_days
//! 同边界）。
//!
//! ## 每日一次判定（[take_due_digest]）
//! 条件：开关开 + 当前本地时刻 ≥ 当天目标时刻 + 当天尚未处置。
//! - **启动即补**：应用整天没开、次日打开时**不补昨天的摘要**（本地日 index
//!   已翻页，当天目标未到则等当天时刻）——与 trash/holiday 的「启动首轮补跑」
//!   不同，摘要的语义是「当天回顾」，补昨天的内容无意义。
//! - **补弹窗口**（[CATCHUP_WINDOW_MS]）：同一天内迟到超过窗口（默认 12h）
//!   则静默跳过，避免深夜（目标 08:00、21:00 才开机）补弹「今日待办」。
//!   跳过时照样记 `digest_last_day`，当天不再判定。
//!
//! ## 双端分工
//! - **桌面**：`digest_scheduler`（60s tick）调 [take_due_digest]，命中则发系统
//!   通知 + 写 `notification_log`（kind `digest`）。进程常驻，本模块的记账键
//!   由这条路径独占。
//! - **移动**：走系统闹钟的**每日重复**本地通知（`zonedSchedule` +
//!   `matchDateTimeComponents: time`），应用被杀也准时到达；文案由
//!   [digest_summary] + [summary_body] 在排程时算好。移动侧**不调**
//!   [take_due_digest]（否则与系统闹钟双重提醒；且系统闹钟不依赖进程，
//!   无需本模块的每日记账）。
//!
//! ## 日界口径
//! 与 stats_api 一致：毫秒时间戳按**本地时区**换算日界（复用
//! `stats_api::local_day_index`），不在 SQL 里按 UTC 天分组。

use chrono::{TimeZone, Utc};
use serde::Serialize;
use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};

use super::stats_api::local_day_index;

// ============================================================================
// 常量与配置
// ============================================================================

/// cfg_kv 键：摘要提醒总开关（"1"/"0"，缺省 0 = 关）
const KV_ENABLED: &str = "digest_enabled";

/// cfg_kv 键：目标时刻 "HH:mm"
const KV_TIME: &str = "digest_time";

/// cfg_kv 键：上次已处置的本地日 index（天；缺省 -1 = 从未处置）
const KV_LAST_DAY: &str = "digest_last_day";

/// 默认时刻（早八点，通勤前扫一眼当天安排）
pub const DEFAULT_HOUR: i64 = 8;

/// 默认分钟
pub const DEFAULT_MINUTE: i64 = 0;

/// 补弹窗口：迟到超过此长度则当天静默跳过（避免深夜补弹当日摘要）
pub const CATCHUP_WINDOW_MS: i64 = 12 * 3600 * 1000;

/// 天 → 毫秒
const DAY_MS: i64 = 86_400_000;

/// 摘要偏好（UI 读写 + 调度判定共用）
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DigestPrefs {
    /// 总开关
    pub enabled: bool,
    /// 目标小时（0–23）
    pub hour: i64,
    /// 目标分钟（0–59）
    pub minute: i64,
}

impl Default for DigestPrefs {
    fn default() -> Self {
        Self {
            enabled: false,
            hour: DEFAULT_HOUR,
            minute: DEFAULT_MINUTE,
        }
    }
}

/// 摘要计数（只读聚合结果；UI 与通知文案共用）
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct DigestSummary {
    /// 今日截止且未完成
    pub due_today: i64,
    /// 逾期未完成（截止早于本地今日零点）
    pub overdue: i64,
    /// 今日已完成（is_deleted=0 且 done_at 落在今日窗口）
    pub done_today: i64,
}

// ============================================================================
// cfg_kv 读写（trash_api 同款口径）
// ============================================================================

async fn kv_get(pool: &SqlitePool, key: &str) -> CoreResult<Option<String>> {
    let row: Option<(String,)> = sqlx::query_as("SELECT value FROM cfg_kv WHERE key = ?1")
        .bind(key)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(v,)| v))
}

async fn kv_set(pool: &SqlitePool, key: &str, value: &str) -> CoreResult<()> {
    let now = Utc::now().timestamp_millis();
    sqlx::query(
        "INSERT INTO cfg_kv (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
    )
    .bind(key)
    .bind(value)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn kv_get_i64(pool: &SqlitePool, key: &str) -> CoreResult<Option<i64>> {
    Ok(kv_get(pool, key).await?.and_then(|v| v.parse().ok()))
}

async fn kv_set_i64(pool: &SqlitePool, key: &str, value: i64) -> CoreResult<()> {
    kv_set(pool, key, &value.to_string()).await
}

// ============================================================================
// 时刻工具（本地时区）
// ============================================================================

/// 解析 "HH:mm"；非法（格式/越界）返回 None
pub fn parse_hhmm(raw: &str) -> Option<(i64, i64)> {
    let (h, m) = raw.split_once(':')?;
    if h.len() > 2 || m.len() > 2 {
        return None;
    }
    let h: i64 = h.parse().ok()?;
    let m: i64 = m.parse().ok()?;
    if !(0..=23).contains(&h) || !(0..=59).contains(&m) {
        return None;
    }
    Some((h, m))
}

/// 规范化为 "HH:mm"（补零）
pub fn format_hhmm(hour: i64, minute: i64) -> String {
    format!("{hour:02}:{minute:02}")
}

/// 本地今日零点（毫秒）
fn local_day_start(now_ms: i64) -> i64 {
    let local = Utc
        .timestamp_millis_opt(now_ms)
        .single()
        .unwrap_or_else(|| Utc.timestamp_millis_opt(0).single().unwrap())
        .with_timezone(&chrono::Local);
    let naive = local
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .expect("00:00:00 恒合法");
    chrono::Local
        .from_local_datetime(&naive)
        .earliest()
        .map(|dt| dt.timestamp_millis())
        // 极端 DST 缺失（本地不存在 00:00）时按固定日长回退，仍单调可用
        .unwrap_or_else(|| now_ms - now_ms.rem_euclid(DAY_MS))
}

/// 本地当天的目标时刻（毫秒）
fn local_target_ms(now_ms: i64, hour: i64, minute: i64) -> i64 {
    local_day_start(now_ms) + hour * 3600 * 1000 + minute * 60 * 1000
}

// ============================================================================
// 偏好读写
// ============================================================================

/// 读取摘要偏好（非法/缺省值逐项回落默认）
pub async fn digest_prefs(pool: &SqlitePool) -> CoreResult<DigestPrefs> {
    let enabled = kv_get(pool, KV_ENABLED).await?.as_deref() == Some("1");
    let (hour, minute) = kv_get(pool, KV_TIME)
        .await?
        .and_then(|v| parse_hhmm(&v))
        .unwrap_or((DEFAULT_HOUR, DEFAULT_MINUTE));
    Ok(DigestPrefs {
        enabled,
        hour,
        minute,
    })
}

/// 设置摘要偏好（hour 0–23 / minute 0–59，越界报错；开关与时刻一次性落库）
pub async fn set_digest_prefs(
    pool: &SqlitePool,
    enabled: bool,
    hour: i64,
    minute: i64,
) -> CoreResult<()> {
    if !(0..=23).contains(&hour) {
        return Err(CoreError::Other(format!("非法小时 {hour}（应为 0-23）")));
    }
    if !(0..=59).contains(&minute) {
        return Err(CoreError::Other(format!("非法分钟 {minute}（应为 0-59）")));
    }
    kv_set(pool, KV_ENABLED, if enabled { "1" } else { "0" }).await?;
    kv_set(pool, KV_TIME, &format_hhmm(hour, minute)).await
}

// ============================================================================
// 只读聚合
// ============================================================================

/// 摘要计数（今日截止 / 逾期 / 今日完成；口径见模块头「日界口径」）
pub async fn digest_summary(pool: &SqlitePool, now_ms: i64) -> CoreResult<DigestSummary> {
    let day_start = local_day_start(now_ms);
    let day_end = day_start + DAY_MS;

    let (overdue,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM todo_tasks \
         WHERE is_deleted = 0 AND done = 0 AND due_date IS NOT NULL AND due_date < ?1",
    )
    .bind(day_start)
    .fetch_one(pool)
    .await?;

    let (due_today,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM todo_tasks \
         WHERE is_deleted = 0 AND done = 0 AND due_date IS NOT NULL \
           AND due_date >= ?1 AND due_date < ?2",
    )
    .bind(day_start)
    .bind(day_end)
    .fetch_one(pool)
    .await?;

    let (done_today,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM todo_tasks \
         WHERE is_deleted = 0 AND done = 1 AND done_at IS NOT NULL \
           AND done_at >= ?1 AND done_at < ?2",
    )
    .bind(day_start)
    .bind(day_end)
    .fetch_one(pool)
    .await?;

    Ok(DigestSummary {
        due_today,
        overdue,
        done_today,
    })
}

/// 摘要通知文案（双端共用单一真相源，避免两端各写一份措辞）
///
/// - 今日与逾期皆 0 → 鼓励语（不含「已完成」尾巴：无待办时数字无意义）；
/// - 有逾期 → 两个数字都报；无逾期只报今日；
/// - 今日有完成 → 追加尾巴（正向反馈）。
pub fn summary_body(s: &DigestSummary) -> String {
    if s.due_today == 0 && s.overdue == 0 {
        return "今天没有待办，休息一下吧".to_string();
    }
    let head = if s.overdue > 0 {
        format!("今日 {} 项 · 逾期 {} 项", s.due_today, s.overdue)
    } else {
        format!("今日 {} 项", s.due_today)
    };
    if s.done_today > 0 {
        format!("{head} · 已完成 {} 项", s.done_today)
    } else {
        head
    }
}

// ============================================================================
// 每日一次判定
// ============================================================================

/// 到点则取走今日摘要（幂等：同一天最多返回一次 Some）
///
/// 判定与记账见模块头「每日一次判定」。返回 `None` 的三种情形：
/// 开关关闭 / 当天目标时刻未到 / 当天已处置（含超窗口静默跳过）。
pub async fn take_due_digest(pool: &SqlitePool, now_ms: i64) -> CoreResult<Option<DigestSummary>> {
    let prefs = digest_prefs(pool).await?;
    if !prefs.enabled {
        return Ok(None);
    }

    let today = local_day_index(now_ms);
    if kv_get_i64(pool, KV_LAST_DAY).await?.unwrap_or(-1) == today {
        return Ok(None); // 今天已处置（已发或已静默跳过）
    }

    let target = local_target_ms(now_ms, prefs.hour, prefs.minute);
    if now_ms < target {
        return Ok(None); // 未到点
    }
    if now_ms - target > CATCHUP_WINDOW_MS {
        // 迟到太久（深夜才开机）：静默跳过当天，记账防每轮 tick 反复判定
        kv_set_i64(pool, KV_LAST_DAY, today).await?;
        return Ok(None);
    }

    let summary = digest_summary(pool, now_ms).await?;
    kv_set_i64(pool, KV_LAST_DAY, today).await?;
    Ok(Some(summary))
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 直插一条任务（绕开业务写路径，精准控制 due/done/done_at）
    async fn seed_task(
        pool: &SqlitePool,
        title: &str,
        due: Option<i64>,
        done: i32,
        done_at: Option<i64>,
    ) -> i64 {
        let now = crate::db::clock::next_ms();
        let row: (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks \
             (uuid, title, priority, status, done, done_at, due_date, repeat_mode, is_deleted, created_at, updated_at, version) \
             VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6, 0, 0, ?7, ?7, 1) RETURNING id",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(title)
        .bind(if done == 1 { "done" } else { "pending" })
        .bind(done)
        .bind(done_at)
        .bind(due)
        .bind(now)
        .fetch_one(pool)
        .await
        .unwrap();
        row.0
    }

    /// 指定本地时刻的毫秒时间戳（测试不依赖运行机器的当前钟点）
    fn local_ms(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
        chrono::Local
            .with_ymd_and_hms(year, month, day, hour, minute, 0)
            .single()
            .expect("测试用本地时刻恒有效")
            .timestamp_millis()
    }

    #[test]
    fn default_prefs_is_disabled_at_0800() {
        let p = DigestPrefs::default();
        assert!(!p.enabled, "摘要提醒默认关闭（打扰型功能需显式开启）");
        assert_eq!((p.hour, p.minute), (8, 0));
    }

    #[test]
    fn parse_hhmm_accepts_valid_and_rejects_out_of_range() {
        assert_eq!(parse_hhmm("08:00"), Some((8, 0)));
        assert_eq!(parse_hhmm("00:00"), Some((0, 0)));
        assert_eq!(parse_hhmm("23:59"), Some((23, 59)));
        assert_eq!(parse_hhmm("8:5"), Some((8, 5))); // 不补零也接受
        assert_eq!(parse_hhmm("24:00"), None);
        assert_eq!(parse_hhmm("12:60"), None);
        assert_eq!(parse_hhmm("12"), None);
        assert_eq!(parse_hhmm(""), None);
        assert_eq!(parse_hhmm("abc:def"), None);
        assert_eq!(parse_hhmm("123:00"), None); // 位数越界
    }

    #[tokio::test]
    async fn prefs_roundtrip_and_validation() {
        let pool = setup_db().await;
        assert_eq!(digest_prefs(&pool).await.unwrap(), DigestPrefs::default());

        set_digest_prefs(&pool, true, 21, 30).await.unwrap();
        let p = digest_prefs(&pool).await.unwrap();
        assert!(p.enabled);
        assert_eq!((p.hour, p.minute), (21, 30));

        assert!(set_digest_prefs(&pool, true, 24, 0).await.is_err());
        assert!(set_digest_prefs(&pool, true, -1, 0).await.is_err());
        assert!(set_digest_prefs(&pool, true, 8, 60).await.is_err());
        // 校验失败不落库（原值保持）
        assert_eq!(digest_prefs(&pool).await.unwrap().hour, 21);

        // 存量非法值回落默认
        kv_set(&pool, KV_TIME, "99:99").await.unwrap();
        let p = digest_prefs(&pool).await.unwrap();
        assert_eq!((p.hour, p.minute), (DEFAULT_HOUR, DEFAULT_MINUTE));
    }

    #[tokio::test]
    async fn summary_splits_today_overdue_and_done_today() {
        let pool = setup_db().await;
        // 锚点取一个真实量级的本地时刻（避免 now 过小导致日界换算退化）
        let now = local_ms(2026, 9, 30, 20, 0);
        let day_start = local_day_start(now);

        seed_task(&pool, "今日", Some(day_start + 3_600_000), 0, None).await;
        seed_task(&pool, "昨天逾期", Some(day_start - 3_600_000), 0, None).await;
        seed_task(&pool, "上周逾期", Some(day_start - 7 * DAY_MS), 0, None).await;
        seed_task(
            &pool,
            "今日已完成",
            Some(day_start + 7_200_000),
            1,
            Some(now),
        )
        .await;
        seed_task(&pool, "昨天完成", None, 1, Some(day_start - 60_000)).await;
        seed_task(&pool, "无截止", None, 0, None).await;

        let s = digest_summary(&pool, now).await.unwrap();
        assert_eq!(s.due_today, 1, "仅今天截止的未完成任务");
        assert_eq!(s.overdue, 2, "昨天与上周逾期；无截止不算逾期");
        assert_eq!(s.done_today, 1, "仅今天的完成计入");
    }

    #[tokio::test]
    async fn summary_ignores_deleted_rows() {
        let pool = setup_db().await;
        let now = local_ms(2026, 9, 30, 20, 0);
        let day_start = local_day_start(now);
        let id = seed_task(&pool, "今日", Some(day_start + 3_600_000), 0, None).await;
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1 WHERE id = ?")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        let s = digest_summary(&pool, now).await.unwrap();
        assert_eq!((s.due_today, s.overdue), (0, 0));
    }

    #[test]
    fn summary_body_wording() {
        let none = DigestSummary::default();
        assert_eq!(summary_body(&none), "今天没有待办，休息一下吧");

        let today_only = DigestSummary {
            due_today: 3,
            overdue: 0,
            done_today: 0,
        };
        assert_eq!(summary_body(&today_only), "今日 3 项");

        let with_overdue = DigestSummary {
            due_today: 3,
            overdue: 1,
            done_today: 0,
        };
        assert_eq!(summary_body(&with_overdue), "今日 3 项 · 逾期 1 项");

        let with_done = DigestSummary {
            due_today: 3,
            overdue: 1,
            done_today: 2,
        };
        assert_eq!(
            summary_body(&with_done),
            "今日 3 项 · 逾期 1 项 · 已完成 2 项"
        );

        // 全清零但有完成：仍报完成数
        let done_only = DigestSummary {
            due_today: 0,
            overdue: 0,
            done_today: 2,
        };
        assert_eq!(summary_body(&done_only), "今天没有待办，休息一下吧");
    }

    #[tokio::test]
    async fn take_due_digest_disabled_is_none() {
        let pool = setup_db().await;
        let now = local_ms(2026, 9, 30, 9, 0);
        assert!(take_due_digest(&pool, now).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn take_due_digest_before_target_is_none() {
        let pool = setup_db().await;
        set_digest_prefs(&pool, true, 8, 0).await.unwrap();
        // 07:59 未到点
        let now = local_ms(2026, 9, 30, 7, 59);
        assert!(take_due_digest(&pool, now).await.unwrap().is_none());
        // 08:00 到点
        let now = local_ms(2026, 9, 30, 8, 0);
        assert!(take_due_digest(&pool, now).await.unwrap().is_some());
    }

    #[tokio::test]
    async fn take_due_digest_fires_once_per_local_day() {
        let pool = setup_db().await;
        set_digest_prefs(&pool, true, 8, 0).await.unwrap();
        let now = local_ms(2026, 9, 30, 8, 0);
        assert!(take_due_digest(&pool, now).await.unwrap().is_some());
        // 同一天稍后再 tick（桌面 60s 轮询常态）→ 不再发
        let later = local_ms(2026, 9, 30, 8, 1);
        assert!(take_due_digest(&pool, later).await.unwrap().is_none());
        let later = local_ms(2026, 9, 30, 23, 59);
        assert!(take_due_digest(&pool, later).await.unwrap().is_none());
        // 次日同时刻 → 再发
        let next_day = local_ms(2026, 10, 1, 8, 0);
        assert!(take_due_digest(&pool, next_day).await.unwrap().is_some());
    }

    #[tokio::test]
    async fn take_due_digest_skips_beyond_catchup_window_once() {
        let pool = setup_db().await;
        set_digest_prefs(&pool, true, 8, 0).await.unwrap();
        // 21:00 开机：距 08:00 已 13h > 12h 窗口 → 静默跳过
        let late = local_ms(2026, 9, 30, 21, 0);
        assert!(take_due_digest(&pool, late).await.unwrap().is_none());
        // 当天不再判定（已记账），即便回到窗口内
        let back = local_ms(2026, 9, 30, 19, 0);
        assert!(take_due_digest(&pool, back).await.unwrap().is_none());
        // 次日恢复正常
        assert!(
            take_due_digest(&pool, local_ms(2026, 10, 1, 8, 0))
                .await
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn take_due_digest_boundary_at_window_edge() {
        let pool = setup_db().await;
        set_digest_prefs(&pool, true, 8, 0).await.unwrap();
        // 恰好 12h（20:00）仍在窗口内 → 发
        let edge = local_ms(2026, 9, 30, 20, 0);
        assert_eq!(edge - local_target_ms(edge, 8, 0), CATCHUP_WINDOW_MS);
        assert!(take_due_digest(&pool, edge).await.unwrap().is_some());
    }

    #[tokio::test]
    async fn take_due_digest_returns_counts_not_just_flag() {
        let pool = setup_db().await;
        set_digest_prefs(&pool, true, 8, 0).await.unwrap();
        let now = local_ms(2026, 9, 30, 9, 0);
        let day_start = local_day_start(now);
        seed_task(&pool, "今日", Some(day_start + 3_600_000), 0, None).await;
        seed_task(&pool, "逾期", Some(day_start - 3_600_000), 0, None).await;

        let s = take_due_digest(&pool, now).await.unwrap().unwrap();
        assert_eq!((s.due_today, s.overdue), (1, 1));
        assert_eq!(summary_body(&s), "今日 1 项 · 逾期 1 项");
    }
}
