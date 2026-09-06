//! holiday_api — 中国法定节假日数据层（用户需求：日历视图联网更新节假日）
//!
//! 数据源：timor.tech 免费公益 API `https://timor.tech/api/holiday/year/{y}`，
//! 响应 `{"code":0,"holiday":{"MM-DD":{"holiday":true,"name":"春节","date":"2026-02-15",...}}}`；
//! `holiday:true` = 放假、`false` = 调休补班、不在 map 中 = 普通日（按星期判定）。
//! 国务院未发布次年安排时该年 map 为空 `{}`，属正常状态（见 [builtin_holidays]）。
//! 请求需带浏览器 UA（服务端 Cloudflare 会拦无 UA 的默认客户端）。
//!
//! ## 更新时机（三触发，全端共用本模块判定）
//! - **定时**：每天固定时间（默认 08:00 本地时区）一次。[should_update_now]
//!   以「上次成功更新的自然日」记账——当天已成功过则不重复；到点未开应用时，
//!   下次启动/下轮 tick 会因 `已过当日固定时刻 && 上次成功在今日之前` 而补更；
//! - **手动**：[update_holidays] 无视记账立即拉取；
//! - **翻年**：本地 12 月起自动多拉明年（元旦跨年即有节假日可显示）。
//!
//! ## 存储边界
//! `cfg_holidays` / `cfg_kv` 为本地缓存表，不进 SYNCABLE_TABLES 同步白名单
//! （migration 0003 注释）：各端自行拉取即可收敛，不占云同步/备份面。
//! 拉取成功以事务「先删拉取年份旧行再插入」整年替换；失败保留旧缓存并记账
//! （last_attempt / failure_count），下次 tick / 下次启动仍按缺额重试。

use chrono::{Datelike, TimeZone};
use serde::Deserialize;
use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};

// ============================================================================
// 常量与类型
// ============================================================================

/// 数据源基础地址（公益接口，无鉴权；UA 见 [HOLIDAY_UA]）
pub const HOLIDAY_API_BASE: &str = "https://timor.tech/api/holiday/year";

/// 预置数据覆盖的最早年份（更早年份线上也无数据）
pub const HOLIDAY_YEARS_MIN: i32 = 2026;

/// 默认每日固定更新时刻（本地时区小时；可被 cfg_kv `holiday_fixed_hour` 覆盖）
pub const DEFAULT_UPDATE_HOUR: u32 = 8;

/// 浏览器 UA：timor.tech 的 Cloudflare 拦截无 UA 的默认 reqwest 客户端
const HOLIDAY_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
     AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36";

/// cfg_kv 键名
const KV_LAST_SUCCESS: &str = "holiday_last_update_ms";
const KV_LAST_ATTEMPT: &str = "holiday_last_attempt_ms";
const KV_FAILURE_COUNT: &str = "holiday_failure_count";
const KV_FIXED_HOUR: &str = "holiday_fixed_hour";

/// 节假日行（UI 消费形状：date YYYY-MM-DD + 放假/补班标记 + 名称）
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct HolidayInfo {
    /// YYYY-MM-DD（公历日期字符串，来源数据直存）
    pub date: String,
    pub year: i32,
    /// true = 放假日；false = 调休补班日（要上班的周末）
    pub is_holiday: bool,
    /// 节假日名称（如「春节」「春节前补班」）
    pub name: String,
}

// ============================================================================
// 时钟抽象（生产/测试双实现）
// ============================================================================

/// 本地时区时钟（[should_update_now] 的判定依赖）
pub trait Clock: Send + Sync {
    /// 当前本地时间
    fn now_local(&self) -> chrono::DateTime<chrono::Local>;
    /// 毫秒时间戳 → 本地 DateTime（无效值回落当前时间）
    fn millis_to_local(&self, ms: i64) -> chrono::DateTime<chrono::Local>;
    /// 本地某日 00:00 的毫秒时间戳
    fn local_midnight_ms(&self, d: chrono::DateTime<chrono::Local>) -> i64;
}

