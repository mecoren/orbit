//! day_planner_api — 本地启发式日排程（F3，docs/13 §五 F3，对标 Motion/Reclaim 的
//! 本地可解释替代，ADR 0013）
//!
//! **阶段一：只读预览**——不写库、不 emit 事件、不联网；输入任务集与作息偏好，
//! 输出确定性排程建议（时段 + 理由）、未排入清单与超载提示。应用写入
//! （my_day_date + start_date，不改 due_date）属阶段二，另行立项。
//!
//! 口径与约束：
//! - **确定性**：相同输入相同输出（排序全键稳定：bucket → 桶内 key → duration → id），
//!   便于测试与「为什么排在这」的解释；
//! - **硬约束**：不排到过去（从 now 向上对齐粒度）；不与已排时段重叠；
//!   今日带时刻的截止不越线（放不下即未排入，不挪截止）；固定时长放不下
//!   则顺延到下一段/未排入；
//! - **DST 安全**：[plan_day_slots] 纯函数完全在「相对今天零点的分钟」整数域
//!   运算（零 chrono 依赖），毫秒 ↔ 分钟的换算只在 [plan_day] 边界做一次；
//! - **只读聚合不进同步白名单**、不 emit db-change（与统计同族）。

use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::api::digest_api::local_day_start;
use crate::error::CoreResult;

/// 一天的分钟数（分钟域的天界）
const MINUTES_PER_DAY: i64 = 24 * 60;

/// 排程偏好（阶段一双端传默认值；阶段三落 cfg_kv 本地偏好可编辑。
/// Deserialize 供双端壳的 JSON 反序列化进命令入参）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DayPlanPrefs {
    /// 工作开始（相对今天零点的分钟；默认 09:00 = 540）
    pub work_start_minute: i64,
    /// 工作结束（默认 18:00 = 1080）
    pub work_end_minute: i64,
    /// 午休开始（默认 12:00 = 720；不落在工作窗内时视为无午休）
    pub lunch_start_minute: i64,
    /// 午休结束（默认 13:00 = 780）
    pub lunch_end_minute: i64,
    /// 排程粒度（分钟；默认 15，向上对齐）
    pub granularity_minutes: i64,
    /// 无时长任务的默认时长（分钟；默认 30——`duration_minutes` 缺省时兜底）
    pub default_task_minutes: i64,
    /// 是否把逾期任务纳入排程（默认 true）
    pub include_overdue: bool,
}

impl Default for DayPlanPrefs {
    fn default() -> Self {
        Self {
            work_start_minute: 9 * 60,
            work_end_minute: 18 * 60,
            lunch_start_minute: 12 * 60,
            lunch_end_minute: 13 * 60,
            granularity_minutes: 15,
            default_task_minutes: 30,
            include_overdue: true,
        }
    }
}

/// 单个排程建议（时段 + 任务 + 理由）
#[derive(Debug, Clone, Serialize)]
pub struct PlanSlot {
    pub task_id: i64,
    pub title: String,
    /// 开始/结束（本地墙钟毫秒，今天内）
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_minutes: i64,
    /// 可解释理由（「已逾期 N 天」「截止 HH:mm」「紧急优先」「高优先级」「我的一天」「填充空档」「顺序安排」）
    pub reason: String,
}

/// 未排入任务与原因
#[derive(Debug, Clone, Serialize)]
pub struct UnscheduledTask {
    pub task_id: i64,
    pub title: String,
    /// 「晚于截止 HH:mm」「今日时段已满」「已过工作时间」
    pub reason: String,
}

/// 日排程预览（只读）
#[derive(Debug, Clone, Serialize)]
pub struct DayPlan {
    pub slots: Vec<PlanSlot>,
    pub unscheduled: Vec<UnscheduledTask>,
    /// 今天剩余可排容量（分钟；已扣午休与已过时段）
    pub capacity_minutes: i64,
    /// 候选任务总时长（分钟）
    pub load_minutes: i64,
    /// 候选总量超出剩余容量（前端给警示条；不阻断预览）
    pub overloaded: bool,
    /// 今天零点（毫秒；前端时间轴基准）
    pub day_start_ms: i64,
}

