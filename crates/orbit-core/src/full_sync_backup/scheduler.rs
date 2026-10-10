//! scheduler — 调度器核心逻辑（v4 新增）
//!
//! 提供 `calculate_next_backup_at` 纯函数，根据当前时间与 `BackupPrefs` 计算下一次
//! 备份触发时间戳（Unix 秒）。桌面端 Tauri managed state 与移动端 Riverpod provider
//! 共用此函数，保证双端调度行为一致。
//!
//! 调度规则（`schedule_time` 等挂钟字段一律按**本地时区**解释）：
//! - off：返回 0（不调度）
//! - hourly：当前时间向上取整到下一个 schedule_minute 分（如 10:23 + minute=30 → 10:30）
//! - daily：今天或明天 schedule_time
//! - weekly：下一个 schedule_weekday 的 schedule_time
//! - monthly：下一个 schedule_day_of_month 的 schedule_time
//! - yearly：下一个 schedule_month/day_of_month 的 schedule_time
//!
//! # 日期推进与 DST 口径
//!
//! - 跨日推进按**日历日**（naive 日期 +1 再解析回绝对瞬间），不用绝对 +24h——
//!   DST 跳变当天挂钟不漂移 1 小时。
//! - 春季跳变：用户填的时刻当天不存在（如 02:30 落在 02:00→03:00 空隙里）→
//!   顺延到跳变后首个存在时刻，不漏备份。
//! - 秋季回拨：同一挂钟时刻出现两次 → 取第一次。
//! - 触发侧比对的是绝对时间戳（`now_ts < prefs.next_backup_at`），故挂钟语义
//!   全部落在本模块的时刻构造里，触发瞬间本身不受时区影响。

use chrono::{
    DateTime, Datelike, Days, MappedLocalTime, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc,
};

use crate::full_sync_backup::backup_prefs::{BackupPrefs, ScheduleType};

/// 计算下一次备份触发时间戳（Unix 秒）
///
/// 返回 0 表示不调度（schedule_type == Off）
pub fn calculate_next_backup_at(now_ts: i64, prefs: &BackupPrefs) -> i64 {
    calculate_next_backup_at_in(now_ts, prefs, &chrono::Local)
}

/// 泛型时区入口：生产固定 `Local`；测试注入带 DST 的时区（如 America/New_York）
/// 验证跳变边界，不依赖本机时区。
fn calculate_next_backup_at_in<Tz: TimeZone>(now_ts: i64, prefs: &BackupPrefs, tz: &Tz) -> i64
where
    Tz::Offset: Copy,
{
    if prefs.schedule_type == ScheduleType::Off {
        return 0;
    }

    let now = DateTime::<Utc>::from_timestamp(now_ts, 0)
        .unwrap_or_else(Utc::now)
        .with_timezone(tz);
    let (h, m) = BackupPrefs::parse_schedule_time(&prefs.schedule_time).unwrap_or((3, 0));

    let next = match prefs.schedule_type {
        ScheduleType::Off => return 0,
        ScheduleType::Hourly => next_hourly(&now, prefs.schedule_minute),
        ScheduleType::Daily => next_daily(tz, &now, h, m),
        ScheduleType::Weekly => next_weekly(tz, &now, prefs.schedule_weekday, h, m),
        ScheduleType::Monthly => next_monthly(tz, &now, prefs.schedule_day_of_month, h, m),
        ScheduleType::Yearly => next_yearly(
            tz,
            &now,
            prefs.schedule_month,
            prefs.schedule_day_of_month,
            h,
            m,
        ),
    };

    next.timestamp()
}

/// 在指定日期拼出本地挂钟时刻（naive，尚未解析到时区）
fn naive_at(date: NaiveDate, h: u32, m: u32) -> NaiveDateTime {
    date.and_hms_opt(h, m, 0)
        .unwrap_or_else(|| date.and_hms_opt(0, 0, 0).unwrap())
}

/// 把本地挂钟时刻解析为绝对时间，处理 DST 两分支：
/// - 时刻不存在（春季跳变空隙）→ 沿 naive 分钟轴向前顺延，取跳变后首个存在时刻；
/// - 时刻出现两次（秋季回拨）→ 取第一次。
///
/// 搜索窗 24h（tzdata 实际缺口 ≤ 2h），窗内仍无解返回 None，由调用方兜底。
fn resolve_local<Tz: TimeZone>(tz: &Tz, naive: NaiveDateTime) -> Option<DateTime<Tz>>
where
    Tz::Offset: Copy,
{
    for stretch_min in 0..=(24 * 60) {
        let candidate = naive + chrono::Duration::minutes(stretch_min);
        match tz.from_local_datetime(&candidate) {
            MappedLocalTime::Single(dt) => return Some(dt),
            MappedLocalTime::Ambiguous(earliest, _) => return Some(earliest),
            MappedLocalTime::None => continue,
        }
    }
    None
}

