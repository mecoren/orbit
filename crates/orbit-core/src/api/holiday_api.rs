//! holiday_api — 中国法定节假日数据层（用户需求：日历视图联网更新节假日）
//!
//! 数据源：timor.tech 免费公益 API `https://timor.tech/api/holiday/year/{y}`，
//! 响应 `{"code":0,"holiday":{"MM-DD":{"holiday":true,"name":"春节","date":"2026-02-15",...}}}`；
//! `holiday:true` = 放假、`false` = 调休补班、不在 map 中 = 普通日（按星期判定）。
//! 国务院未发布次年安排时该年 map 为空 `{}`，属正常状态（见 [builtin_holidays]）。
//! 请求需带浏览器 UA（服务端 Cloudflare 会拦无 UA 的默认客户端）。
//!
//! ## 更新时机（三触发，全端共用本模块判定）
//! - **自动**：每月一次。[should_update_now] 以「上次成功更新的日历月」记账——
//!   跨入新月后首次 tick / 首次启动即拉取；总开关关闭（cfg_kv
//!   `holiday_auto_enabled` = 0）后自动更新彻底不跑，仅保留手动；
//! - **手动**：[update_holidays] 无视记账立即拉取（拉今年；12 月加明年）；
//! - **翻年**：本地 12 月起自动多拉明年（元旦跨年即有节假日可显示）；
//! - **按年补写**：[fetch_holiday_year] / [fetch_holiday_range] 补写
//!   [HOLIDAY_FETCH_YEAR_MIN] ~ [holiday_fetch_year_max] 范围内任意年份，
//!   供设置页「按年份范围获取」与分组标题「更新该年」使用。
//!
//! ## 记账口径（cfg_kv）
//! - `holiday_last_update_ms`：上次「自动更新范围内年份」的成功时间，只作每月
//!   去重依据。补写**历史年份不写**此键（[account_year_success]）——否则会把
//!   本月本该发生的自动更新误判为「本月已成功」而静默跳过；
//! - `holiday_last_attempt_ms`：上次尝试时间（成败都写，供 UI 展示）；
//! - `holiday_failure_count`：连续失败次数（成功后清零）；
//! - `holiday_auto_enabled`：自动更新总开关（缺省 1 = 开）。
//!
//! ## 存储边界
//! `cfg_holidays` / `cfg_kv` 为本地缓存表，不进 SYNCABLE_TABLES 同步白名单：
//! 各端自行拉取即可收敛，不占云同步/备份面。拉取成功以事务「先删拉取年份旧行
//! 再插入」整年替换；失败保留旧缓存并记账，下次 tick / 下次启动仍按缺额重试。
//!
//! ## 读取兜底（按年合并）
//! [list_holidays] / [is_holiday_on] 以「年」为粒度合并 DB 与预置表：DB 已覆盖
//! 的年份完全以 DB 为准，预置表只兜底 DB 未覆盖的年份——避免补写历史年份后
//! 预置年份的休/班徽标整体消失。
//!
//! ## 进度与取消（范围补写专用）
//! 范围补写通过独立于 [crate::eventbus] 的广播通道（[subscribe_holiday_progress]）
//! 回传逐年进度；[cancel_holiday_range_fetch] 可中途取消（颗粒无收时记账原样
//! 恢复）。**只读缓存表不 emit DbEvent**，故不复用事件总线。

use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use chrono::{Datelike, TimeZone};
use futures::future::join_all;
use once_cell::sync::Lazy;
use serde::Deserialize;
use sqlx::SqlitePool;
use tokio::sync::broadcast;

use crate::error::{CoreError, CoreResult};

// ============================================================================
// 常量与类型
// ============================================================================

/// 数据源基础地址（公益接口，无鉴权；UA 见 [HOLIDAY_UA]）
pub const HOLIDAY_API_BASE: &str = "https://timor.tech/api/holiday/year";

/// 预置兜底表覆盖的年份（[builtin_holidays] 只有这一年的数据）
///
/// 注意与 [HOLIDAY_FETCH_YEAR_MIN] 区分：本常量是「预置数据范围」，
/// 后者是「按年补写的可选下界」。
pub const HOLIDAY_BUILTIN_YEAR: i32 = 2026;

/// 按年补写的可选下界：timor.tech 实测有数据的最早年份
/// （2000 / 2007 / 2008 / 2010 / 2012 均返回空，2013 起完整）。
/// 下界之前的年份请求必空，故 UI 不让用户选到。
pub const HOLIDAY_FETCH_YEAR_MIN: i32 = 2013;

/// 按年补写的可选上界 = 明年（与 [years_to_fetch] 的 12 月跨年口径一致）
pub fn holiday_fetch_year_max(now_year: i32) -> i32 {
    now_year + 1
}

/// 常规请求超时（自动 / 手动更新）
const REQ_TIMEOUT: Duration = Duration::from_secs(20);

/// 范围补写的单年请求超时：批量场景单年卡 20s 会拖住整片，10s 足够返回 KB 级 JSON
const RANGE_REQ_TIMEOUT: Duration = Duration::from_secs(10);

/// 范围补写并发度：分片并发（落库仍串行）；保守取 4 避免公益接口限流
const RANGE_CONCURRENCY: usize = 4;

/// 连续失败这么多次后熔断剩余年份：网络已断的典型信号，
/// 再等下去只是把剩余年份逐个等到超时（18 年 × 10s ≈ 3 分钟白等）
const RANGE_ABORT_AFTER: u32 = 3;

/// 进度通道容量：单次范围操作年份数最多 20（2013..now+1），64 足够
pub const HOLIDAY_PROGRESS_CAPACITY: usize = 64;

/// 浏览器 UA：timor.tech 的 Cloudflare 拦截无 UA 的默认 reqwest 客户端
const HOLIDAY_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
     AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36";

/// cfg_kv 键名
const KV_LAST_SUCCESS: &str = "holiday_last_update_ms";
const KV_LAST_ATTEMPT: &str = "holiday_last_attempt_ms";
const KV_FAILURE_COUNT: &str = "holiday_failure_count";
const KV_AUTO_ENABLED: &str = "holiday_auto_enabled";

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