/// 排程器输入（分钟域投影；[plan_day] 从库行换算，单测直接构造）
#[derive(Debug, Clone)]
pub struct PlannerTask {
    pub id: i64,
    pub title: String,
    pub priority: i32,
    /// 截止相对今天零点的分钟：负数 = 逾期；0 = 今天纯日期；1..1439 = 今天带时刻；
    /// ≥1440 = 未来（不该出现在候选里，兜底按纯日期档）
    pub due_minute: Option<i64>,
    /// 我的一天（今天）
    pub is_my_day: bool,
    pub duration_minutes: Option<i64>,
}

impl PlannerTask {
    fn duration(&self, default_minutes: i64) -> i64 {
        self.duration_minutes
            .filter(|d| *d > 0)
            .unwrap_or(default_minutes)
    }
}

/// 排序桶：0 逾期 → 1 今日带时刻截止（EDF）→ 2 今日/未来纯日期截止 → 3 我的一天 → 4 未排期带时长
fn bucket_of(t: &PlannerTask) -> i32 {
    match t.due_minute {
        Some(d) if d < 0 => 0,
        Some(d) if d > 0 && d < MINUTES_PER_DAY => 1,
        Some(_) => 2,
        None if t.is_my_day => 3,
        _ => 4,
    }
}

/// 本地 HH:mm 文案（相对今天零点的分钟）
fn hhmm(minute: i64) -> String {
    format!("{:02}:{:02}", minute / 60, minute % 60)
}

/// 排程纯函数：候选任务 → (已排时段, 未排入)。
///
/// 排序（docs/13：逾期 → 今日截止 EDF → 优先级 → 我的一天 → 其余；同档短任务优先）：
/// bucket → 桶内 key（逾期=due 升序最老先、带时刻=截止时刻升序、其余=优先级降序）
/// → duration 升序 → id 升序（全键稳定 = 确定性）。
///
/// `now_minute`：相对今天零点的当前分钟；段内放置从 `max(段起, now)` 向上对齐粒度。
pub fn plan_day_slots(
    tasks: &[PlannerTask],
    prefs: &DayPlanPrefs,
    now_minute: i64,
) -> (Vec<PlanSlot>, Vec<UnscheduledTask>) {
    let gran = prefs.granularity_minutes.max(1);
    let mut candidates: Vec<&PlannerTask> = tasks
        .iter()
        .filter(|t| !(t.due_minute.is_some_and(|d| d < 0) && !prefs.include_overdue))
        .collect();
    candidates.sort_by(|a, b| {
        let (ba, bb) = (bucket_of(a), bucket_of(b));
        ba.cmp(&bb)
            .then_with(|| match ba {
                0 => a.due_minute.cmp(&b.due_minute),
                1 => a.due_minute.cmp(&b.due_minute),
                _ => (-(a.priority as i64)).cmp(&(-(b.priority as i64))),
            })
            .then_with(|| {
                a.duration(prefs.default_task_minutes)
                    .cmp(&b.duration(prefs.default_task_minutes))
            })
            .then_with(|| a.id.cmp(&b.id))
    });

    // 可排段（分钟域）：工作窗挖掉午休（午休不落工作窗内 = 无午休）
    let lunch_active = prefs.lunch_start_minute > prefs.work_start_minute
        && prefs.lunch_end_minute < prefs.work_end_minute;
    let segments: Vec<(i64, i64)> = if lunch_active {
        vec![
            (prefs.work_start_minute, prefs.lunch_start_minute),
            (prefs.lunch_end_minute, prefs.work_end_minute),
        ]
    } else {
        vec![(prefs.work_start_minute, prefs.work_end_minute)]
    };

    let mut cursor = now_minute;
    let mut slots: Vec<PlanSlot> = Vec::new();
    let mut unscheduled: Vec<UnscheduledTask> = Vec::new();
    let mut prev_end: Option<i64> = None;

    for t in candidates {
        let duration = t.duration(prefs.default_task_minutes);
        // 今日带时刻截止才设硬线（逾期已过、纯日期/未来不设线）
        let deadline = t.due_minute.filter(|d| *d > 0 && *d < MINUTES_PER_DAY);

        let mut placed: Option<(i64, i64)> = None;
        for (s, e) in &segments {
            let seg_start = (*s).max(cursor);
            // 向上对齐粒度
            let start = seg_start + (gran - seg_start.rem_euclid(gran)) % gran;
            let end = start + duration;
            if start >= *e || end > *e {
                continue;
            }
            if let Some(dl) = deadline {
                if end > dl {
                    continue;
                }
            }
            placed = Some((start, end));
            break;
        }

        match placed {
            Some((start, end)) => {
                let reason = if bucket_of(t) == 0 {
                    format!(
                        "已逾期 {} 天",
                        (-t.due_minute.unwrap_or(0) + MINUTES_PER_DAY - 1) / MINUTES_PER_DAY
                    )
                } else if let Some(dl) = deadline {
                    format!("截止 {}", hhmm(dl))
                } else if t.priority >= 4 {
                    "紧急优先".to_string()
                } else if t.priority == 3 {
                    "高优先级".to_string()
                } else if bucket_of(t) == 3 {
                    "我的一天".to_string()
                } else if prev_end.is_some_and(|pe| start > pe) {
                    "填充空档".to_string()
                } else {
                    "顺序安排".to_string()
                };
                prev_end = Some(end);
                cursor = end;
                slots.push(PlanSlot {
                    task_id: t.id,
                    title: t.title.clone(),
                    // 分钟域毫秒占位（相对今天零点）；plan_day 加回 day_start_ms
                    start_ms: start * 60_000,
                    end_ms: end * 60_000,
                    duration_minutes: duration,
                    reason,
                });
            }
            None => {
                let reason = if now_minute >= prefs.work_end_minute {
                    "已过工作时间".to_string()
                } else if let Some(dl) = deadline {
                    format!("晚于截止 {}", hhmm(dl))
                } else {
                    "今日时段已满".to_string()
                };
                unscheduled.push(UnscheduledTask {
                    task_id: t.id,
                    title: t.title.clone(),
                    reason,
                });
            }
        }
    }

    (slots, unscheduled)
}