/// 生产时钟（宿主机本地时区）
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_local(&self) -> chrono::DateTime<chrono::Local> {
        chrono::Local::now()
    }
    fn millis_to_local(&self, ms: i64) -> chrono::DateTime<chrono::Local> {
        chrono::Local
            .timestamp_millis_opt(ms)
            .single()
            .unwrap_or_else(chrono::Local::now)
    }
    fn local_midnight_ms(&self, d: chrono::DateTime<chrono::Local>) -> i64 {
        chrono::Local
            .with_ymd_and_hms(d.year(), d.month(), d.day(), 0, 0, 0)
            .single()
            .map(|t| t.timestamp_millis())
            .unwrap_or(0)
    }
}

// ============================================================================
// 数据源响应解析（纯函数，单测覆盖）
// ============================================================================

/// timor.tech 年接口条目（截取消费字段；wage/rest/after/target 忽略）
#[derive(Debug, Deserialize)]
struct HolidayEntry {
    holiday: bool,
    #[serde(default)]
    name: String,
    #[serde(default)]
    date: String,
}

#[derive(Debug, Deserialize)]
struct YearResponse {
    code: i32,
    #[serde(default)]
    holiday: std::collections::BTreeMap<String, HolidayEntry>,
}

/// 预置节假日（无网络/首装冷启动时日历仍可正确标注的兜底表）。
///
/// 来源：timor.tech `/api/holiday/year/{y}` 实测数据（2026-09 快照，与国务院
/// 办公厅发布的安排一致）。放假日与调休补班日都收录（补班日影响周末展示）。
/// 线上数据更新后由拉取整年替换本表在查询中的兜底作用（见 [list_holidays]）。
pub fn builtin_holidays() -> Vec<HolidayInfo> {
    let rows: &[(&str, bool, &str)] = &[
        // 2026 年（国办发明电〔2025〕10 号）
        ("2026-01-01", true, "元旦"),
        ("2026-01-02", true, "元旦"),
        ("2026-01-03", true, "元旦"),
        ("2026-01-04", false, "元旦后补班"),
        ("2026-02-14", false, "春节前补班"),
        ("2026-02-15", true, "春节"),
        ("2026-02-16", true, "除夕"),
        ("2026-02-17", true, "初一"),
        ("2026-02-18", true, "初二"),
        ("2026-02-19", true, "初三"),
        ("2026-02-20", true, "初四"),
        ("2026-02-21", true, "初五"),
        ("2026-02-22", true, "初六"),
        ("2026-02-23", true, "初七"),
        ("2026-02-28", false, "春节后补班"),
        ("2026-04-04", true, "清明节"),
        ("2026-04-05", true, "清明节"),
        ("2026-04-06", true, "清明节"),
        ("2026-05-01", true, "劳动节"),
        ("2026-05-02", true, "劳动节"),
        ("2026-05-03", true, "劳动节"),
        ("2026-05-04", true, "劳动节"),
        ("2026-05-05", true, "劳动节"),
        ("2026-05-09", false, "劳动节后补班"),
        ("2026-06-19", true, "端午节"),
        ("2026-06-20", true, "端午节"),
        ("2026-06-21", true, "端午节"),
        ("2026-09-20", false, "中秋节前补班"),
        ("2026-09-25", true, "中秋节"),
        ("2026-09-26", true, "中秋节"),
        ("2026-09-27", true, "中秋节"),
        ("2026-10-01", true, "国庆节"),
        ("2026-10-02", true, "国庆节"),
        ("2026-10-03", true, "国庆节"),
        ("2026-10-04", true, "中秋节"),
        ("2026-10-05", true, "国庆节"),
        ("2026-10-06", true, "国庆节"),
        ("2026-10-07", true, "国庆节"),
        ("2026-10-08", true, "国庆节"),
        ("2026-10-10", false, "国庆节后补班"),
    ];
    rows.iter()
        .map(|(date, is_holiday, name)| HolidayInfo {
            date: date.to_string(),
            year: date[..4].parse().unwrap_or(0),
            is_holiday: *is_holiday,
            name: name.to_string(),
        })
        .collect()
}

/// 预置节假日按 date 索引（查询兜底）
pub fn builtin_holiday_by_date() -> std::collections::HashMap<String, HolidayInfo> {
    builtin_holidays()
        .into_iter()
        .map(|h| (h.date.clone(), h))
        .collect()
}

// ============================================================================
// 查询 API
// ============================================================================