/// 节假日更新记账（UI 展示「上次更新 / 失败次数 / 自动开关」+ 调度判定共用）
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct HolidayMeta {
    /// 上次「自动更新范围内年份」成功时间（ms；0 = 从未成功）
    pub last_update_ms: i64,
    /// 上次尝试时间（ms；0 = 从未尝试）
    pub last_attempt_ms: i64,
    /// 连续失败次数（成功后清零）
    pub failure_count: i32,
    /// 自动更新总开关（关闭后仅手动更新）
    pub auto_enabled: bool,
}

/// 语义缺省 = 自动更新开启（与 [holiday_meta] 缺省口径一致，勿依赖 bool 的 false）
impl Default for HolidayMeta {
    fn default() -> Self {
        Self {
            last_update_ms: 0,
            last_attempt_ms: 0,
            failure_count: 0,
            auto_enabled: true,
        }
    }
}

/// 按年范围补写的结果汇总
#[derive(Debug, Clone, serde::Serialize, Default, PartialEq, Eq)]
pub struct HolidayRangeSummary {
    /// 成功写入（含空响应）的年份数
    pub ok: u32,
    /// 获取失败的年份数（含熔断后未尝试的年份）
    pub failed: u32,
    /// 成功但线上无数据的年份数（该年已清空）
    pub empty: u32,
    /// 是否被中途取消
    pub cancelled: bool,
}

/// 按单年补写的结果：更新记账 + 该年实际返回行数
///
/// `row_count == 0` = 该年线上无数据（AC-E7，UI 据此提示「该年无数据」而非报错）。
/// 注意不能靠「列表里有没有该年」判断——[list_holidays] 会为 DB 未覆盖的年份
/// 兜底预置表，空响应年份仍可能显示出预置行。
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct HolidayYearOutcome {
    /// 更新后的记账
    pub meta: HolidayMeta,
    /// 该年实际拉取到的行数（0 = 线上无数据）
    pub row_count: u32,
}

// ============================================================================
// 进度广播（独立于 eventbus：只读缓存表不 emit DbEvent）
// ============================================================================

/// 范围补写进度（serde 内部标签，对齐 cloud_sync 的 `#[serde(tag = "phase")]` 习惯）
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum HolidayProgress {
    /// 范围操作开始（total = 待处理年份数）
    Starting { total: u32 },
    /// 某年结算完成（done = 已结算年份数，1-based）
    Year {
        year: i32,
        done: u32,
        total: u32,
        ok: bool,
        empty: bool,
    },
    /// 全部完成
    Done {
        ok: u32,
        failed: u32,
        cancelled: bool,
    },
    /// 致命错误（参数非法等）
    Error { message: String },
}

static HOLIDAY_PROGRESS: Lazy<broadcast::Sender<HolidayProgress>> =
    Lazy::new(|| broadcast::channel(HOLIDAY_PROGRESS_CAPACITY).0);

/// 订阅范围补写进度（桌面 emit 泵 / 移动 StreamSink 各订阅一次）
pub fn subscribe_holiday_progress() -> broadcast::Receiver<HolidayProgress> {
    HOLIDAY_PROGRESS.subscribe()
}

/// 广播进度；无订阅者时静默忽略（同 [crate::eventbus::EventBus::emit] 语义）
fn emit_progress(sender: &broadcast::Sender<HolidayProgress>, p: HolidayProgress) {
    let _ = sender.send(p);
}

// ============================================================================
// 取消与单会话守卫
// ============================================================================

/// 范围补写是否进行中（防并发会话串扰单一取消标志）
static RANGE_ACTIVE: AtomicBool = AtomicBool::new(false);
/// 取消请求（每次范围操作开始时清零）
static CANCEL_REQUESTED: AtomicBool = AtomicBool::new(false);

/// 请求取消当前范围补写（幂等；无进行中操作时置位无害，下轮开始即清零）
pub fn cancel_holiday_range_fetch() {
    CANCEL_REQUESTED.store(true, Ordering::SeqCst);
}

/// 释放时复位两个标志（panic / 早退亦安全）
struct RangeGuard;

impl RangeGuard {
    /// CAS 抢占单会话资格；已被占用则返回 None
    fn try_acquire() -> Option<Self> {
        if RANGE_ACTIVE
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            CANCEL_REQUESTED.store(false, Ordering::SeqCst);
            Some(RangeGuard)
        } else {
            None
        }
    }
}

impl Drop for RangeGuard {
    fn drop(&mut self) {
        CANCEL_REQUESTED.store(false, Ordering::SeqCst);
        RANGE_ACTIVE.store(false, Ordering::SeqCst);
    }
}

// ============================================================================
// 时钟抽象（生产/测试双实现）
// ============================================================================

/// 本地时区时钟（[should_update_now] 与 [years_to_fetch] 的判定依赖）
pub trait Clock: Send + Sync {
    /// 当前本地时间
    fn now_local(&self) -> chrono::DateTime<chrono::Local>;
    /// 毫秒时间戳 → 本地 DateTime（无效值回落当前时间）
    fn millis_to_local(&self, ms: i64) -> chrono::DateTime<chrono::Local>;
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
    holiday: BTreeMap<String, HolidayEntry>,
}

/// 解析 timor.tech 年接口响应（纯函数，单测覆盖形状与脏数据）
///
/// `date` 字段更权威（YYYY-MM-DD）；缺失时用 `MM-DD + year` 拼合；拼接后仍不是
/// 10 位（脏数据）则跳过该条。`code != 0` 视为失败。
fn parse_year_response(year: i32, body: YearResponse) -> CoreResult<Vec<HolidayInfo>> {
    if body.code != 0 {
        return Err(CoreError::Other(format!(
            "[holiday] 接口返回 code={}（非 0）",
            body.code
        )));
    }
    Ok(body
        .holiday
        .into_iter()
        .filter_map(|(mmdd, e)| {
            let date = if e.date.len() == 10 {
                e.date
            } else {
                format!("{year}-{mmdd}")
            };
            if date.len() != 10 {
                return None; // 脏数据（既非完整 date 也非 MM-DD）
            }
            let row_year = date
                .get(..4)
                .and_then(|s| s.parse::<i32>().ok())
                .unwrap_or(year);
            Some(HolidayInfo {
                date,
                year: row_year,
                is_holiday: e.holiday,
                name: e.name,
            })
        })
        .collect())
}

