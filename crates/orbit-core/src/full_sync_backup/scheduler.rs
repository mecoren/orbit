//! scheduler — 调度器核心逻辑（v4 新增）
//!
//! 提供 `calculate_next_backup_at` 纯函数，根据当前时间与 `BackupPrefs` 计算下一次
//! 备份触发时间戳（Unix 秒）。桌面端 Tauri managed state 与移动端 Riverpod provider
//! 共用此函数，保证双端调度行为一致。
//!
//! 调度规则：
//! - off：返回 0（不调度）
//! - hourly：当前时间向上取整到下一个 schedule_minute 分（如 10:23 + minute=30 → 10:30）
//! - daily：明天 schedule_time
//! - weekly：下一个 schedule_weekday 的 schedule_time
//! - monthly：下一个 schedule_day_of_month 的 schedule_time
//! - yearly：下一个 schedule_month/day_of_month 的 schedule_time

use chrono::{DateTime, Datelike, TimeZone, Timelike, Utc};

use crate::full_sync_backup::backup_prefs::{BackupPrefs, ScheduleType};

/// 计算下一次备份触发时间戳（Unix 秒）
///
/// 返回 0 表示不调度（schedule_type == Off）
pub fn calculate_next_backup_at(now_ts: i64, prefs: &BackupPrefs) -> i64 {
    if prefs.schedule_type == ScheduleType::Off {
        return 0;
    }

    let now = DateTime::<Utc>::from_timestamp(now_ts, 0).unwrap_or_else(Utc::now);
    let (h, m) = BackupPrefs::parse_schedule_time(&prefs.schedule_time).unwrap_or((3, 0));

    let next = match prefs.schedule_type {
        ScheduleType::Off => return 0,
        ScheduleType::Hourly => next_hourly(&now, prefs.schedule_minute),
        ScheduleType::Daily => next_daily(&now, h, m),
        ScheduleType::Weekly => next_weekly(&now, prefs.schedule_weekday, h, m),
        ScheduleType::Monthly => next_monthly(&now, prefs.schedule_day_of_month, h, m),
        ScheduleType::Yearly => next_yearly(
            &now,
            prefs.schedule_month,
            prefs.schedule_day_of_month,
            h,
            m,
        ),
    };

    next.timestamp()
}

/// hourly：向上取整到下一个 schedule_minute 分
///
/// 例：
/// - 10:23:00 + minute=30 → 10:30:00
/// - 10:31:00 + minute=30 → 11:30:00
/// - 10:30:00 + minute=30 → 11:30:00（当前分钟已过，取下一个）
fn next_hourly(now: &DateTime<Utc>, minute: u32) -> DateTime<Utc> {
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

/// daily：明天 schedule_time
fn next_daily(now: &DateTime<Utc>, h: u32, m: u32) -> DateTime<Utc> {
    let today_target = now
        .with_hour(h)
        .unwrap_or(*now)
        .with_minute(m)
        .unwrap_or(*now)
        .with_second(0)
        .unwrap_or(*now)
        .with_nanosecond(0)
        .unwrap_or(*now);

    if today_target > *now {
        today_target
    } else {
        today_target + chrono::Duration::days(1)
    }
}

/// weekly：下一个 schedule_weekday 的 schedule_time
///
/// weekday: 0=周日, 1=周一, ..., 6=周六（与 chrono::Weekday::num_days_from_sunday 一致）
fn next_weekly(now: &DateTime<Utc>, target_weekday: u32, h: u32, m: u32) -> DateTime<Utc> {
    let current_weekday = now.weekday().num_days_from_sunday();
    let mut days_ahead = (target_weekday as i64 - current_weekday as i64 + 7) % 7;

    let today_target = now
        .with_hour(h)
        .unwrap_or(*now)
        .with_minute(m)
        .unwrap_or(*now)
        .with_second(0)
        .unwrap_or(*now)
        .with_nanosecond(0)
        .unwrap_or(*now);

    // 如果是同一天但时间已过，则推到下周
    if days_ahead == 0 && today_target <= *now {
        days_ahead = 7;
    }

    today_target + chrono::Duration::days(days_ahead)
}

/// monthly：下一个 schedule_day_of_month 的 schedule_time
///
/// day_of_month 限制 1-28（由 validate_schedule 保证），避免月末歧义
fn next_monthly(now: &DateTime<Utc>, target_day: u32, h: u32, m: u32) -> DateTime<Utc> {
    let today_target = build_target_this_month(now, target_day, h, m);

    if let Some(target) = today_target
        && target > *now
    {
        return target;
    }

    // 当前月的目标日已过，取下个月同一天
    let next_month_date = next_month_same_day(now, target_day);
    build_target_at_date(next_month_date, h, m)
}

/// yearly：下一个 schedule_month/day_of_month 的 schedule_time
fn next_yearly(now: &DateTime<Utc>, month: u32, day: u32, h: u32, m: u32) -> DateTime<Utc> {
    let this_year_target = build_target_this_year(now, month, day, h, m);

    if let Some(target) = this_year_target
        && target > *now
    {
        return target;
    }

    // 今年的目标已过，取明年同月同日
    let next_year = now.year() + 1;
    Utc.with_ymd_and_hms(next_year, month, day, h, m, 0)
        .single()
        .unwrap_or_else(|| {
            // 极端情况下日期无效（不应该发生，因 day 限制 1-28），回退到下一年同月第一天
            Utc.with_ymd_and_hms(next_year, month, 1, h, m, 0)
                .single()
                .unwrap_or(*now)
        })
}

/// 构造本月 target_day 的目标时刻；若日期无效返回 None
fn build_target_this_month(
    now: &DateTime<Utc>,
    target_day: u32,
    h: u32,
    m: u32,
) -> Option<DateTime<Utc>> {
    Utc.with_ymd_and_hms(now.year(), now.month(), target_day, h, m, 0)
        .single()
}

/// 构造今年 month/day 的目标时刻；若日期无效返回 None
fn build_target_this_year(
    now: &DateTime<Utc>,
    month: u32,
    day: u32,
    h: u32,
    m: u32,
) -> Option<DateTime<Utc>> {
    Utc.with_ymd_and_hms(now.year(), month, day, h, m, 0)
        .single()
}

/// 构造下个月同一天的时刻
fn next_month_same_day(now: &DateTime<Utc>, target_day: u32) -> chrono::NaiveDate {
    let year = now.year();
    let month = now.month();

    let (next_year, next_month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };

    // target_day 限制 1-28，所有月份都有 28 天，不会失败
    chrono::NaiveDate::from_ymd_opt(next_year, next_month, target_day)
        .unwrap_or_else(|| chrono::NaiveDate::from_ymd_opt(next_year, next_month, 1).unwrap())
}

/// 在指定日期构造目标时刻
fn build_target_at_date(date: chrono::NaiveDate, h: u32, m: u32) -> DateTime<Utc> {
    let dt = date
        .and_hms_opt(h, m, 0)
        .unwrap_or_else(|| date.and_hms_opt(0, 0, 0).unwrap());
    DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(year: i32, month: u32, day: u32, hour: u32, min: u32) -> i64 {
        Utc.with_ymd_and_hms(year, month, day, hour, min, 0)
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
}