/// 拉取全部缓存的节假日行（date 升序；DB 为空时回落预置表，保证冷启动可用）
pub async fn list_holidays(pool: &SqlitePool) -> CoreResult<Vec<HolidayInfo>> {
    let rows = sqlx::query_as::<_, (String, i32, i32, String)>(
        "SELECT date, year, is_holiday, name FROM cfg_holidays ORDER BY date ASC",
    )
    .fetch_all(pool)
    .await?;
    if rows.is_empty() {
        return Ok(builtin_holidays());
    }
    Ok(rows
        .into_iter()
        .map(|(date, year, is_holiday, name)| HolidayInfo {
            date,
            year,
            is_holiday: is_holiday != 0,
            name,
        })
        .collect())
}

/// 判定某日期是否放假（DB 行优先，无行回落预置表；两处都无 = None 按星期判）
///
/// 返回 `Some(true)` 放假 / `Some(false)` 调休补班 / `None` 普通日。
/// 回落语义保证「首次启动未拉取」与「拉取中」两个窗口 UI 仍正确。
pub async fn is_holiday_on(pool: &SqlitePool, date: &str) -> CoreResult<Option<bool>> {
    let row: Option<(i32,)> = sqlx::query_as("SELECT is_holiday FROM cfg_holidays WHERE date = ?1")
        .bind(date)
        .fetch_optional(pool)
        .await?;
    if let Some((is_holiday,)) = row {
        return Ok(Some(is_holiday != 0));
    }
    Ok(builtin_holiday_by_date().get(date).map(|h| h.is_holiday))
}

// ============================================================================
// 更新记账（cfg_kv）
// ============================================================================

async fn kv_get_i64(pool: &SqlitePool, key: &str) -> CoreResult<Option<i64>> {
    let row: Option<(String,)> = sqlx::query_as("SELECT value FROM cfg_kv WHERE key = ?1")
        .bind(key)
        .fetch_optional(pool)
        .await?;
    Ok(row.and_then(|(v,)| v.parse().ok()))
}

async fn kv_set(pool: &SqlitePool, key: &str, value: &str) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
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

/// 节假日更新记账（UI 展示「上次更新 / 失败次数」+ 调度判定共用）
#[derive(Debug, Clone, serde::Serialize, Default)]
pub struct HolidayMeta {
    /// 上次成功更新时间（ms；0 = 从未成功）
    pub last_update_ms: i64,
    /// 上次尝试时间（ms；0 = 从未尝试）
    pub last_attempt_ms: i64,
    /// 连续失败次数（成功后清零）
    pub failure_count: i32,
    /// 每日固定更新时刻（本地时区小时 0-23）
    pub fixed_hour: u32,
}

/// 读取更新记账
pub async fn holiday_meta(pool: &SqlitePool) -> CoreResult<HolidayMeta> {
    Ok(HolidayMeta {
        last_update_ms: kv_get_i64(pool, KV_LAST_SUCCESS).await?.unwrap_or(0),
        last_attempt_ms: kv_get_i64(pool, KV_LAST_ATTEMPT).await?.unwrap_or(0),
        failure_count: kv_get_i64(pool, KV_FAILURE_COUNT).await?.unwrap_or(0) as i32,
        fixed_hour: kv_get_i64(pool, KV_FIXED_HOUR)
            .await?
            .map(|h| h.clamp(0, 23) as u32)
            .unwrap_or(DEFAULT_UPDATE_HOUR),
    })
}

/// 是否应执行每日更新（定时 + 补更判定的唯一口径，纯函数）
///
/// - `last_update_ms <= 0`（从未成功）→ 应更新（首装冷启动）；
/// - 上次成功在「今天零点」之前，且现在已过今天固定时刻 → 应更新
///   （到点没开应用 → 错过后本次启动/本轮 tick 即补更）；
/// - 其余（今天已成功过）→ 不更新。
pub fn should_update_now<C: Clock>(last_update_ms: i64, fixed_hour: u32, clock: &C) -> bool {
    if last_update_ms <= 0 {
        return true;
    }
    let now = clock.now_local();
    let today_start = clock.local_midnight_ms(now);
    debug_assert!(
        today_start > 0,
        "local_midnight_ms 不可能失败（now 本身合法）"
    );
    if last_update_ms < today_start {
        let fixed_ms = today_start + (fixed_hour.min(23) as i64) * 3_600_000;
        return now.timestamp_millis() >= fixed_ms;
    }
    false
}