/// 预置节假日（无网络/首装冷启动时日历仍可正确标注的兜底表）。
///
/// 来源：timor.tech `/api/holiday/year/{y}` 实测数据（2026-09 快照，与国务院
/// 办公厅发布的安排一致）。放假日与调休补班日都收录（补班日影响周末展示）。
/// 线上数据更新后由拉取整年替换本表在查询中的兜底作用（见 [list_holidays]）；
/// 本表只对**未被 DB 覆盖的年份**生效（按年合并）。
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

/// 预置节假日按 date 索引（未覆盖年份的查询兜底）
pub fn builtin_holiday_by_date() -> std::collections::HashMap<String, HolidayInfo> {
    builtin_holidays()
        .into_iter()
        .map(|h| (h.date.clone(), h))
        .collect()
}

// ============================================================================
// 查询 API（按年合并兜底）
// ============================================================================

/// 拉取全部节假日行（date 升序）。
///
/// **按年合并**（AC-E5）：DB 已覆盖的年份完全以 DB 为准；预置表只兜底 DB 未
/// 覆盖的年份。合并结果只是读时视图，**不回写 DB**（避免预置表灌库造成概览
/// 条数虚高），也避免「补写某个历史年份就把预置年份的徽标整体抹掉」。
pub async fn list_holidays(pool: &SqlitePool) -> CoreResult<Vec<HolidayInfo>> {
    let rows = sqlx::query_as::<_, (String, i32, i32, String)>(
        "SELECT date, year, is_holiday, name FROM cfg_holidays ORDER BY date ASC",
    )
    .fetch_all(pool)
    .await?;

    let covered: HashSet<i32> = rows.iter().map(|(_, year, _, _)| *year).collect();
    let mut out: Vec<HolidayInfo> = rows
        .into_iter()
        .map(|(date, year, is_holiday, name)| HolidayInfo {
            date,
            year,
            is_holiday: is_holiday != 0,
            name,
        })
        .collect();
    out.extend(
        builtin_holidays()
            .into_iter()
            .filter(|h| !covered.contains(&h.year)),
    );
    out.sort_by(|a, b| a.date.cmp(&b.date));
    Ok(out)
}