/// hourly：向上取整到下一个 schedule_minute 分
///
/// 例：
/// - 10:23:00 + minute=30 → 10:30:00
/// - 10:31:00 + minute=30 → 11:30:00
/// - 10:30:00 + minute=30 → 11:30:00（当前分钟已过，取下一个）
fn next_hourly<Tz: TimeZone>(now: &DateTime<Tz>, minute: u32) -> DateTime<Tz>
where
    Tz::Offset: Copy,
{
    let mut next = now
        .with_minute(0)
        .unwrap_or(*now)
        .with_second(0)
        .unwrap_or(*now)
        .with_nanosecond(0)
        .unwrap_or(*now);

    // 设置目标分钟
    next = next.with_minute(minute).unwrap_or(next);

    // 若已过当前小时的 target minute，跳到下一小时的 target minute
    if next <= *now {
        next += chrono::Duration::hours(1);
    }

    next
}

/// daily：今天或明天 schedule_time
fn next_daily<Tz: TimeZone>(tz: &Tz, now: &DateTime<Tz>, h: u32, m: u32) -> DateTime<Tz>
where
    Tz::Offset: Copy,
{
    let today = now.date_naive();
    for offset in [0u64, 1] {
        let date = today + Days::new(offset);
        if let Some(target) = resolve_local(tz, naive_at(date, h, m))
            && target > *now
        {
            return target;
        }
    }

    // 兜底：理论上不可达（resolve_local 24h 搜索窗必有解），退化为绝对 +24h
    *now + chrono::Duration::days(1)
}

/// weekly：下一个 schedule_weekday 的 schedule_time
///
/// weekday: 0=周日, 1=周一, ..., 6=周六（与 chrono::Weekday::num_days_from_sunday 一致）
fn next_weekly<Tz: TimeZone>(
    tz: &Tz,
    now: &DateTime<Tz>,
    target_weekday: u32,
    h: u32,
    m: u32,
) -> DateTime<Tz>
where
    Tz::Offset: Copy,
{
    let current_weekday = now.weekday().num_days_from_sunday();
    let days_ahead = (target_weekday as i64 - current_weekday as i64 + 7) % 7;
    let base = now.date_naive() + Days::new(days_ahead as u64);

    // 两个候选：本周（或当天）目标时刻 → +7 天后的同一挂钟时刻；
    // 同一天但时刻已过时自然落到第二个候选（下周），无需单独分支
    for extra in [0u64, 7] {
        let date = base + Days::new(extra);
        if let Some(target) = resolve_local(tz, naive_at(date, h, m))
            && target > *now
        {
            return target;
        }
    }

    // 兜底：理论上不可达（resolve_local 24h 搜索窗必有解），退化为绝对 +7 天
    *now + chrono::Duration::days(7)
}

/// monthly：下一个 schedule_day_of_month 的 schedule_time
///
/// day_of_month 限制 1-28（由 validate_schedule 保证），避免月末歧义
fn next_monthly<Tz: TimeZone>(
    tz: &Tz,
    now: &DateTime<Tz>,
    target_day: u32,
    h: u32,
    m: u32,
) -> DateTime<Tz>
where
    Tz::Offset: Copy,
{
    let today = now.date_naive();
    let (y, mo) = (today.year(), today.month());
    let (ny, nmo) = if mo == 12 { (y + 1, 1) } else { (y, mo + 1) };

    // 两个候选：本月 target_day → 下月同日（target_day 限 1-28，任何月都有效）
    for (year, month) in [(y, mo), (ny, nmo)] {
        let Some(date) = NaiveDate::from_ymd_opt(year, month, target_day) else {
            continue;
        };
        if let Some(target) = resolve_local(tz, naive_at(date, h, m))
            && target > *now
        {
            return target;
        }
    }

    // 兜底：理论上不可达（resolve_local 24h 搜索窗必有解），退化为绝对 +28 天
    *now + chrono::Duration::days(28)
}