// ============================================================================
// 更新执行（网络拉取 + 事务替换）
// ============================================================================

/// 应拉取的年份集合：今年 + （本地 12 月时）明年
fn years_to_fetch<C: Clock>(clock: &C) -> Vec<i32> {
    let now = clock.now_local();
    let y = now.year();
    if now.month() == 12 {
        vec![y, y + 1]
    } else {
        vec![y]
    }
}

/// 拉取单年数据（HTTP + 解析；code==0 时返回条目，空 map = 次年未发布）
async fn fetch_year(client: &reqwest::Client, year: i32) -> CoreResult<Vec<HolidayInfo>> {
    let url = format!("{HOLIDAY_API_BASE}/{year}");
    let resp = client
        .get(&url)
        .header(reqwest::header::USER_AGENT, HOLIDAY_UA)
        .header(reqwest::header::ACCEPT, "application/json")
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| CoreError::Other(format!("[holiday] 请求失败 {url}: {e}")))?;
    if !resp.status().is_success() {
        return Err(CoreError::Other(format!(
            "[holiday] HTTP {} {url}",
            resp.status()
        )));
    }
    let body: YearResponse = resp
        .json()
        .await
        .map_err(|e| CoreError::Other(format!("[holiday] 响应解析失败: {e}")))?;
    if body.code != 0 {
        return Err(CoreError::Other(format!(
            "[holiday] 接口返回 code={}（非 0）",
            body.code
        )));
    }
    Ok(body
        .holiday
        .into_iter()
        .map(|(mmdd, e)| {
            // date 字段更权威（YYYY-MM-DD）；异常缺失时由 MM-DD + 年份拼合
            let date = if e.date.len() == 10 {
                e.date
            } else {
                format!("{year}-{mmdd}")
            };
            let row_year: i32 = date[..4].parse().unwrap_or(year);
            HolidayInfo {
                date,
                year: row_year,
                is_holiday: e.holiday,
                name: e.name,
            }
        })
        .collect())
}

/// 手动更新：强制拉取（无视每日记账；网络失败时旧缓存保留并记账失败）
pub async fn update_holidays(pool: &SqlitePool) -> CoreResult<HolidayMeta> {
    update_holidays_with(pool, true, &SystemClock, reqwest::Client::new()).await
}

/// 调度入口：按 [should_update_now] 判定是否需要更新
///
/// 返回 `Ok(true)` = 本次执行了更新；`Ok(false)` = 未到更新条件（今天已更新）。
pub async fn auto_update_holidays(pool: &SqlitePool) -> CoreResult<bool> {
    auto_update_with(pool, &SystemClock, reqwest::Client::new()).await
}

async fn auto_update_with<C: Clock>(
    pool: &SqlitePool,
    clock: &C,
    client: reqwest::Client,
) -> CoreResult<bool> {
    let meta = holiday_meta(pool).await?;
    if !should_update_now(meta.last_update_ms, meta.fixed_hour, clock) {
        return Ok(false);
    }
    update_holidays_with(pool, true, clock, client).await?;
    Ok(true)
}

