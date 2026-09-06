//! stats — 移动端桥接层统计域（backlog #25：统计仪表盘）
//!
//! 与桌面壳命令一一对应（业务全部在 orbit_core::api::stats_api）：
//! - stats_aggregate → 桌面 stats_aggregate：一次性返回全部统计卡片。
//!
//! DTO 镜像模式：本模块本地 DTO（StatsAggregate 及子结构，同 [super::trash]
//! 的 TrashMeta 规则——Rust core 的 Serialize 结构不直接暴露给 FRB，桥层
//! 显式镜像保持两端壳各自的演进自由度）。只读聚合，不 emit 事件。

use orbit_core::api::stats_api;

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

// ============================================================================
// DTO 镜像（core stats_api 结构 → FRB 可见）
// ============================================================================

/// 总览卡（镜像 core StatsOverview）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsOverview {
    pub total: i64,
    pub pending: i64,
    pub done: i64,
    pub done_last_7d: i64,
    pub done_last_30d: i64,
}

/// 热力图单格（镜像 core HeatmapCell）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsHeatmapCell {
    pub date: String,
    pub count: i64,
}

/// 热力图数据（镜像 core HeatmapData）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsHeatmap {
    pub start_date: String,
    pub end_date: String,
    pub cells: Vec<StatsHeatmapCell>,
}

/// 连续完成天数（镜像 core StreakData）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsStreak {
    pub current: i64,
    pub best: i64,
    pub done_today: bool,
}

/// 项目分布行（镜像 core ProjectDistRow；title None = 未分组）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsProjectRow {
    pub project_id: Option<i64>,
    pub project_title: Option<String>,
    pub done_count: i64,
    pub pending_count: i64,
}

/// 优先级分布行（镜像 core PriorityDistRow）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsPriorityRow {
    pub priority: i64,
    pub done_count: i64,
    pub pending_count: i64,
}

/// 星期分布行（镜像 core WeekdayDistRow；0=周一 … 6=周日）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsWeekdayRow {
    pub weekday: i64,
    pub done_count: i64,
}

/// 一次性聚合结果（镜像 core StatsAggregate）
#[derive(Debug, Clone, serde::Serialize)]
pub struct StatsAggregate {
    pub overview: StatsOverview,
    pub heatmap: StatsHeatmap,
    pub streak: StatsStreak,
    pub by_project: Vec<StatsProjectRow>,
    pub by_priority: Vec<StatsPriorityRow>,
    pub by_weekday: Vec<StatsWeekdayRow>,
}

impl From<stats_api::StatsAggregate> for StatsAggregate {
    fn from(a: stats_api::StatsAggregate) -> Self {
        Self {
            overview: StatsOverview {
                total: a.overview.total,
                pending: a.overview.pending,
                done: a.overview.done,
                done_last_7d: a.overview.done_last_7d,
                done_last_30d: a.overview.done_last_30d,
            },
            heatmap: StatsHeatmap {
                start_date: a.heatmap.start_date,
                end_date: a.heatmap.end_date,
                cells: a
                    .heatmap
                    .cells
                    .into_iter()
                    .map(|c| StatsHeatmapCell {
                        date: c.date,
                        count: c.count,
                    })
                    .collect(),
            },
            streak: StatsStreak {
                current: a.streak.current,
                best: a.streak.best,
                done_today: a.streak.done_today,
            },
            by_project: a
                .by_project
                .into_iter()
                .map(|r| StatsProjectRow {
                    project_id: r.project_id,
                    project_title: r.project_title,
                    done_count: r.done_count,
                    pending_count: r.pending_count,
                })
                .collect(),
            by_priority: a
                .by_priority
                .into_iter()
                .map(|r| StatsPriorityRow {
                    priority: r.priority,
                    done_count: r.done_count,
                    pending_count: r.pending_count,
                })
                .collect(),
            by_weekday: a
                .by_weekday
                .into_iter()
                .map(|r| StatsWeekdayRow {
                    weekday: r.weekday,
                    done_count: r.done_count,
                })
                .collect(),
        }
    }
}

/// 统计聚合（days 为热力图窗口天数，35–371 钳制；None = 182 半年）
pub async fn stats_aggregate(days: Option<i64>) -> Result<StatsAggregate, String> {
    let pool = pool()?;
    stats_api::aggregate(&pool, days.unwrap_or(182))
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
}
