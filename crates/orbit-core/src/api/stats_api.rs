//! stats_api — 统计仪表盘（只读聚合，无新增表、不进同步白名单）
//!
//! 口径：以 `done_at`（完成时刻）为唯一事实来源，只统计存活任务
//!（`is_deleted=0`）；软删墓碑行进回收站后不参与统计（完成度不应因删行漂移）。
//! 日界：`done_at` 为 UTC 毫秒时间戳，分桶按**本地时区**日界
//!（chrono::Local，与前端 date-fns / Dart 本地日期语义一致）。日界换算在
//! Rust 侧完成后，SQL 仅按天数值 GROUP BY——单机单时区，无需参数化时区。
//!
//! 一次性聚合（overview / heatmap / streak / by_project / by_priority /
//! by_weekday 六路一次往返），单次 UI 渲染一调用即可。

use chrono::{Datelike, TimeZone, Utc};
use serde::Serialize;
use sqlx::SqlitePool;

use crate::error::CoreResult;

// ============================================================================
// 返回结构（serde 平铺给两端薄壳直读）
// ============================================================================

/// 总览卡：任务规模 + 近期完成节奏
#[derive(Debug, Clone, Serialize)]
pub struct StatsOverview {
    /// 存活任务总数
    pub total: i64,
    /// 未完成（done=0）
    pub pending: i64,
    /// 已完成（done=1 且 done_at 非空）
    pub done: i64,
    /// 近 7 天完成数（含今天，本地日界）
    pub done_last_7d: i64,
    /// 近 30 天完成数（含今天，本地日界）
    pub done_last_30d: i64,
}

/// 热力图单格（本地日期，YYYY-MM-DD）
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapCell {
    /// 本地日期（YYYY-MM-DD）
    pub date: String,
    /// 当日完成数
    pub count: i64,
}

/// 热力图数据：窗口首日至今的逐日计数（含零完成日，前端直接铺格）
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapData {
    /// 窗口首日（含）
    pub start_date: String,
    /// 今天（含）
    pub end_date: String,
    pub cells: Vec<HeatmapCell>,
}

/// 连续完成天数（GitHub / TickTick 式 streak）
#[derive(Debug, Clone, Serialize)]
pub struct StreakData {
    /// 当前连续完成天数
    ///
    /// 断档规则：今天有完成 → 从今天往前数；今天没有 → 从昨天往前数（昨天
    /// 必须有完成才算 >0，否则 0，今天的不确定性不惩罚也不奖励）。
    pub current: i64,
    /// 历史最长连续天数
    pub best: i64,
    /// 今天（本地）是否已有完成
    pub done_today: bool,
}

/// 项目维度分布行（NULL 项目聚合为「未分组」）
#[derive(Debug, Clone, Serialize)]
pub struct ProjectDistRow {
    pub project_id: Option<i64>,
    /// 项目名（未分组时 None，前端显示「未分组」）
    pub project_title: Option<String>,
    /// 项目自选色（未分组时 None；前端条形图按此着色，空串回落待办强调色）
    pub project_hex_color: Option<String>,
    /// 已完成任务数
    pub done_count: i64,
    /// 未完成任务数
    pub pending_count: i64,
}

/// 优先级分布行（priority 0-4，与种子选项 low..immediate 对齐）
#[derive(Debug, Clone, Serialize)]
pub struct PriorityDistRow {
    pub priority: i64,
    pub done_count: i64,
    pub pending_count: i64,
}

/// 星期分布行（weekday 0=周一 … 6=周日，与周日历一致）
#[derive(Debug, Clone, Serialize)]
pub struct WeekdayDistRow {
    pub weekday: i64,
    pub done_count: i64,
}

/// 单任务行的统计最小投影（overview / heatmap / streak / weekday 共用）
#[derive(Debug, sqlx::FromRow)]
struct TaskStatRow {
    done: i64,
    done_at: Option<i64>,
}

/// 天 → 毫秒
#[cfg(test)]
const DAY_MS: i64 = 86_400_000;

// ============================================================================
// 时间工具（本地时区日界）
// ============================================================================