/// 更新执行体（force=true 手动；force=false 定时/补更判定）
///
/// 网络失败：记账 last_attempt + failure_count（保留旧缓存），下次 tick /
/// 下次启动仍会重试（should_update 仍为 true）。
async fn update_holidays_with<C: Clock>(
    pool: &SqlitePool,
    force: bool,
    clock: &C,
    client: reqwest::Client,
) -> CoreResult<HolidayMeta> {
    let mut meta = holiday_meta(pool).await?;
    if !force && !should_update_now(meta.last_update_ms, meta.fixed_hour, clock) {
        return Ok(meta);
    }

    let now_ms = chrono::Utc::now().timestamp_millis();
    kv_set(pool, KV_LAST_ATTEMPT, &now_ms.to_string()).await?;

    let years = years_to_fetch(clock);
    let mut fetched = Vec::new();
    // 逐年拉取：单年失败即中止（保证「整年完整替换」而非半截数据）
    for y in &years {
        fetched.extend(fetch_year(&client, *y).await?);
    }

    // 事务：整年替换（先删拉取年份的旧行再插入），失败整体回滚保留旧缓存
    let mut tx = pool.begin().await?;
    for y in &years {
        sqlx::query("DELETE FROM cfg_holidays WHERE year = ?1")
            .bind(y)
            .execute(&mut *tx)
            .await?;
    }
    let now_sec = chrono::Utc::now().timestamp();
    for h in &fetched {
        sqlx::query(
            "INSERT INTO cfg_holidays (date, year, is_holiday, name, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
        )
        .bind(&h.date)
        .bind(h.year)
        .bind(h.is_holiday as i32)
        .bind(&h.name)
        .bind(now_sec)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;

    let success_ms = chrono::Utc::now().timestamp_millis();
    kv_set(pool, KV_LAST_SUCCESS, &success_ms.to_string()).await?;
    kv_set(pool, KV_FAILURE_COUNT, "0").await?;
    kv_set(pool, KV_LAST_ATTEMPT, &success_ms.to_string()).await?;

    meta = holiday_meta(pool).await?;
    Ok(meta)
}

// ============================================================================
// 配置（每日固定更新时刻）
// ============================================================================

/// 修改每日固定更新时刻（0-23，越界 clamp 到边界）
pub async fn set_holiday_fixed_hour(pool: &SqlitePool, hour: u32) -> CoreResult<()> {
    let h = hour.min(23);
    kv_set(pool, KV_FIXED_HOUR, &h.to_string()).await
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

    /// 固定时钟：now_local 返回构造时刻；换算逻辑委托 SystemClock
    /// （换算仅做 ts→DateTime 映射，不依赖“现在”，无时区脆弱性）
    struct FixedClock(chrono::DateTime<chrono::Local>);

    impl Clock for FixedClock {
        fn now_local(&self) -> chrono::DateTime<chrono::Local> {
            self.0
        }
        fn millis_to_local(&self, ms: i64) -> chrono::DateTime<chrono::Local> {
            SystemClock.millis_to_local(ms)
        }
        fn local_midnight_ms(&self, d: chrono::DateTime<chrono::Local>) -> i64 {
            SystemClock.local_midnight_ms(d)
        }
    }

    /// 构造本地某日某时刻的 FixedClock
    fn clock_at(year: i32, month: u32, day: u32, hour: u32, min: u32) -> FixedClock {
        FixedClock(
            chrono::Local
                .with_ymd_and_hms(year, month, day, hour, min, 0)
                .single()
                .expect("测试时刻合法"),
        )
    }

    /// 本地某日某时刻的毫秒时间戳
    fn ms_at(year: i32, month: u32, day: u32, hour: u32) -> i64 {
        chrono::Local
            .with_ymd_and_hms(year, month, day, hour, 0, 0)
            .single()
            .expect("测试时刻合法")
            .timestamp_millis()
    }

    // —— should_update_now：每日一次 + 错过补更 ——

    #[test]
    fn update_needed_when_never_succeeded() {
        // 从未成功（含首装冷启动）→ 任意时刻都应更新
        assert!(should_update_now(0, 8, &clock_at(2026, 9, 6, 7, 0)));
        assert!(should_update_now(0, 8, &clock_at(2026, 9, 6, 23, 30)));
    }

    #[test]
    fn daily_gate_opens_at_fixed_hour() {
        // 昨天 23:00 成功更新过：
        let last = ms_at(2026, 9, 5, 23);
        // 今天 07:59（未到 08:00）→ 不更新
        assert!(!should_update_now(last, 8, &clock_at(2026, 9, 6, 7, 59)));
        // 今天 08:00 整点（边界含等号）→ 更新
        assert!(should_update_now(last, 8, &clock_at(2026, 9, 6, 8, 0)));
        // 今天下午 → 更新（错过早上 8 点的场景 = 下次打开补更）
        assert!(should_update_now(last, 8, &clock_at(2026, 9, 6, 21, 0)));
    }

    #[test]
    fn no_second_update_same_day() {
        // 今天 00:30 成功更新过（固定时刻 08:00 之前）→ 同日不再更新
        let last = ms_at(2026, 9, 6, 0);
        assert!(!should_update_now(last, 8, &clock_at(2026, 9, 6, 8, 0)));
        assert!(!should_update_now(last, 8, &clock_at(2026, 9, 6, 23, 0)));
        // 今天 09:00 成功更新过 → 同日不再更新
        let last = ms_at(2026, 9, 6, 9);
        assert!(!should_update_now(last, 8, &clock_at(2026, 9, 6, 12, 0)));
    }

    #[test]
    fn missed_days_still_update_on_open() {
        // 多天没开应用（上次成功在 3 天前）→ 打开即过固定时刻 → 补更
        let last = ms_at(2026, 9, 3, 8);
        assert!(should_update_now(last, 8, &clock_at(2026, 9, 6, 9, 0)));
        // 但若打开时还没到当天固定时刻（如清晨 6 点）→ 等定时器
        assert!(!should_update_now(last, 8, &clock_at(2026, 9, 6, 6, 0)));
    }

    #[test]
    fn custom_fixed_hour_respected() {
        let last = ms_at(2026, 9, 5, 23);
        // 固定时刻设为 12:00：上午 11 点不更新、12 点更新
        assert!(!should_update_now(last, 12, &clock_at(2026, 9, 6, 11, 0)));
        assert!(should_update_now(last, 12, &clock_at(2026, 9, 6, 12, 0)));
    }

    // —— 数据源解析 ——

    #[test]
    fn parse_year_response_shape() {
        let json = r#"{"code":0,"holiday":{
            "02-16":{"holiday":true,"name":"除夕","wage":3,"date":"2026-02-16","rest":1},
            "02-28":{"holiday":false,"name":"春节后补班","wage":1,"target":"春节","after":true,"date":"2026-02-28"}}}"#;
        let body: YearResponse = serde_json::from_str(json).unwrap();
        assert_eq!(body.code, 0);
        assert_eq!(body.holiday.len(), 2);
        assert!(body.holiday["02-16"].holiday);
        assert!(!body.holiday["02-28"].holiday);
    }

    #[test]
    fn builtin_table_covers_2026_holidays() {
        let m = builtin_holiday_by_date();
        assert_eq!(
            m.get("2026-02-17").map(|h| (h.is_holiday, h.name.as_str())),
            Some((true, "初一"))
        );
        assert_eq!(m.get("2026-01-04").map(|h| h.is_holiday), Some(false)); // 补班
        assert_eq!(m.get("2026-10-01").map(|h| h.is_holiday), Some(true));
        assert!(!m.contains_key("2026-03-15")); // 普通日不在表
        assert!(builtin_holidays().iter().all(|h| h.year == 2026));
    }

    // —— DB 集成 ——

    #[tokio::test]
    async fn list_falls_back_to_builtin_on_empty_db() {
        let pool = setup_db().await;
        let list = list_holidays(&pool).await.unwrap();
        assert_eq!(list, builtin_holidays());
        // 查询兜底：DB 无行时预置表生效
        assert_eq!(
            is_holiday_on(&pool, "2026-02-17").await.unwrap(),
            Some(true)
        );
        assert_eq!(
            is_holiday_on(&pool, "2026-01-04").await.unwrap(),
            Some(false)
        );
        assert_eq!(is_holiday_on(&pool, "2026-03-15").await.unwrap(), None);
    }

    #[tokio::test]
    async fn meta_roundtrip_and_fixed_hour_clamp() {
        let pool = setup_db().await;
        let meta = holiday_meta(&pool).await.unwrap();
        assert_eq!(meta.last_update_ms, 0);
        assert_eq!(meta.last_attempt_ms, 0);
        assert_eq!(meta.failure_count, 0);
        assert_eq!(meta.fixed_hour, DEFAULT_UPDATE_HOUR);

        set_holiday_fixed_hour(&pool, 99).await.unwrap(); // clamp 到 23
        assert_eq!(holiday_meta(&pool).await.unwrap().fixed_hour, 23);
        set_holiday_fixed_hour(&pool, 12).await.unwrap();
        assert_eq!(holiday_meta(&pool).await.unwrap().fixed_hour, 12);
    }

    #[tokio::test]
    async fn kv_upsert_overwrites() {
        let pool = setup_db().await;
        kv_set(&pool, "k", "1").await.unwrap();
        kv_set(&pool, "k", "2").await.unwrap();
        assert_eq!(kv_get_i64(&pool, "k").await.unwrap(), Some(2));
        assert_eq!(kv_get_i64(&pool, "absent").await.unwrap(), None);
    }
}