/// 剩余可排容量（分钟）：各段与其内已过部分之差
fn capacity_minutes(prefs: &DayPlanPrefs, now_minute: i64) -> i64 {
    let lunch_active = prefs.lunch_start_minute > prefs.work_start_minute
        && prefs.lunch_end_minute < prefs.work_end_minute;
    if lunch_active {
        (prefs.lunch_start_minute - prefs.work_start_minute.max(now_minute)).max(0)
            + (prefs.work_end_minute - prefs.lunch_end_minute.max(now_minute)).max(0)
    } else {
        (prefs.work_end_minute - prefs.work_start_minute.max(now_minute)).max(0)
    }
}

/// 日排程预览（只读聚合）：从库内归集候选任务 → 分钟域投影 → [plan_day_slots]。
///
/// 候选口径（docs/13 F3 输入）：今日到期 / 逾期 / 我的一天（今天）/ 未排期且带时长，
/// 均须未完成未软删。fetch_all 无 LIMIT：候选由日期窗口与 my_day/时长谓词收敛
/// （「今天相关」的任务，非全库；上界来源登记 docs/14 C 档）。
pub async fn plan_day(pool: &SqlitePool, prefs: &DayPlanPrefs, now_ms: i64) -> CoreResult<DayPlan> {
    let day_start_ms = local_day_start(now_ms);
    let day_end_ms = day_start_ms + 86_400_000;

    let rows: Vec<(i64, String, i32, Option<i64>, Option<i64>, Option<i64>)> = sqlx::query_as(
        "SELECT id, title, priority, due_date, my_day_date, duration_minutes FROM todo_tasks \
         WHERE is_deleted = 0 AND done = 0 AND ( \
           (due_date IS NOT NULL AND due_date >= ? AND due_date < ?) \
           OR (due_date IS NOT NULL AND due_date < ?) \
           OR (my_day_date IS NOT NULL AND my_day_date >= ? AND my_day_date < ?) \
           OR (due_date IS NULL AND duration_minutes IS NOT NULL) \
         )",
    )
    .bind(day_start_ms)
    .bind(day_end_ms)
    .bind(day_start_ms)
    .bind(day_start_ms)
    .bind(day_end_ms)
    .fetch_all(pool)
    .await?;

    let tasks: Vec<PlannerTask> = rows
        .into_iter()
        .filter(|(_, _, _, due, _, _)| {
            !(due.is_some_and(|d| d < day_start_ms) && !prefs.include_overdue)
        })
        .map(
            |(id, title, priority, due_date, my_day_date, duration_minutes)| PlannerTask {
                id,
                title,
                priority,
                due_minute: due_date.map(|d| (d - day_start_ms) / 60_000),
                is_my_day: my_day_date.is_some_and(|m| m >= day_start_ms && m < day_end_ms),
                duration_minutes,
            },
        )
        .collect();

    let load_minutes: i64 = tasks
        .iter()
        .map(|t| t.duration(prefs.default_task_minutes))
        .sum();
    let now_minute = ((now_ms - day_start_ms) / 60_000).max(0);
    let (mut slots, unscheduled) = plan_day_slots(&tasks, prefs, now_minute);
    for s in &mut slots {
        s.start_ms += day_start_ms;
        s.end_ms += day_start_ms;
    }

    Ok(DayPlan {
        capacity_minutes: capacity_minutes(prefs, now_minute),
        load_minutes,
        overloaded: load_minutes > capacity_minutes(prefs, now_minute),
        slots,
        unscheduled,
        day_start_ms,
    })
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod plan_day_slots_tests {
    use super::*;

    fn prefs() -> DayPlanPrefs {
        DayPlanPrefs::default() // 09:00-18:00，午休 12-13，粒度 15，默认 30 分钟
    }

    fn task(id: i64, title: &str, due_minute: Option<i64>) -> PlannerTask {
        PlannerTask {
            id,
            title: title.into(),
            priority: 0,
            due_minute,
            is_my_day: false,
            duration_minutes: Some(30),
        }
    }

    #[test]
    fn places_in_order_starting_from_now() {
        // now = 08:50 → 首个槽从 09:00 起（向上对齐粒度到段起）
        let tasks = [task(1, "甲", None), task(2, "乙", None)];
        let (slots, unscheduled) = plan_day_slots(&tasks, &prefs(), 8 * 60 + 50);
        assert!(unscheduled.is_empty());
        assert_eq!(slots.len(), 2);
        assert_eq!(slots[0].start_ms, 9 * 60 * 60_000);
        assert_eq!(slots[0].end_ms, 9 * 60 * 60_000 + 30 * 60_000);
        assert_eq!(slots[1].start_ms, (9 * 60 + 30) * 60_000);
        assert_eq!(slots[0].reason, "顺序安排");
    }

    #[test]
    fn skips_lunch_and_continues_after() {
        // 4×60 分钟任务：09:00-10:00? 60 分钟：甲(60) 09:00-10:00，乙(60) 10:00-11:00，
        // 丙(60) 11:00-12:00，丁(60) 放不进上午段（12:00 段尾）→ 跳过午休 13:00-14:00
        let mk = |id, m: i64| PlannerTask {
            duration_minutes: Some(m),
            ..task(id, "t", None)
        };
        let tasks = [mk(1, 60), mk(2, 60), mk(3, 60), mk(4, 60)];
        let (slots, unscheduled) = plan_day_slots(&tasks, &prefs(), 8 * 60);
        assert_eq!(slots.len(), 4);
        assert_eq!(slots[3].start_ms, 13 * 60 * 60_000, "丁跨午休落到 13:00");
        assert!(unscheduled.is_empty());
    }

    #[test]
    fn edf_orders_by_deadline_time_within_today() {
        // 同为今天带时刻截止：14:00 截止先于 16:00 截止（EDF），无视优先级
        let mut high = task(1, "紧急", Some(16 * 60));
        high.priority = 4;
        let mut low = task(2, "普通", Some(14 * 60));
        low.priority = 0;
        let (slots, _) = plan_day_slots(&[high, low], &prefs(), 8 * 60);
        assert_eq!(slots[0].task_id, 2, "EDF：14:00 截止先排");
        assert_eq!(slots[0].reason, "截止 14:00");
    }

    #[test]
    fn deadline_line_unplaceable_task_goes_unscheduled() {
        // now 17:00，截止 17:30 的 60 分钟任务放不下（end 18:00 > 17:30）→ 未排入
        //（30 分钟的恰好放进 17:00-17:30，不触发越线）
        let big = PlannerTask {
            duration_minutes: Some(60),
            ..task(1, "大活", Some(17 * 60 + 30))
        };
        let (slots, unscheduled) = plan_day_slots(&[big], &prefs(), 17 * 60);
        assert!(slots.is_empty());
        assert_eq!(unscheduled.len(), 1);
        assert_eq!(unscheduled[0].reason, "晚于截止 17:30");
    }

    #[test]
    fn overdue_first_and_respects_include_overdue_switch() {
        let overdue = task(1, "昨天的", Some(-24 * 60));
        let today = task(2, "今天的", Some(10 * 60));
        let (slots, _) = plan_day_slots(&[today.clone(), overdue.clone()], &prefs(), 8 * 60);
        assert_eq!(slots[0].task_id, 1, "逾期最先");
        assert!(slots[0].reason.starts_with("已逾期"));

        // 关闭逾期：候选剔除
        let mut p = prefs();
        p.include_overdue = false;
        let (slots, _) = plan_day_slots(&[today, overdue], &p, 8 * 60);
        assert_eq!(slots.len(), 1);
        assert_eq!(slots[0].task_id, 2);
    }

    #[test]
    fn my_day_bucket_before_undated_with_duration() {
        let myday = PlannerTask {
            is_my_day: true,
            ..task(1, "我的一天", None)
        };
        let undated = task(2, "带时长的未排期", None);
        let (slots, _) = plan_day_slots(&[undated, myday], &prefs(), 8 * 60);
        assert_eq!(slots[0].task_id, 1);
        assert_eq!(slots[0].reason, "我的一天");
    }

    #[test]
    fn short_task_fills_gap_and_reports_reason() {
        // 09:00 排 60 分钟甲 → 10:00；中途插入 15 分钟短任务乙（position 靠后但 duration 短）
        // 排序 duration 升序在同桶内先生乙：甲(60) 与乙(15) 同桶 → 乙先排 09:00-09:15，
        // 甲 09:15-10:15——「短任务优先填空」的直接体现
        let long = PlannerTask {
            duration_minutes: Some(60),
            ..task(1, "长活", None)
        };
        let short = PlannerTask {
            duration_minutes: Some(15),
            ..task(2, "短活", None)
        };
        let (slots, _) = plan_day_slots(&[long, short], &prefs(), 8 * 60);
        assert_eq!(slots[0].task_id, 2, "同桶内短任务优先");
        assert_eq!(slots[1].task_id, 1);
        assert_eq!(slots[1].reason, "顺序安排");
    }

    #[test]
    fn capacity_full_reports_unscheduled_with_reason() {
        // now 17:00，两个 60 分钟任务：只放得下一个（17:00-18:00），另一个未排入
        let mk = |id| PlannerTask {
            duration_minutes: Some(60),
            ..task(id, "t", None)
        };
        let (slots, unscheduled) = plan_day_slots(&[mk(1), mk(2)], &prefs(), 17 * 60);
        assert_eq!(slots.len(), 1);
        assert_eq!(unscheduled.len(), 1);
        assert_eq!(unscheduled[0].reason, "今日时段已满");
    }

    #[test]
    fn after_work_hours_everything_unscheduled() {
        let tasks = [task(1, "甲", None)];
        let (slots, unscheduled) = plan_day_slots(&tasks, &prefs(), 19 * 60);
        assert!(slots.is_empty());
        assert_eq!(unscheduled[0].reason, "已过工作时间");
    }

    #[test]
    fn deterministic_same_input_same_output() {
        let mk = |id: i64, d: i64, p: i32| PlannerTask {
            priority: p,
            duration_minutes: Some(d),
            ..task(id, "t", None)
        };
        let tasks = vec![mk(1, 30, 0), mk(2, 30, 3), mk(3, 15, 0), mk(4, 30, 3)];
        let (a, ua) = plan_day_slots(&tasks, &prefs(), 8 * 60);
        let (b, ub) = plan_day_slots(&tasks, &prefs(), 8 * 60);
        assert_eq!(
            a.iter()
                .map(|s| (s.task_id, s.start_ms))
                .collect::<Vec<_>>(),
            b.iter()
                .map(|s| (s.task_id, s.start_ms))
                .collect::<Vec<_>>()
        );
        assert_eq!(ua.len(), ub.len());
        // 优先级降序在同 duration 档内生效：3、4 优先于 1、2
        assert_eq!(a[0].task_id, 2, "同桶同时长：优先级高者先");
    }

    #[test]
    fn zero_duration_falls_back_to_default() {
        let t = PlannerTask {
            duration_minutes: Some(0),
            ..task(1, "零时长", None)
        };
        let (slots, _) = plan_day_slots(&[t], &prefs(), 8 * 60);
        assert_eq!(slots[0].duration_minutes, 30, "0/负时长回落默认 30 分钟");
    }
}

#[cfg(test)]
mod api_tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn mk_task(
        pool: &SqlitePool,
        title: &str,
        due: Option<i64>,
        my_day: Option<i64>,
        duration: Option<i64>,
    ) -> i64 {
        let row: (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, due_date, my_day_date, duration_minutes, is_deleted, done, created_at, updated_at, version) \
             VALUES (?, ?, ?, ?, ?, 0, 0, 1, 1, 1) RETURNING id",
        )
        .bind(format!("t-{title}"))
        .bind(title)
        .bind(due)
        .bind(my_day)
        .bind(duration)
        .fetch_one(pool)
        .await
        .unwrap();
        row.0
    }

    fn noon_today_ms() -> i64 {
        // 今天本地正午（DST 安全基准）
        let n = chrono::Utc::now().timestamp_millis();
        let start = local_day_start(n);
        start + 12 * 3_600_000
    }

    #[tokio::test]
    async fn collects_all_four_candidate_classes_and_offsets_to_wall_clock() {
        let pool = setup_db().await;
        let now = noon_today_ms();
        let day_start = local_day_start(now);
        // 四类候选：今日带时刻 14:00 / 逾期（昨天）/ 我的一天（今天零点）/ 未排期带时长
        mk_task(
            &pool,
            "今日时刻",
            Some(day_start + 14 * 3_600_000),
            None,
            Some(30),
        )
        .await;
        mk_task(&pool, "逾期", Some(day_start - 86_400_000), None, Some(30)).await;
        mk_task(&pool, "我的一天", None, Some(day_start), None).await;
        mk_task(&pool, "带时长", None, None, Some(45)).await;
        // 非候选：明天的截止 / 已完成 / 软删 / 无时长无 my_day
        mk_task(
            &pool,
            "明天",
            Some(day_start + 86_400_000 + 3_600_000),
            None,
            Some(30),
        )
        .await;
        mk_task(&pool, "已完成", None, None, Some(30)).await;
        sqlx::query("UPDATE todo_tasks SET done = 1 WHERE title = '已完成'")
            .execute(&pool)
            .await
            .unwrap();

        let plan = plan_day(&pool, &DayPlanPrefs::default(), now)
            .await
            .unwrap();
        let titles: Vec<&str> = plan.slots.iter().map(|s| s.title.as_str()).collect();
        assert!(titles.contains(&"逾期"), "逾期最先：{:?}", titles);
        assert_eq!(titles.first(), Some(&"逾期"));
        assert!(titles.contains(&"今日时刻"));
        assert!(titles.contains(&"我的一天"));
        assert!(titles.contains(&"带时长"));
        assert!(!titles.contains(&"明天") && !titles.contains(&"已完成"));
        // 毫秒已加回今天零点（时段落在 09:00-18:00 窗内）
        for s in &plan.slots {
            assert!(s.start_ms >= day_start + 9 * 3_600_000);
            assert!(s.end_ms <= day_start + 18 * 3_600_000);
        }
    }

    #[tokio::test]
    async fn overdue_excluded_by_pref_and_overload_flag_set() {
        let pool = setup_db().await;
        let now = noon_today_ms();
        let day_start = local_day_start(now);
        mk_task(
            &pool,
            "逾期大活",
            Some(day_start - 86_400_000),
            None,
            Some(600),
        )
        .await;

        // include_overdue = false：候选为空
        let mut p = DayPlanPrefs::default();
        p.include_overdue = false;
        let plan = plan_day(&pool, &p, now).await.unwrap();
        assert!(plan.slots.is_empty());
        assert!(!plan.overloaded);

        // include_overdue = true：600 分钟 > 剩余容量（约 300 分钟）→ 超载
        let plan = plan_day(&pool, &DayPlanPrefs::default(), now)
            .await
            .unwrap();
        assert!(plan.overloaded);
        assert!(plan.load_minutes > plan.capacity_minutes);
    }

    #[tokio::test]
    async fn my_day_outside_today_is_not_candidate() {
        let pool = setup_db().await;
        let now = noon_today_ms();
        let day_start = local_day_start(now);
        // my_day 标记在昨天且无时长无截止：不满足任何候选谓词（窗外 my_day
        // 不算「我的一天」档；若带时长会从「未排期带时长」谓词合法入选）
        mk_task(
            &pool,
            "昨天的标记",
            None,
            Some(day_start - 86_400_000),
            None,
        )
        .await;
        let plan = plan_day(&pool, &DayPlanPrefs::default(), now)
            .await
            .unwrap();
        assert!(plan.slots.is_empty());
        assert_eq!(plan.load_minutes, 0);
    }
}