/// yearly：下一个 schedule_month/day_of_month 的 schedule_time
fn next_yearly<Tz: TimeZone>(
    tz: &Tz,
    now: &DateTime<Tz>,
    month: u32,
    day: u32,
    h: u32,
    m: u32,
) -> DateTime<Tz>
where
    Tz::Offset: Copy,
{
    // 两个候选：今年目标日 → 明年同月同日
    for year in [now.year(), now.year() + 1] {
        let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
            continue;
        };
        if let Some(target) = resolve_local(tz, naive_at(date, h, m))
            && target > *now
        {
            return target;
        }
    }

    // 兜底：理论上不可达（resolve_local 24h 搜索窗必有解），退化为绝对 +365 天
    *now + chrono::Duration::days(365)
}

#[cfg(test)]
mod tests {
    use chrono::Local;
    use chrono_tz::America::New_York;

    use super::*;

    /// 按本地挂钟时间构造时间戳（F89 修复口径：schedule_time = 本地时区挂钟时间，
    /// 用例的输入与期望都按本地构造，故在任何时区机器上跑结果一致）
    fn ts(year: i32, month: u32, day: u32, hour: u32, min: u32) -> i64 {
        Local
            .with_ymd_and_hms(year, month, day, hour, min, 0)
            .single()
            .unwrap()
            .timestamp()
    }

    fn make_prefs(schedule_type: ScheduleType) -> BackupPrefs {
        BackupPrefs {
            schedule_type,
            ..Default::default()
        }
    }

    // ============== Off ==============

    #[test]
    fn off_returns_zero() {
        let prefs = make_prefs(ScheduleType::Off);
        assert_eq!(calculate_next_backup_at(ts(2026, 7, 20, 10, 0), &prefs), 0);
    }

    // ============== Hourly ==============