/// 本地日期序号（days since epoch）——streak/窗口运算的整数域
fn local_day_index(ts_ms: i64) -> i64 {
    Utc.timestamp_millis_opt(ts_ms)
        .single()
        .unwrap_or_else(|| Utc.timestamp_millis_opt(0).single().unwrap())
        .with_timezone(&chrono::Local)
        .ordinal0() as i64
        + (Utc.timestamp_millis_opt(ts_ms)
            .single()
            .unwrap()
            .with_timezone(&chrono::Local)
            .year() as i64)
            * 366
}

// ============================================================================
// 聚合实现
// ============================================================================

/// 一次性聚合入口（UI 单次调用拿到全部卡片）
pub async fn aggregate(pool: &SqlitePool, days: i64) -> CoreResult<StatsAggregate> {
    let days = days.clamp(35, 371);

    let overview = stats_overview_impl(pool).await?;
    let heatmap = stats_heatmap_impl(pool, days).await?;
    let streak = stats_streak_impl(pool).await?;
    let by_project = stats_by_project_impl(pool).await?;
    let by_priority = stats_by_priority_impl(pool).await?;
    let by_weekday = stats_by_weekday_impl(pool).await?;

    Ok(StatsAggregate {
        overview,
        heatmap,
        streak,
        by_project,
        by_priority,
        by_weekday,
    })
}

/// 单任务行最小投影（仅供本模块测试构造，功能代码走一次性聚合）
pub async fn stats_overview(pool: &SqlitePool) -> CoreResult<StatsOverview> {
    stats_overview_impl(pool).await
}

async fn fetch_stat_rows(pool: &SqlitePool) -> CoreResult<Vec<TaskStatRow>> {
    let rows: Vec<TaskStatRow> = sqlx::query_as(
        "SELECT done, done_at FROM todo_tasks WHERE is_deleted = 0",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

async fn stats_overview_impl(pool: &SqlitePool) -> CoreResult<StatsOverview> {
    let rows = fetch_stat_rows(pool).await?;
    let total = rows.len() as i64;
    let done = rows.iter().filter(|r| r.done == 1).count() as i64;
    let pending = total - done;

    let today_idx = local_day_index(now_ms());
    let in_last = |n: i64| {
        rows.iter()
            .filter(|r| {
                r.done == 1
                    && r.done_at
                        .map(|ts| local_day_index(ts) >= today_idx - (n - 1))
                        .unwrap_or(false)
            })
            .count() as i64
    };
    Ok(StatsOverview {
        total,
        pending,
        done,
        done_last_7d: in_last(7),
        done_last_30d: in_last(30),
    })
}

async fn stats_heatmap_impl(pool: &SqlitePool, days: i64) -> CoreResult<HeatmapData> {
    let rows = fetch_stat_rows(pool).await?;

    // 窗口：今天往回 days-1 天（含今天共 days 格）
    let today_idx = local_day_index(now_ms());
    let start_idx = today_idx - (days - 1);

    let mut counts: std::collections::HashMap<i64, i64> = std::collections::HashMap::new();
    for r in rows.iter().filter(|r| r.done == 1) {
        if let Some(ts) = r.done_at {
            let idx = local_day_index(ts);
            if idx >= start_idx && idx <= today_idx {
                *counts.entry(idx).or_insert(0) += 1;
            }
        }
    }

    // day index → YYYY-MM-DD：基准用今天的本地日期逐日回退（chrono NaiveDate 支持
    // signed_days_offset，窗口最长 371 天不会溢出）
    let today_local = chrono::Local::now().date_naive();
    let cells: Vec<HeatmapCell> = (0..days)
        .map(|offset| {
            let d = today_local - chrono::Duration::days(days - 1 - offset);
            let idx = start_idx + offset;
            HeatmapCell {
                date: d.format("%Y-%m-%d").to_string(),
                count: counts.get(&idx).copied().unwrap_or(0),
            }
        })
        .collect();

    Ok(HeatmapData {
        start_date: cells.first().map(|c| c.date.clone()).unwrap_or_default(),
        end_date: cells.last().map(|c| c.date.clone()).unwrap_or_default(),
        cells,
    })
}

/// streak 双值计算（纯函数，单测注入固定日集）
fn compute_streak(done_indices: &std::collections::HashSet<i64>, today_idx: i64) -> StreakData {
    let done_today = done_indices.contains(&today_idx);

    // 当前连续：今天有完成从今天起，否则从昨天起（昨天无完成 → 0）
    let anchor = if done_today { today_idx } else { today_idx - 1 };
    let mut current = 0i64;
    let mut idx = anchor;
    while done_indices.contains(&idx) {
        current += 1;
        idx -= 1;
    }

    // 最长连续：排序去重后线性扫
    let mut best = 0i64;
    let mut sorted: Vec<i64> = done_indices.iter().copied().collect();
    sorted.sort_unstable();
    let mut run = 0i64;
    let mut prev: Option<i64> = None;
    for &i in &sorted {
        run = if prev == Some(i - 1) { run + 1 } else { 1 };
        best = best.max(run);
        prev = Some(i);
    }

    StreakData {
        current,
        best,
        done_today,
    }
}

async fn stats_streak_impl(pool: &SqlitePool) -> CoreResult<StreakData> {
    let rows = fetch_stat_rows(pool).await?;
    let today_idx = local_day_index(now_ms());
    let done_indices: std::collections::HashSet<i64> = rows
        .iter()
        .filter(|r| r.done == 1)
        .filter_map(|r| r.done_at)
        .map(local_day_index)
        .collect();
    Ok(compute_streak(&done_indices, today_idx))
}

async fn stats_by_project_impl(pool: &SqlitePool) -> CoreResult<Vec<ProjectDistRow>> {
    let rows: Vec<(Option<i64>, String, String, i64, i64)> = sqlx::query_as(
        "SELECT t.project_id, \
                CASE WHEN t.project_id IS NULL THEN '' ELSE p.title END, \
                CASE WHEN t.project_id IS NULL THEN '' ELSE p.hex_color END, \
                SUM(CASE WHEN t.done = 1 THEN 1 ELSE 0 END), \
                SUM(CASE WHEN t.done = 0 THEN 1 ELSE 0 END) \
         FROM todo_tasks t LEFT JOIN todo_projects p ON t.project_id = p.id \
         WHERE t.is_deleted = 0 \
         GROUP BY t.project_id \
         ORDER BY 4 DESC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(pid, title, hex, done, pending)| ProjectDistRow {
            project_id: pid,
            project_title: if pid.is_some() { Some(title) } else { None },
            project_hex_color: if pid.is_some() { Some(hex) } else { None },
            done_count: done,
            pending_count: pending,
        })
        .collect())
}

