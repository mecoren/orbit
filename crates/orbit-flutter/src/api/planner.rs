//! planner — 移动端桥接层日排程域（F3 阶段一只读预览，ADR 0013）
//!
//! 与桌面壳命令一一对应（业务全部在 `orbit_core::api::day_planner_api`）：
//! - day_plan_preview → 桌面 planner_cmd 同名命令（只读，不写库不 emit）。
//!
//! ## DTO 镜像模式
//! [DayPlanPrefs] / [PlanSlot] / [UnscheduledTask] / [DayPlan] 为本模块本地
//! DTO（同 [super::digest] 的 DigestPrefs 规则：显式镜像 core 的结构，
//! 不直接暴露 core 类型）。

use orbit_core::api::day_planner_api;
use serde::{Deserialize, Serialize};

/// 排程偏好（镜像 core day_planner_api::DayPlanPrefs；相对今天零点的分钟）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DayPlanPrefs {
    pub work_start_minute: i64,
    pub work_end_minute: i64,
    pub lunch_start_minute: i64,
    pub lunch_end_minute: i64,
    pub granularity_minutes: i64,
    pub default_task_minutes: i64,
    pub include_overdue: bool,
}

impl From<DayPlanPrefs> for day_planner_api::DayPlanPrefs {
    fn from(p: DayPlanPrefs) -> Self {
        Self {
            work_start_minute: p.work_start_minute,
            work_end_minute: p.work_end_minute,
            lunch_start_minute: p.lunch_start_minute,
            lunch_end_minute: p.lunch_end_minute,
            granularity_minutes: p.granularity_minutes,
            default_task_minutes: p.default_task_minutes,
            include_overdue: p.include_overdue,
        }
    }
}

/// 单个排程建议（镜像 core PlanSlot）
#[derive(Debug, Clone, Serialize)]
pub struct PlanSlot {
    pub task_id: i64,
    pub title: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_minutes: i64,
    pub reason: String,
}

impl From<day_planner_api::PlanSlot> for PlanSlot {
    fn from(s: day_planner_api::PlanSlot) -> Self {
        Self {
            task_id: s.task_id,
            title: s.title,
            start_ms: s.start_ms,
            end_ms: s.end_ms,
            duration_minutes: s.duration_minutes,
            reason: s.reason,
        }
    }
}

/// 未排入任务（镜像 core UnscheduledTask）
#[derive(Debug, Clone, Serialize)]
pub struct UnscheduledTask {
    pub task_id: i64,
    pub title: String,
    pub reason: String,
}

impl From<day_planner_api::UnscheduledTask> for UnscheduledTask {
    fn from(u: day_planner_api::UnscheduledTask) -> Self {
        Self {
            task_id: u.task_id,
            title: u.title,
            reason: u.reason,
        }
    }
}

/// 日排程预览（镜像 core DayPlan）
#[derive(Debug, Clone, Serialize)]
pub struct DayPlan {
    pub slots: Vec<PlanSlot>,
    pub unscheduled: Vec<UnscheduledTask>,
    pub capacity_minutes: i64,
    pub load_minutes: i64,
    pub overloaded: bool,
    pub day_start_ms: i64,
}

impl From<day_planner_api::DayPlan> for DayPlan {
    fn from(p: day_planner_api::DayPlan) -> Self {
        Self {
            slots: p.slots.into_iter().map(PlanSlot::from).collect(),
            unscheduled: p
                .unscheduled
                .into_iter()
                .map(UnscheduledTask::from)
                .collect(),
            capacity_minutes: p.capacity_minutes,
            load_minutes: p.load_minutes,
            overloaded: p.overloaded,
            day_start_ms: p.day_start_ms,
        }
    }
}

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// 规划今天：只读排程预览（对应桌面 day_plan_preview；now_ms 由 Dart 传
/// DateTime.now().millisecondsSinceEpoch——本地日界换算在 core）
pub async fn day_plan_preview(prefs: DayPlanPrefs, now_ms: i64) -> Result<DayPlan, String> {
    let pool = pool()?;
    day_planner_api::plan_day(&pool, &prefs.into(), now_ms)
        .await
        .map_err(|e| e.to_string())
        .map(DayPlan::from)
}