/// 判定某日期是否放假（返回 `Some(true)` 放假 / `Some(false)` 调休补班 / `None` 普通日）。
///
/// **按年合并**：若该日期所属年份已被 DB 覆盖，则严格以 DB 为准——DB 无该行即
/// `None`（绝不回落预置，否则会与「该年已整体替换」的事实矛盾）；仅在该年未被
/// DB 覆盖时才回落预置表。回落语义保证「首次启动未拉取」窗口 UI 仍正确。
pub async fn is_holiday_on(pool: &SqlitePool, date: &str) -> CoreResult<Option<bool>> {
    let year: i32 = date.get(..4).and_then(|s| s.parse().ok()).unwrap_or(0);
    let (covered,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM cfg_holidays WHERE year = ?1")
        .bind(year)
        .fetch_one(pool)
        .await?;
    if covered > 0 {
        let row: Option<(i32,)> =
            sqlx::query_as("SELECT is_holiday FROM cfg_holidays WHERE date = ?1")
                .bind(date)
                .fetch_optional(pool)
                .await?;
        return Ok(row.map(|(is_holiday,)| is_holiday != 0));
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

/// 读取更新记账
pub async fn holiday_meta(pool: &SqlitePool) -> CoreResult<HolidayMeta> {
    Ok(HolidayMeta {
        last_update_ms: kv_get_i64(pool, KV_LAST_SUCCESS).await?.unwrap_or(0),
        last_attempt_ms: kv_get_i64(pool, KV_LAST_ATTEMPT).await?.unwrap_or(0),
        failure_count: kv_get_i64(pool, KV_FAILURE_COUNT).await?.unwrap_or(0) as i32,
        auto_enabled: kv_get_i64(pool, KV_AUTO_ENABLED).await?.unwrap_or(1) != 0,
    })
}

/// 是否应执行自动更新（**每月一次**口径，定时 + 补更判定的唯一口径，纯函数）
///
/// - `last_update_ms <= 0`（从未成功）→ 应更新（首装冷启动）；
/// - 上次成功所在的本地「年/月」≠ 当前本地「年/月」（跨入新月后的首次 tick /
///   首次启动）→ 应更新；
/// - 其余（本月已成功过）→ 不更新。
///
/// 失败不写成功时间，本月内后续 tick / 启动仍按缺额重试（与旧每日口径的补更
/// 语义一致）。不校验时刻——每月首次满足条件即更新。
pub fn should_update_now<C: Clock>(last_update_ms: i64, clock: &C) -> bool {
    if last_update_ms <= 0 {
        return true;
    }
    let last = clock.millis_to_local(last_update_ms);
    let now = clock.now_local();
    last.year() != now.year() || last.month() != now.month()
}

/// 单年补写成功后的记账（AC-E6：仅自动更新范围内的年份才写 `last_update_ms`）
///
/// 手动补写历史年份（如 2015）只写 `last_attempt_ms` 并清零 `failure_count`，
/// **不动** `last_update_ms`；否则会把本月本该发生的自动更新误判为「本月已成功」
/// 而静默跳过（自动更新永远拉不到历史年份，本月真正要拉的今年数据被压掉）。
async fn account_year_success<C: Clock>(
    pool: &SqlitePool,
    year: i32,
    before: &HolidayMeta,
    now_ms: i64,
    clock: &C,
) -> CoreResult<()> {
    let in_scope = years_to_fetch(clock).contains(&year);
    let last_update = if in_scope {
        now_ms
    } else {
        before.last_update_ms
    };
    kv_set(pool, KV_LAST_SUCCESS, &last_update.to_string()).await?;
    kv_set(pool, KV_LAST_ATTEMPT, &now_ms.to_string()).await?;
    kv_set(pool, KV_FAILURE_COUNT, "0").await?;
    Ok(())
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

/// 校验按年补写的年份在可选范围内
fn validate_fetch_year(year: i32, now_year: i32) -> CoreResult<()> {
    if year < HOLIDAY_FETCH_YEAR_MIN || year > holiday_fetch_year_max(now_year) {
        return Err(CoreError::Other(format!(
            "[holiday] 年份 {year} 超出可选范围 {}~{}",
            HOLIDAY_FETCH_YEAR_MIN,
            holiday_fetch_year_max(now_year)
        )));
    }
    Ok(())
}

/// 拉取单年数据（HTTP + 解析；空 map = 次年未发布 / 该年线上无数据）
async fn fetch_year(
    client: &reqwest::Client,
    year: i32,
    timeout: Duration,
) -> CoreResult<Vec<HolidayInfo>> {
    let url = format!("{HOLIDAY_API_BASE}/{year}");
    let resp = client
        .get(&url)
        .header(reqwest::header::USER_AGENT, HOLIDAY_UA)
        .header(reqwest::header::ACCEPT, "application/json")
        .timeout(timeout)
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
    parse_year_response(year, body)
}

/// 事务「整年替换」：先删目标年份旧行再插入（失败整体回滚，保留旧缓存）
async fn replace_years(pool: &SqlitePool, years: &[i32], rows: &[HolidayInfo]) -> CoreResult<()> {
    let mut tx = pool.begin().await?;
    for y in years {
        sqlx::query("DELETE FROM cfg_holidays WHERE year = ?1")
            .bind(y)
            .execute(&mut *tx)
            .await?;
    }
    let now_sec = chrono::Utc::now().timestamp();
    for h in rows {
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
    Ok(())
}

/// 手动更新：强制拉取（无视记账；网络失败时旧缓存保留并记账失败）
pub async fn update_holidays(pool: &SqlitePool) -> CoreResult<HolidayMeta> {
    update_holidays_with(pool, true, &SystemClock, reqwest::Client::new()).await
}

/// 调度入口：按 [should_update_now] 判定是否需要更新
///
/// 返回 `Ok(true)` = 本次执行了更新；`Ok(false)` = 未到更新条件（本月已成功）
/// 或自动更新总开关已关闭。
pub async fn auto_update_holidays(pool: &SqlitePool) -> CoreResult<bool> {
    auto_update_with(pool, &SystemClock, reqwest::Client::new()).await
}

async fn auto_update_with<C: Clock>(
    pool: &SqlitePool,
    clock: &C,
    client: reqwest::Client,
) -> CoreResult<bool> {
    let meta = holiday_meta(pool).await?;
    if !meta.auto_enabled {
        return Ok(false);
    }
    if !should_update_now(meta.last_update_ms, clock) {
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
    let meta = holiday_meta(pool).await?;
    if !force && !should_update_now(meta.last_update_ms, clock) {
        return Ok(meta);
    }

    let now_ms = clock.now_local().timestamp_millis();
    kv_set(pool, KV_LAST_ATTEMPT, &now_ms.to_string()).await?;

    let years = years_to_fetch(clock);
    let mut fetched = Vec::new();
    // 逐年拉取：单年失败即中止（保证「整年完整替换」而非半截数据）
    for y in &years {
        fetched.extend(fetch_year(&client, *y, REQ_TIMEOUT).await?);
    }
    // 整份传入 + 按年替换：12 月拉 [本年, 次年] 时跨年条目（如次年 1 月 1 日）
    // 会被两个年份的响应先后给出，整份写入才能保证两个年份的行都在。
    replace_years(pool, &years, &fetched).await?;

    let success_ms = clock.now_local().timestamp_millis();
    kv_set(pool, KV_LAST_SUCCESS, &success_ms.to_string()).await?;
    kv_set(pool, KV_FAILURE_COUNT, "0").await?;
    kv_set(pool, KV_LAST_ATTEMPT, &success_ms.to_string()).await?;

    holiday_meta(pool).await
}

// ============================================================================
// 按年补写（单年 / 范围）
// ============================================================================

/// 按单年联网补写（设置页「按年份获取」/「更新该年」，AC-E1/E3）。
///
/// 与 [update_holidays] 同源的整年替换语义，差异只在**记账口径**（AC-E6，见
/// [account_year_success]）。空响应（该年 `holiday == {}`）按成功处理：该年
/// 替换为空集（清掉旧数据），不抛错也不记失败（AC-E7），由返回的
/// [HolidayYearOutcome::row_count] 供 UI 提示「该年无数据」。
pub async fn fetch_holiday_year(pool: &SqlitePool, year: i32) -> CoreResult<HolidayYearOutcome> {
    fetch_holiday_year_with(pool, year, &SystemClock, reqwest::Client::new()).await
}

async fn fetch_holiday_year_with<C: Clock>(
    pool: &SqlitePool,
    year: i32,
    clock: &C,
    client: reqwest::Client,
) -> CoreResult<HolidayYearOutcome> {
    validate_fetch_year(year, clock.now_local().year())?;

    let before = holiday_meta(pool).await?;
    let attempt_ms = clock.now_local().timestamp_millis();
    kv_set(pool, KV_LAST_ATTEMPT, &attempt_ms.to_string()).await?;

    match fetch_year(&client, year, REQ_TIMEOUT).await {
        Ok(rows) => {
            replace_years(pool, &[year], &rows).await?;
            let now_ms = clock.now_local().timestamp_millis();
            account_year_success(pool, year, &before, now_ms, clock).await?;
            Ok(HolidayYearOutcome {
                meta: holiday_meta(pool).await?,
                row_count: rows.len() as u32,
            })
        }
        Err(e) => {
            // 保留旧缓存，只累加失败计数（旧数据仍可显示）
            kv_set(
                pool,
                KV_FAILURE_COUNT,
                &(before.failure_count + 1).to_string(),
            )
            .await?;
            Err(e)
        }
    }
}

/// 按年份范围联网补写（设置页「按年份范围获取」）。
///
/// 两阶段流水线：
/// 1. **分片并发拉取**（[RANGE_CONCURRENCY] 分片 `join_all`，保序）——只做网络
///    + 解析，不写库（sqlx 连接不可并发事务，落库统一放阶段 2 串行）；
/// 2. **串行落库**：按年份升序逐个整年替换（语义与 [fetch_holiday_year] 一致）。
///
/// 单年失败**跳过不中止**；但连续失败达 [RANGE_ABORT_AFTER] 次即熔断——网络已断
/// 时不再把剩余年份逐个等到超时，未尝试的年份同样计入 `failed`。
///
/// 记账一次写完：整次操作 `failure_count` 只 +1（有失败时）或清零（全成功），
/// `last_update_ms` 仅当范围内含自动更新年份且成功时才写（AC-E6）。取消且颗粒
/// 无收则记账原样恢复，不污染失败计数。
///
/// 进度经 [subscribe_holiday_progress] 广播；[cancel_holiday_range_fetch] 可取消。
pub async fn fetch_holiday_range(
    pool: &SqlitePool,
    start: i32,
    end: i32,
) -> CoreResult<HolidayRangeSummary> {
    fetch_holiday_range_with(
        pool,
        start,
        end,
        &SystemClock,
        reqwest::Client::new(),
        &HOLIDAY_PROGRESS,
        &CANCEL_REQUESTED,
    )
    .await
}

async fn fetch_holiday_range_with<C: Clock>(
    pool: &SqlitePool,
    start: i32,
    end: i32,
    clock: &C,
    client: reqwest::Client,
    progress: &broadcast::Sender<HolidayProgress>,
    cancel: &AtomicBool,
) -> CoreResult<HolidayRangeSummary> {
    let now_year = clock.now_local().year();
    validate_fetch_year(start, now_year)?;
    validate_fetch_year(end, now_year)?;
    if start > end {
        return Err(CoreError::Other(format!(
            "[holiday] 起始年份 {start} 大于结束年份 {end}"
        )));
    }
    let _guard = RangeGuard::try_acquire()
        .ok_or_else(|| CoreError::Other("[holiday] 节假日范围补写已在进行中，请稍后再试".into()))?;

    let years: Vec<i32> = (start..=end).collect();
    let total = years.len() as u32;
    emit_progress(progress, HolidayProgress::Starting { total });

    // 阶段 1：分片并发拉取（只网络 + 解析，不写库；join_all 保序）
    let mut results: Vec<(i32, Result<Vec<HolidayInfo>, String>)> = Vec::with_capacity(years.len());
    for chunk in years.chunks(RANGE_CONCURRENCY) {
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        let futs = chunk.iter().map(|y| {
            let client = client.clone();
            let year = *y;
            async move {
                (
                    year,
                    fetch_year(&client, year, RANGE_REQ_TIMEOUT)
                        .await
                        .map_err(|e| e.to_string()),
                )
            }
        });
        results.extend(join_all(futs).await);
    }

    // 阶段 2：串行落库 + 记账 + 熔断
    settle_range_results(pool, results, total, clock, progress, cancel).await
}

/// 阶段 2 结算：`results` 为按年升序的拉取结果（可因取消而少于 `total`）。
///
/// 抽出为独立函数以便单测注入合成结果（无需真实网络）。
async fn settle_range_results<C: Clock>(
    pool: &SqlitePool,
    results: Vec<(i32, Result<Vec<HolidayInfo>, String>)>,
    total: u32,
    clock: &C,
    progress: &broadcast::Sender<HolidayProgress>,
    cancel: &AtomicBool,
) -> CoreResult<HolidayRangeSummary> {
    let before = holiday_meta(pool).await?;
    let scope = years_to_fetch(clock);

    let mut ok = 0u32;
    let mut failed = 0u32;
    let mut empty = 0u32;
    let mut consecutive = 0u32;
    let mut done = 0u32;
    let mut cancelled = false;
    let mut in_scope_success = false;

    for (year, res) in results {
        if cancel.load(Ordering::SeqCst) {
            cancelled = true;
            break;
        }
        match res {
            Err(_) => {
                consecutive += 1;
                failed += 1;
                done += 1;
                emit_progress(
                    progress,
                    HolidayProgress::Year {
                        year,
                        done,
                        total,
                        ok: false,
                        empty: false,
                    },
                );
                if consecutive >= RANGE_ABORT_AFTER {
                    // 熔断：剩余未尝试的年份同样计入失败（没拿到数据是事实）
                    failed += total.saturating_sub(done);
                    break;
                }
            }
            Ok(rows) => {
                consecutive = 0;
                let is_empty = rows.is_empty(); // AC-E7：空响应按成功处理
                replace_years(pool, &[year], &rows).await?;
                if scope.contains(&year) {
                    in_scope_success = true;
                }
                ok += 1;
                if is_empty {
                    empty += 1;
                }
                done += 1;
                emit_progress(
                    progress,
                    HolidayProgress::Year {
                        year,
                        done,
                        total,
                        ok: true,
                        empty: is_empty,
                    },
                );
            }
        }
    }

    let now_ms = clock.now_local().timestamp_millis();

    // 取消且颗粒无收：记账原样恢复，不污染失败计数
    if cancelled && ok == 0 {
        kv_set(pool, KV_LAST_SUCCESS, &before.last_update_ms.to_string()).await?;
        kv_set(pool, KV_LAST_ATTEMPT, &before.last_attempt_ms.to_string()).await?;
        kv_set(pool, KV_FAILURE_COUNT, &before.failure_count.to_string()).await?;
        emit_progress(
            progress,
            HolidayProgress::Done {
                ok: 0,
                failed: 0,
                cancelled: true,
            },
        );
        return Ok(HolidayRangeSummary {
            ok: 0,
            failed: 0,
            empty: 0,
            cancelled: true,
        });
    }

    // 整次范围操作记账一次：failure_count 只 +1（有失败）或清零（全成功）
    let last_update = if in_scope_success {
        now_ms
    } else {
        before.last_update_ms
    };
    kv_set(pool, KV_LAST_SUCCESS, &last_update.to_string()).await?;
    kv_set(pool, KV_LAST_ATTEMPT, &now_ms.to_string()).await?;
    let failure_count = if failed > 0 {
        before.failure_count + 1
    } else {
        0
    };
    kv_set(pool, KV_FAILURE_COUNT, &failure_count.to_string()).await?;

    emit_progress(
        progress,
        HolidayProgress::Done {
            ok,
            failed,
            cancelled,
        },
    );
    Ok(HolidayRangeSummary {
        ok,
        failed,
        empty,
        cancelled,
    })
}

// ============================================================================
// 配置（自动更新总开关）
// ============================================================================

/// 设置自动更新总开关（关闭后调度器不再联网，仅保留手动与按年补写）
pub async fn set_holiday_auto_enabled(pool: &SqlitePool, enabled: bool) -> CoreResult<()> {
    kv_set(pool, KV_AUTO_ENABLED, if enabled { "1" } else { "0" }).await
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
    }

    /// 构造本地某日正午的 FixedClock
    fn clock_at(year: i32, month: u32, day: u32) -> FixedClock {
        FixedClock(
            chrono::Local
                .with_ymd_and_hms(year, month, day, 12, 0, 0)
                .single()
                .expect("测试时刻合法"),
        )
    }

    /// 本地某日正午的毫秒时间戳
    fn ms_at(year: i32, month: u32, day: u32) -> i64 {
        chrono::Local
            .with_ymd_and_hms(year, month, day, 12, 0, 0)
            .single()
            .expect("测试时刻合法")
            .timestamp_millis()
    }

    fn info(date: &str, is_holiday: bool, name: &str) -> HolidayInfo {
        HolidayInfo {
            date: date.to_string(),
            year: date[..4].parse().unwrap_or(0),
            is_holiday,
            name: name.to_string(),
        }
    }

    /// 测试专用本地进度通道（避免与全局通道串扰导致用例间互相干扰）
    fn progress_channel() -> (
        broadcast::Sender<HolidayProgress>,
        broadcast::Receiver<HolidayProgress>,
    ) {
        broadcast::channel(HOLIDAY_PROGRESS_CAPACITY)
    }

    fn drain(rx: &mut broadcast::Receiver<HolidayProgress>) -> Vec<HolidayProgress> {
        let mut seq = Vec::new();
        while let Ok(p) = rx.try_recv() {
            seq.push(p);
        }
        seq
    }

    // —— should_update_now：每月一次 ——

    #[test]
    fn update_needed_when_never_succeeded() {
        // 从未成功（含首装冷启动）→ 任意时刻都应更新
        assert!(should_update_now(0, &clock_at(2026, 9, 6)));
        assert!(should_update_now(0, &clock_at(2026, 9, 30)));
    }

    #[test]
    fn monthly_gate_opens_on_new_calendar_month() {
        let last = ms_at(2026, 9, 30);
        // 同月任何一天都不重复（月初、同日、月末）
        assert!(!should_update_now(last, &clock_at(2026, 9, 1)));
        assert!(!should_update_now(last, &clock_at(2026, 9, 30)));
        // 跨入新月（无论是否已过当月某日）→ 更新
        assert!(should_update_now(last, &clock_at(2026, 10, 1)));
        assert!(should_update_now(last, &clock_at(2026, 10, 31)));
    }

    #[test]
    fn monthly_gate_crosses_year_boundary() {
        let last = ms_at(2025, 12, 20);
        assert!(!should_update_now(last, &clock_at(2025, 12, 31)));
        // 同年同月不同年 → 视为跨月（年/月任一不同即更新）
        assert!(should_update_now(last, &clock_at(2026, 1, 1)));
        assert!(should_update_now(last, &clock_at(2025, 11, 30)));
    }

    // —— years_to_fetch ——

    #[test]
    fn years_to_fetch_adds_next_year_in_december() {
        assert_eq!(years_to_fetch(&clock_at(2026, 6, 1)), vec![2026]);
        assert_eq!(years_to_fetch(&clock_at(2026, 12, 1)), vec![2026, 2027]);
    }

    // —— 数据源解析 ——

    #[test]
    fn parse_year_response_shape() {
        let json = r#"{"code":0,"holiday":{
            "02-16":{"holiday":true,"name":"除夕","wage":3,"date":"2026-02-16","rest":1},
            "02-28":{"holiday":false,"name":"春节后补班","wage":1,"target":"春节","after":true,"date":"2026-02-28"}}}"#;
        let body: YearResponse = serde_json::from_str(json).unwrap();
        let rows = parse_year_response(2026, body).unwrap();
        assert_eq!(rows.len(), 2);
        let d = rows.iter().find(|h| h.date == "2026-02-16").unwrap();
        assert!(d.is_holiday);
        assert_eq!(d.name, "除夕");
        let w = rows.iter().find(|h| h.date == "2026-02-28").unwrap();
        assert!(!w.is_holiday);
    }

    #[test]
    fn parse_year_response_falls_back_to_mmdd_and_skips_dirty() {
        let json = r#"{"code":0,"holiday":{
            "05-01":{"holiday":true,"name":"劳动节"},
            "bad":{"holiday":true,"name":"脏数据"}}}"#;
        let body: YearResponse = serde_json::from_str(json).unwrap();
        let rows = parse_year_response(2026, body).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].date, "2026-05-01");
        assert_eq!(rows[0].year, 2026);
    }

    #[test]
    fn parse_year_response_rejects_nonzero_code() {
        let body: YearResponse = serde_json::from_str(r#"{"code":404,"holiday":{}}"#).unwrap();
        assert!(parse_year_response(2026, body).is_err());
    }

    #[test]
    fn parse_year_response_treats_empty_map_as_success() {
        let body: YearResponse = serde_json::from_str(r#"{"code":0,"holiday":{}}"#).unwrap();
        assert!(parse_year_response(2026, body).unwrap().is_empty());
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
        assert!(
            builtin_holidays()
                .iter()
                .all(|h| h.year == HOLIDAY_BUILTIN_YEAR)
        );
    }

    // —— 年份边界校验 ——

    #[test]
    fn validate_fetch_year_bounds() {
        assert_eq!(holiday_fetch_year_max(2026), 2027);
        assert!(validate_fetch_year(2013, 2026).is_ok());
        assert!(validate_fetch_year(2026, 2026).is_ok());
        assert!(validate_fetch_year(2027, 2026).is_ok());
        assert!(validate_fetch_year(2012, 2026).is_err());
        assert!(validate_fetch_year(2028, 2026).is_err());
    }

    // —— 查询兜底（按年合并）——

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
    async fn list_merge_keeps_builtin_for_uncovered_year() {
        let pool = setup_db().await;
        replace_years(&pool, &[2022], &[info("2022-01-01", true, "元旦")])
            .await
            .unwrap();
        let list = list_holidays(&pool).await.unwrap();
        assert!(list.iter().any(|h| h.date == "2022-01-01"));
        // 补写历史年份不得让 2026 预置兜底整体失效（AC-E5 回归）
        assert!(list.iter().any(|h| h.date == "2026-02-17"));
        // 按 date 升序
        assert!(list.windows(2).all(|w| w[0].date <= w[1].date));
    }

    #[tokio::test]
    async fn list_merge_db_wins_for_covered_year() {
        let pool = setup_db().await;
        replace_years(&pool, &[2026], &[info("2026-01-01", true, "元旦(DB)")])
            .await
            .unwrap();
        let list = list_holidays(&pool).await.unwrap();
        // 该年已被 DB 覆盖 → 该年只出现 DB 行（预置同日期不重复渲染）
        assert_eq!(list.iter().filter(|h| h.year == 2026).count(), 1);
        assert_eq!(
            list.iter().find(|h| h.date == "2026-01-01").unwrap().name,
            "元旦(DB)"
        );
    }

    #[tokio::test]
    async fn is_holiday_on_covered_year_does_not_fall_back() {
        let pool = setup_db().await;
        replace_years(&pool, &[2026], &[info("2026-01-01", true, "元旦")])
            .await
            .unwrap();
        assert_eq!(
            is_holiday_on(&pool, "2026-01-01").await.unwrap(),
            Some(true)
        );
        // 该年已覆盖但无该行 → None（绝不回落预置）
        assert_eq!(is_holiday_on(&pool, "2026-02-17").await.unwrap(), None);
    }

    #[tokio::test]
    async fn is_holiday_on_uncovered_year_falls_back_to_builtin() {
        let pool = setup_db().await;
        replace_years(&pool, &[2022], &[info("2022-01-01", true, "元旦")])
            .await
            .unwrap();
        // 2026 未被覆盖 → 预置兜底
        assert_eq!(
            is_holiday_on(&pool, "2026-02-17").await.unwrap(),
            Some(true)
        );
        assert_eq!(
            is_holiday_on(&pool, "2022-01-01").await.unwrap(),
            Some(true)
        );
        assert_eq!(is_holiday_on(&pool, "2022-06-06").await.unwrap(), None);
    }

    // —— 整年替换 ——

    #[tokio::test]
    async fn replace_years_only_touches_target_year() {
        let pool = setup_db().await;
        replace_years(
            &pool,
            &[2024],
            &[
                info("2024-01-01", true, "元旦"),
                info("2024-01-02", true, "元旦"),
            ],
        )
        .await
        .unwrap();
        replace_years(&pool, &[2025], &[info("2025-01-01", true, "元旦")])
            .await
            .unwrap();
        let list = list_holidays(&pool).await.unwrap();
        assert_eq!(list.iter().filter(|h| h.year == 2024).count(), 2);
        assert_eq!(list.iter().filter(|h| h.year == 2025).count(), 1);

        // 再替换 2024 → 旧两行被清掉，2025 不受影响
        replace_years(&pool, &[2024], &[info("2024-05-01", true, "劳动节")])
            .await
            .unwrap();
        let list = list_holidays(&pool).await.unwrap();
        assert_eq!(list.iter().filter(|h| h.year == 2024).count(), 1);
        assert!(list.iter().any(|h| h.date == "2024-05-01"));
        assert_eq!(list.iter().filter(|h| h.year == 2025).count(), 1);
    }

    // —— 记账 ——

    #[tokio::test]
    async fn meta_roundtrip_and_auto_enabled_default() {
        let pool = setup_db().await;
        let meta = holiday_meta(&pool).await.unwrap();
        assert_eq!(meta.last_update_ms, 0);
        assert_eq!(meta.last_attempt_ms, 0);
        assert_eq!(meta.failure_count, 0);
        assert!(meta.auto_enabled, "缺省应为开启");

        set_holiday_auto_enabled(&pool, false).await.unwrap();
        assert!(!holiday_meta(&pool).await.unwrap().auto_enabled);
        set_holiday_auto_enabled(&pool, true).await.unwrap();
        assert!(holiday_meta(&pool).await.unwrap().auto_enabled);
    }

    #[tokio::test]
    async fn kv_upsert_overwrites() {
        let pool = setup_db().await;
        kv_set(&pool, "k", "1").await.unwrap();
        kv_set(&pool, "k", "2").await.unwrap();
        assert_eq!(kv_get_i64(&pool, "k").await.unwrap(), Some(2));
        assert_eq!(kv_get_i64(&pool, "absent").await.unwrap(), None);
    }

    #[tokio::test]
    async fn account_year_success_writes_last_update_only_in_scope() {
        let pool = setup_db().await;
        let before = holiday_meta(&pool).await.unwrap();
        let clock = clock_at(2026, 9, 6); // years_to_fetch = [2026]
        let now_ms = ms_at(2026, 9, 6);

        // 历史年份：只写 attempt，不动 last_update（AC-E6）
        account_year_success(&pool, 2015, &before, now_ms, &clock)
            .await
            .unwrap();
        let m = holiday_meta(&pool).await.unwrap();
        assert_eq!(m.last_update_ms, 0, "历史年份不得写 last_update");
        assert_eq!(m.last_attempt_ms, now_ms);

        // 范围内年份：写 last_update
        account_year_success(&pool, 2026, &before, now_ms, &clock)
            .await
            .unwrap();
        assert_eq!(holiday_meta(&pool).await.unwrap().last_update_ms, now_ms);
    }

    // —— 范围补写结算（注入合成结果，不触网）——

    #[tokio::test]
    async fn settle_emits_progress_year_and_done() {
        let pool = setup_db().await;
        let (tx, mut rx) = progress_channel();
        let clock = clock_at(2026, 9, 6);
        let cancel = AtomicBool::new(false);
        let results = vec![
            (2024, Ok(vec![info("2024-01-01", true, "元旦")])),
            (2025, Err("boom".to_string())),
        ];
        let summary = settle_range_results(&pool, results, 2, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert_eq!(summary.ok, 1);
        assert_eq!(summary.failed, 1);
        assert!(!summary.cancelled);

        let seq = drain(&mut rx);
        assert_eq!(seq.len(), 3);
        assert_eq!(
            seq[0],
            HolidayProgress::Year {
                year: 2024,
                done: 1,
                total: 2,
                ok: true,
                empty: false
            }
        );
        assert_eq!(
            seq[1],
            HolidayProgress::Year {
                year: 2025,
                done: 2,
                total: 2,
                ok: false,
                empty: false
            }
        );
        assert_eq!(
            seq[2],
            HolidayProgress::Done {
                ok: 1,
                failed: 1,
                cancelled: false
            }
        );
    }

    #[tokio::test]
    async fn settle_circuit_breaker_after_three_consecutive_failures() {
        let pool = setup_db().await;
        let (tx, _rx) = progress_channel();
        let clock = clock_at(2026, 9, 6);
        let cancel = AtomicBool::new(false);
        let results: Vec<(i32, Result<Vec<HolidayInfo>, String>)> = [2019, 2020, 2021, 2022, 2023]
            .iter()
            .map(|y| (*y, Err(format!("fail {y}"))))
            .collect();

        let summary = settle_range_results(&pool, results, 5, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert_eq!(summary.ok, 0);
        assert_eq!(summary.failed, 5, "熔断后剩余未尝试年份同样计失败");
        // 整次操作失败计数只 +1（而非 +5）
        assert_eq!(holiday_meta(&pool).await.unwrap().failure_count, 1);
    }

    #[tokio::test]
    async fn settle_resets_consecutive_streak_on_success() {
        let pool = setup_db().await;
        let (tx, _rx) = progress_channel();
        let clock = clock_at(2026, 9, 6);
        let cancel = AtomicBool::new(false);
        // 失败 2 次 → 成功 1 次（清零连击）→ 再失败 2 次：不应熔断
        let results = vec![
            (2019, Err("f".to_string())),
            (2020, Err("f".to_string())),
            (2021, Ok(vec![info("2021-01-01", true, "元旦")])),
            (2022, Err("f".to_string())),
            (2023, Err("f".to_string())),
        ];
        let summary = settle_range_results(&pool, results, 5, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert_eq!(summary.ok, 1);
        assert_eq!(summary.failed, 4);
    }

    #[tokio::test]
    async fn settle_empty_response_counts_as_no_data_and_clears_year() {
        let pool = setup_db().await;
        replace_years(&pool, &[2024], &[info("2024-01-01", true, "元旦")])
            .await
            .unwrap();
        assert_eq!(
            list_holidays(&pool)
                .await
                .unwrap()
                .iter()
                .filter(|h| h.year == 2024)
                .count(),
            1
        );

        let (tx, _rx) = progress_channel();
        let clock = clock_at(2026, 9, 6);
        let cancel = AtomicBool::new(false);
        let results = vec![(2024, Ok(vec![]))]; // 空响应（AC-E7）
        let summary = settle_range_results(&pool, results, 1, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert_eq!(summary.ok, 1);
        assert_eq!(summary.empty, 1);
        assert_eq!(summary.failed, 0);
        assert_eq!(
            holiday_meta(&pool).await.unwrap().failure_count,
            0,
            "空响应不得记失败"
        );
        assert_eq!(
            list_holidays(&pool)
                .await
                .unwrap()
                .iter()
                .filter(|h| h.year == 2024)
                .count(),
            0,
            "空响应应清空该年旧行"
        );
    }

    #[tokio::test]
    async fn settle_writes_last_update_only_for_in_scope_year() {
        let pool = setup_db().await;
        let (tx, _rx) = progress_channel();
        let clock = clock_at(2026, 9, 6); // 范围内只有 2026
        let cancel = AtomicBool::new(false);

        // 仅历史年份成功 → last_update 不变（AC-E6）
        let results = vec![(2015, Ok(vec![info("2015-01-01", true, "元旦")]))];
        settle_range_results(&pool, results, 1, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert_eq!(holiday_meta(&pool).await.unwrap().last_update_ms, 0);

        // 范围内年份成功 → last_update 写入
        let results = vec![(2026, Ok(vec![info("2026-01-01", true, "元旦")]))];
        settle_range_results(&pool, results, 1, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert!(holiday_meta(&pool).await.unwrap().last_update_ms > 0);
    }

    #[tokio::test]
    async fn settle_cancel_without_result_restores_accounting() {
        let pool = setup_db().await;
        let (tx, _rx) = progress_channel();
        let clock = clock_at(2026, 9, 6);

        // 预置一份记账基线
        kv_set(&pool, KV_LAST_SUCCESS, &ms_at(2026, 8, 1).to_string())
            .await
            .unwrap();
        kv_set(&pool, KV_LAST_ATTEMPT, &ms_at(2026, 8, 1).to_string())
            .await
            .unwrap();
        kv_set(&pool, KV_FAILURE_COUNT, "2").await.unwrap();
        let before = holiday_meta(&pool).await.unwrap();

        let cancel = AtomicBool::new(true); // 一开始就取消
        let results = vec![(2024, Ok(vec![info("2024-01-01", true, "元旦")]))];
        let summary = settle_range_results(&pool, results, 1, &clock, &tx, &cancel)
            .await
            .unwrap();
        assert!(summary.cancelled);
        assert_eq!(summary.ok, 0);

        let after = holiday_meta(&pool).await.unwrap();
        assert_eq!(after.last_update_ms, before.last_update_ms);
        assert_eq!(after.last_attempt_ms, before.last_attempt_ms);
        assert_eq!(
            after.failure_count, before.failure_count,
            "取消且颗粒无收不得污染失败计数"
        );
    }

    // —— 取消标志与单会话守卫 ——

    #[test]
    fn cancel_request_is_idempotent_and_checked() {
        CANCEL_REQUESTED.store(false, Ordering::SeqCst);
        assert!(!CANCEL_REQUESTED.load(Ordering::SeqCst));
        cancel_holiday_range_fetch();
        cancel_holiday_range_fetch();
        assert!(CANCEL_REQUESTED.load(Ordering::SeqCst));
        CANCEL_REQUESTED.store(false, Ordering::SeqCst); // 收尾复位，避免污染其他用例
    }

    #[test]
    fn range_guard_rejects_concurrent_and_resets_on_drop() {
        // 本用例独占全局 RANGE_ACTIVE（其他用例不抢占守卫）
        let g1 = RangeGuard::try_acquire().expect("首次应获取成功");
        assert!(RangeGuard::try_acquire().is_none(), "并发应被拒绝");
        drop(g1);
        let g2 = RangeGuard::try_acquire().expect("释放后应可再次获取");
        drop(g2);
        assert!(
            !CANCEL_REQUESTED.load(Ordering::SeqCst),
            "守卫释放应复位取消位"
        );
    }

    #[tokio::test]
    async fn fetch_range_rejects_bounds_before_touching_network() {
        let pool = setup_db().await;
        let (tx, _rx) = progress_channel();
        let cancel = AtomicBool::new(false);

        // 下界越界
        assert!(
            fetch_holiday_range_with(
                &pool,
                2000,
                2026,
                &SystemClock,
                reqwest::Client::new(),
                &tx,
                &cancel
            )
            .await
            .is_err()
        );
        // 起始 > 结束
        assert!(
            fetch_holiday_range_with(
                &pool,
                2026,
                2020,
                &SystemClock,
                reqwest::Client::new(),
                &tx,
                &cancel
            )
            .await
            .is_err()
        );
    }
}