async fn stats_by_priority_impl(pool: &SqlitePool) -> CoreResult<Vec<PriorityDistRow>> {
    let rows: Vec<(i64, i64, i64)> = sqlx::query_as(
        "SELECT priority, \
                SUM(CASE WHEN done = 1 THEN 1 ELSE 0 END), \
                SUM(CASE WHEN done = 0 THEN 1 ELSE 0 END) \
         FROM todo_tasks WHERE is_deleted = 0 \
         GROUP BY priority ORDER BY priority ASC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(p, done, pending)| PriorityDistRow {
            priority: p,
            done_count: done,
            pending_count: pending,
        })
        .collect())
}

async fn stats_by_weekday_impl(pool: &SqlitePool) -> CoreResult<Vec<WeekdayDistRow>> {
    // 星期分桶在 Rust 侧做（SQLite 无本地时区日界概念）
    let rows = fetch_stat_rows(pool).await?;
    let mut counts = vec![0i64; 7];
    for r in rows.iter().filter(|r| r.done == 1) {
        if let Some(ts) = r.done_at {
            let wd = Utc.timestamp_millis_opt(ts)
                .single()
                .unwrap_or_else(|| Utc.timestamp_millis_opt(0).single().unwrap())
                .with_timezone(&chrono::Local)
                .weekday()
                .num_days_from_monday() as i64;
            counts[wd as usize] += 1;
        }
    }
    Ok(counts
        .into_iter()
        .enumerate()
        .map(|(wd, c)| WeekdayDistRow {
            weekday: wd as i64,
            done_count: c,
        })
        .collect())
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// 一次性聚合结果
#[derive(Debug, Clone, Serialize)]
pub struct StatsAggregate {
    pub overview: StatsOverview,
    pub heatmap: HeatmapData,
    pub streak: StreakData,
    pub by_project: Vec<ProjectDistRow>,
    pub by_priority: Vec<PriorityDistRow>,
    pub by_weekday: Vec<WeekdayDistRow>,
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::business_api;
    use crate::api::business_api::create_todo_task;
    use crate::models::business::TodoTaskCreateInput;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    fn input(title: &str) -> TodoTaskCreateInput {
        TodoTaskCreateInput {
            title: title.to_string(),
            description: None,
            project_id: None,
            priority: None,
            status: None,
            done: None,
            done_at: None,
            due_date: None,
            start_date: None,
            end_date: None,
            repeat_after: None,
            repeat_mode: None,
            position: None,
            is_favorite: None,
            my_day_date: None,
        }
    }

    /// 造一个已完成任务（done_at 指定）
    async fn seed_done(pool: &SqlitePool, title: &str, done_at: i64, priority: i32) {
        let mut inp = input(title);
        inp.priority = Some(priority);
        inp.done = Some(1);
        inp.done_at = Some(done_at);
        create_todo_task(pool, &inp).await.unwrap();
    }

    async fn seed_pending(pool: &SqlitePool, title: &str, priority: i32) {
        let mut inp = input(title);
        inp.priority = Some(priority);
        create_todo_task(pool, &inp).await.unwrap();
    }

    #[tokio::test]
    async fn overview_counts_and_recent_windows() {
        let pool = setup_db().await;
        let now = now_ms();
        // 今天 1 条、昨天 2 条、10 天前 3 条、60 天前 4 条，待办 2 条
        seed_done(&pool, "a", now, 0).await;
        seed_done(&pool, "b", now - DAY_MS - 3_600_000, 0).await;
        seed_done(&pool, "c", now - DAY_MS - 3_600_000, 0).await;
        seed_done(&pool, "d", now - 10 * DAY_MS, 0).await;
        seed_done(&pool, "e", now - 10 * DAY_MS, 0).await;
        seed_done(&pool, "f", now - 10 * DAY_MS, 0).await;
        seed_done(&pool, "g", now - 60 * DAY_MS, 0).await;
        seed_done(&pool, "h", now - 62 * DAY_MS, 0).await;
        seed_done(&pool, "i", now - 62 * DAY_MS, 0).await;
        seed_done(&pool, "j", now - 62 * DAY_MS, 0).await;
        seed_pending(&pool, "p1", 0).await;
        seed_pending(&pool, "p2", 1).await;

        let o = stats_overview_impl(&pool).await.unwrap();
        assert_eq!(o.total, 12);
        assert_eq!(o.done, 10);
        assert_eq!(o.pending, 2);
        assert_eq!(o.done_last_7d, 3, "今天1 + 昨天2");
        assert_eq!(o.done_last_30d, 6, "再加10天前的3条");
    }

    #[tokio::test]
    async fn heatmap_spans_every_day_including_zero_days() {
        let pool = setup_db().await;
        let now = now_ms();
        seed_done(&pool, "t", now, 0).await;
        seed_done(&pool, "y", now - DAY_MS, 0).await;
        seed_done(&pool, "y2", now - DAY_MS, 0).await;

        let h = stats_heatmap_impl(&pool, 35).await.unwrap();
        assert_eq!(h.cells.len(), 35);
        let last = h.cells.last().unwrap();
        assert_eq!(last.count, 1, "今天 1 条");
        assert_eq!(h.cells[33].count, 2, "昨天 2 条");
        assert!(h.cells.iter().any(|c| c.count == 0), "应有零完成日");
        assert_eq!(h.end_date, last_date_str());
    }

    fn last_date_str() -> String {
        chrono::Local::now().date_naive().format("%Y-%m-%d").to_string()
    }

    #[tokio::test]
    async fn streak_today_and_best() {
        let pool = setup_db().await;
        let now = now_ms();
        // 今天 + 前两天 → current 3；再在 10 天前放一条保证 best 不变 3
        for i in 0..3 {
            seed_done(&pool, &format!("s{i}"), now - i * DAY_MS, 0).await;
        }
        seed_done(&pool, "old", now - 10 * DAY_MS, 0).await;

        let s = stats_streak_impl(&pool).await.unwrap();
        assert!(s.done_today);
        assert_eq!(s.current, 3);
        assert_eq!(s.best, 3);
    }

    #[tokio::test]
    async fn streak_zero_when_yesterday_missed() {
        let pool = setup_db().await;
        let now = now_ms();
        // 只有 10 天前的完成
        seed_done(&pool, "old", now - 10 * DAY_MS, 0).await;

        let s = stats_streak_impl(&pool).await.unwrap();
        assert!(!s.done_today);
        assert_eq!(s.current, 0, "昨天无完成，当前连续为 0");
    }

    #[tokio::test]
    async fn by_priority_and_weekday_bucketing() {
        let pool = setup_db().await;
        let now = now_ms();
        seed_done(&pool, "hi", now, 3).await;
        seed_done(&pool, "hi2", now, 3).await;
        seed_pending(&pool, "lo", 0).await;

        let p = stats_by_priority_impl(&pool).await.unwrap();
        assert!(p.iter().any(|r| r.priority == 3 && r.done_count == 2));
        assert!(p.iter().any(|r| r.priority == 0 && r.pending_count == 1));

        let w = stats_by_weekday_impl(&pool).await.unwrap();
        assert_eq!(w.len(), 7);
        assert_eq!(w.iter().map(|r| r.done_count).sum::<i64>(), 2, "2 条已完成");
    }

    #[tokio::test]
    async fn by_project_carries_project_hex_color() {
        let pool = setup_db().await;
        // 自建项目带自选色；未分组行无色（前端自定中性色）
        let proj = business_api::create_todo_project(
            &pool,
            &crate::models::business::TodoProjectCreateInput {
                title: "工作".to_string(),
                description: None,
                hex_color: Some("#2DB87A".to_string()),
                sort_order: None,
            },
        )
        .await
        .unwrap();

        let mut inp = input("t1");
        inp.project_id = Some(proj.id);
        inp.done = Some(1);
        inp.done_at = Some(now_ms());
        create_todo_task(&pool, &inp).await.unwrap();
        seed_pending(&pool, "u1", 0).await;

        let rows = stats_by_project_impl(&pool).await.unwrap();
        let grouped = rows.iter().find(|r| r.project_id == Some(proj.id)).unwrap();
        assert_eq!(grouped.project_title.as_deref(), Some("工作"));
        assert_eq!(grouped.project_hex_color.as_deref(), Some("#2DB87A"));
        let ungrouped = rows.iter().find(|r| r.project_id.is_none()).unwrap();
        assert!(ungrouped.project_hex_color.is_none(), "未分组行不带色");
    }

    #[tokio::test]
    async fn aggregate_returns_all_sections() {
        let pool = setup_db().await;
        seed_done(&pool, "x", now_ms(), 0).await;
        let agg = aggregate(&pool, 53).await.unwrap();
        assert_eq!(agg.overview.total, 1);
        assert_eq!(agg.heatmap.cells.len(), 53);
        assert!(agg.streak.done_today);
        assert!(!agg.by_priority.is_empty());
        assert_eq!(agg.by_weekday.len(), 7);
    }
}

// 纯函数直接测：streak 断档规则
#[cfg(test)]
mod streak_fn_tests {
    use super::compute_streak;
    use std::collections::HashSet;

    fn set(v: &[i64]) -> HashSet<i64> {
        v.iter().copied().collect()
    }

    #[test]
    fn streak_fn_break_rules() {
        // 今天无、昨天有前2 → current 2（昨天起算）
        let s = compute_streak(&set(&[9, 8]), 10);
        assert_eq!(s.current, 2);
        assert!(!s.done_today);

        // 今天有、昨天断 → current 1
        let s = compute_streak(&set(&[10, 8]), 10);
        assert_eq!(s.current, 1);
        assert!(s.done_today);

        // best 跨越断档取最长
        let s = compute_streak(&set(&[10, 9, 5, 4, 3, 2]), 10);
        assert_eq!(s.current, 2);
        assert_eq!(s.best, 4);
    }
}