    #[test]
    fn hourly_before_target_minute_returns_same_hour() {
        // 10:23 + minute=30 → 10:30
        let mut prefs = make_prefs(ScheduleType::Hourly);
        prefs.schedule_minute = 30;
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 23), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 10, 30));
    }

    #[test]
    fn hourly_after_target_minute_returns_next_hour() {
        // 10:31 + minute=30 → 11:30
        let mut prefs = make_prefs(ScheduleType::Hourly);
        prefs.schedule_minute = 30;
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 31), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 11, 30));
    }

    #[test]
    fn hourly_at_exact_target_minute_returns_next_hour() {
        // 10:30:00 + minute=30 → 11:30（当前分钟已开始，取下一个）
        let mut prefs = make_prefs(ScheduleType::Hourly);
        prefs.schedule_minute = 30;
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 30), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 11, 30));
    }

    #[test]
    fn hourly_minute_zero() {
        // 10:23 + minute=0 → 11:00
        let mut prefs = make_prefs(ScheduleType::Hourly);
        prefs.schedule_minute = 0;
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 23), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 11, 0));
    }

    // ============== Daily ==============

    #[test]
    fn daily_before_target_time_returns_today() {
        // 现在 10:00，目标 12:30 → 今天 12:30
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "12:30".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 12, 30));
    }

    #[test]
    fn daily_after_target_time_returns_tomorrow() {
        // 现在 14:00，目标 12:30 → 明天 12:30
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "12:30".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 14, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 21, 12, 30));
    }

    #[test]
    fn daily_at_exact_target_time_returns_tomorrow() {
        // 现在 12:30:00，目标 12:30 → 明天 12:30
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "12:30".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 12, 30), &prefs);
        assert_eq!(next, ts(2026, 7, 21, 12, 30));
    }

    // ============== Weekly ==============

    #[test]
    fn weekly_same_day_before_time_returns_today() {
        // 2026-07-20 是周一（weekday=1），目标周一 10:00，现在 09:00 → 今天 10:00
        let mut prefs = make_prefs(ScheduleType::Weekly);
        prefs.schedule_weekday = 1; // 周一
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 20, 10, 0));
    }

    #[test]
    fn weekly_same_day_after_time_returns_next_week() {
        // 2026-07-20 是周一，目标周一 10:00，现在 11:00 → 下周一 10:00
        let mut prefs = make_prefs(ScheduleType::Weekly);
        prefs.schedule_weekday = 1;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 11, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 27, 10, 0));
    }

    #[test]
    fn weekly_future_day_this_week() {
        // 2026-07-20 是周一，目标周三 10:00 → 本周三 10:00
        let mut prefs = make_prefs(ScheduleType::Weekly);
        prefs.schedule_weekday = 3; // 周三
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 22, 10, 0));
    }

    #[test]
    fn weekly_past_day_this_week_wraps_to_next_week() {
        // 2026-07-22 是周三，目标周一 10:00 → 下周一 10:00
        let mut prefs = make_prefs(ScheduleType::Weekly);
        prefs.schedule_weekday = 1; // 周一
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 22, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 27, 10, 0));
    }

    // ============== Monthly ==============

    #[test]
    fn monthly_before_target_day_this_month() {
        // 现在 7月10日，目标 15日 10:00 → 7月15日 10:00
        let mut prefs = make_prefs(ScheduleType::Monthly);
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 10, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 7, 15, 10, 0));
    }

    #[test]
    fn monthly_after_target_day_this_month_goes_next_month() {
        // 现在 7月20日，目标 15日 10:00 → 8月15日 10:00
        let mut prefs = make_prefs(ScheduleType::Monthly);
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 8, 15, 10, 0));
    }

    #[test]
    fn monthly_on_target_day_after_time_goes_next_month() {
        // 现在 7月15日 11:00，目标 15日 10:00 → 8月15日 10:00
        let mut prefs = make_prefs(ScheduleType::Monthly);
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 15, 11, 0), &prefs);
        assert_eq!(next, ts(2026, 8, 15, 10, 0));
    }

    #[test]
    fn monthly_december_to_january() {
        // 现在 12月20日，目标 15日 → 明年 1月15日
        let mut prefs = make_prefs(ScheduleType::Monthly);
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 12, 20, 9, 0), &prefs);
        assert_eq!(next, ts(2027, 1, 15, 10, 0));
    }

    // ============== Yearly ==============

    #[test]
    fn yearly_before_target_date_this_year() {
        // 现在 2026-03-01，目标 6月15日 10:00 → 2026-06-15 10:00
        let mut prefs = make_prefs(ScheduleType::Yearly);
        prefs.schedule_month = 6;
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 3, 1, 9, 0), &prefs);
        assert_eq!(next, ts(2026, 6, 15, 10, 0));
    }

    #[test]
    fn yearly_after_target_date_this_year_goes_next_year() {
        // 现在 2026-07-20，目标 6月15日 → 2027-06-15
        let mut prefs = make_prefs(ScheduleType::Yearly);
        prefs.schedule_month = 6;
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 9, 0), &prefs);
        assert_eq!(next, ts(2027, 6, 15, 10, 0));
    }

    #[test]
    fn yearly_on_target_date_after_time_goes_next_year() {
        // 现在 2026-06-15 11:00，目标 6月15日 10:00 → 2027-06-15
        let mut prefs = make_prefs(ScheduleType::Yearly);
        prefs.schedule_month = 6;
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "10:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 6, 15, 11, 0), &prefs);
        assert_eq!(next, ts(2027, 6, 15, 10, 0));
    }

    // ============== Edge cases ==============

    #[test]
    fn invalid_schedule_time_falls_back_to_default() {
        // schedule_time = "invalid" → parse 失败回退到 (3, 0)
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "invalid".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 0), &prefs);
        // 回退到 03:00，今天 10:00 已过 → 明天 03:00
        assert_eq!(next, ts(2026, 7, 21, 3, 0));
    }

    #[test]
    fn calculate_returns_timestamp_in_future() {
        // 一般情况下，下次备份时间应大于当前时间（除非 Off）
        let mut prefs = make_prefs(ScheduleType::Hourly);
        prefs.schedule_minute = 30;
        let now = ts(2026, 7, 20, 10, 0);
        let next = calculate_next_backup_at(now, &prefs);
        assert!(next > now, "next_backup_at 应大于 now");
    }

    // ============== F89：本地时区语义 ==============

    #[test]
    fn daily_target_is_local_wall_clock_not_utc() {
        // F89 复现口径：每日 03:00 必须落在本地 03:00（修复前会被当作 UTC 03:00，
        // 在 UTC+8 机器上实际 11:00 本地触发）
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "03:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 20, 10, 0), &prefs);
        let local = Local.timestamp_opt(next, 0).single().unwrap();
        assert_eq!((local.hour(), local.minute()), (3, 0), "应落在本地 03:00");
        assert_eq!(
            local.date_naive(),
            chrono::NaiveDate::from_ymd_opt(2026, 7, 21).unwrap()
        );
    }

    #[test]
    fn monthly_target_day_is_local_calendar_day() {
        // 日期语义也按本地日历：每月 15 日 03:00 不能落到本地 14 日（UTC-5 时区的旧缺陷形态）
        let mut prefs = make_prefs(ScheduleType::Monthly);
        prefs.schedule_day_of_month = 15;
        prefs.schedule_time = "03:00".to_string();
        let next = calculate_next_backup_at(ts(2026, 7, 10, 9, 0), &prefs);
        let local = Local.timestamp_opt(next, 0).single().unwrap();
        assert_eq!(
            local.date_naive(),
            chrono::NaiveDate::from_ymd_opt(2026, 7, 15).unwrap()
        );
        assert_eq!((local.hour(), local.minute()), (3, 0));
    }

    // ============== DST 边界（America/New_York 注入，脱离本机时区） ==============
    //
    // 美东 2026：春季跳变 03-08 02:00→03:00（02:30 不存在）；
    // 秋季回拨 11-01 02:00→01:00（01:30 出现两次）。
    // now 输入用 UTC 构造（这些瞬间无歧义），期望值也用 UTC 构造，避免与实现同义反复。

    #[test]
    fn dst_spring_gap_target_defers_to_first_existing_instant() {
        // 每日 02:30 落在春季跳变空隙里 → 顺延到跳变后首个存在时刻（03:00 EDT = 07:00Z）
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "02:30".to_string();
        let now = Utc
            .with_ymd_and_hms(2026, 3, 8, 5, 0, 0)
            .single()
            .unwrap()
            .timestamp(); // 00:00 EST
        let next = calculate_next_backup_at_in(now, &prefs, &New_York);
        assert_eq!(
            next,
            Utc.with_ymd_and_hms(2026, 3, 8, 7, 0, 0)
                .single()
                .unwrap()
                .timestamp()
        );
    }

    #[test]
    fn dst_fall_ambiguous_target_takes_first_occurrence() {
        // 每日 01:30 在回拨日出现两次 → 取第一次（EDT = 05:30Z），不取第二次（06:30Z）
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "01:30".to_string();
        let now = Utc
            .with_ymd_and_hms(2026, 11, 1, 4, 0, 0)
            .single()
            .unwrap()
            .timestamp(); // 00:00 EDT
        let next = calculate_next_backup_at_in(now, &prefs, &New_York);
        assert_eq!(
            next,
            Utc.with_ymd_and_hms(2026, 11, 1, 5, 30, 0)
                .single()
                .unwrap()
                .timestamp()
        );
    }

    #[test]
    fn dst_calendar_day_advance_keeps_wall_clock() {
        // 跨跳变推进必须按「日历日 +1」而非「绝对 +24h」：
        // 03-07 15:00 EST 已过当日 03:00 → 下次应是 03-08 03:00 EDT = 07:00Z。
        // 若按绝对 +24h 会得到 08:00Z（本地 04:00），挂钟漂 1 小时。
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "03:00".to_string();
        let now = Utc
            .with_ymd_and_hms(2026, 3, 7, 20, 0, 0)
            .single()
            .unwrap()
            .timestamp(); // 15:00 EST
        let next = calculate_next_backup_at_in(now, &prefs, &New_York);
        assert_eq!(
            next,
            Utc.with_ymd_and_hms(2026, 3, 8, 7, 0, 0)
                .single()
                .unwrap()
                .timestamp()
        );
    }

    #[test]
    fn dst_fall_back_day_advance_keeps_wall_clock() {
        // 回拨日反向验证：10-31 15:00 EDT 已过当日 03:00 → 11-01 03:00 EST = 08:00Z。
        // 若按绝对 +24h 会得到 07:00Z（本地 02:00 EST→ 实为 03:00 EDT 挂钟）错位。
        let mut prefs = make_prefs(ScheduleType::Daily);
        prefs.schedule_time = "03:00".to_string();
        let now = Utc
            .with_ymd_and_hms(2026, 10, 31, 19, 0, 0)
            .single()
            .unwrap()
            .timestamp(); // 15:00 EDT
        let next = calculate_next_backup_at_in(now, &prefs, &New_York);
        assert_eq!(
            next,
            Utc.with_ymd_and_hms(2026, 11, 1, 8, 0, 0)
                .single()
                .unwrap()
                .timestamp()
        );
    }
}
