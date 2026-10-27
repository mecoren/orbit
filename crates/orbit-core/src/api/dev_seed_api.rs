//! dev_seed — 测试数据生成（仅测试环境可用）
//!
//! ## 定位
//!
//! `pnpm tauri dev` 起来后，手工点几十条任务只够看首屏：翻页续拉、看板列总数、
//! 日历范围查询、统计聚合、回收站、标签/提醒徽标全部测不到边界。本模块把
//! 「一键写一份结构完整的样本库」下沉到核心层，桌面壳只做薄转发（见
//! `apps/desktop/src-tauri/src/commands/dev_cmd.rs`）。
//!
//! ## 环境门禁
//!
//! 两道闸，缺一不可：
//! - 前端入口只在 Vite 的 `import.meta.env.DEV` 下渲染（设置 → 测试数据）；
//! - 壳层命令在 release 构建里直接返回不可用（`cfg!(debug_assertions)` 常量折叠），
//!   业务函数本身不感知环境，不得被生产路径调用。
//!
//! ## 为什么直写 SQL（不走 business_api）
//!
//! 几千行逐条走 `create_todo_*` 意味着几千次独立事务与几千条 db-change：
//! 这里改为**单事务批量 INSERT**（与 `examples/seed_demo_db.rs` 同口径），
//! 提交后按表补发一条 db-change 让前端缓存失效一次即可。
//!
//! ## 标记与幂等
//!
//! 所有行的 `uuid` 以 [`SEED_UUID_PREFIX`] 开头、标题以 [`SEED_TITLE_PREFIX`]
//! 开头。重复生成先按 uuid 前缀物理删除上一批：不叠数据、不碰手工数据。
//! 物理 DELETE 只发生在这一条测试数据路径上（生成物不是用户数据），业务删除
//! 仍一律软删进回收站。
//!
//! ## 口径
//!
//! - 日期分桶按**本地时区日界**（今天零点）铺，与列表/日历/统计的读数一致；
//! - 软删行先按活行插入再 UPDATE 成墓碑：FTS 的 INSERT 触发器不看 `is_deleted`，
//!   直接插墓碑行会让回收站任务混进搜索结果（UPDATE 触发器会把它摘掉）；
//! - 直写绕过 `generic_repo` 的拼音钩子，提交后 [`search_pinyin::mark_dirty`]
//!   置脏，首次拼音查询自动对账。

use std::time::Instant;

use chrono::TimeZone;
use serde::{Deserialize, Serialize};
use sqlx::{Sqlite, SqlitePool, Transaction};

use crate::db::{clock, search_pinyin};
use crate::error::CoreResult;
use crate::eventbus::EVENT_BUS;
use crate::eventbus::events::{DbEvent, DbOp};

/// 测试数据行的 uuid 前缀（清理与幂等生成的唯一判据）
pub const SEED_UUID_PREFIX: &str = "dev-seed-";

/// 测试数据的标题前缀：让用户一眼区分示例数据与手工数据
pub const SEED_TITLE_PREFIX: &str = "【示例】";

/// 单次生成的任务条数上限（防手滑把开发库写成十万行）
pub const MAX_TASKS: i64 = 20_000;

const DAY_MS: i64 = 86_400_000;
const HOUR_MS: i64 = 3_600_000;

/// 生成规模。
///
/// 只暴露任务条数：项目/标签是固定样本清单，子任务/提醒/评论/关联按固定比例
/// 派生——旋钮越多越难解释「这份数据到底覆盖了什么」。
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(default)]
pub struct DevSeedPlan {
    /// 任务条数（默认 1200；含约 2% 的回收站墓碑行）
    pub tasks: i64,
}

impl Default for DevSeedPlan {
    fn default() -> Self {
        Self { tasks: 1_200 }
    }
}

/// 各表写入/清除条数
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevSeedCounts {
    pub projects: i64,
    pub labels: i64,
    pub tasks: i64,
    pub subtasks: i64,
    pub reminders: i64,
    pub comments: i64,
    pub task_labels: i64,
    pub task_relations: i64,
}

impl DevSeedCounts {
    /// 合计（界面显示「共 N 行」）
    pub fn total(&self) -> i64 {
        self.projects
            + self.labels
            + self.tasks
            + self.subtasks
            + self.reminders
            + self.comments
            + self.task_labels
            + self.task_relations
    }
}

/// 生成结果（`cleared` = 生成前清掉的上一批）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevSeedResult {
    pub created: DevSeedCounts,
    pub cleared: DevSeedCounts,
    pub elapsed_ms: i64,
}

/// 清理结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevSeedClearResult {
    pub removed: DevSeedCounts,
    pub elapsed_ms: i64,
}

/// 生成一份样本库（先清上一批，再写入）。
///
/// 单事务：任何一步失败都回滚，不留半份数据。
pub async fn seed_demo_data(pool: &SqlitePool, plan: &DevSeedPlan) -> CoreResult<DevSeedResult> {
    let started = Instant::now();
    let task_count = plan.tasks.clamp(1, MAX_TASKS);
    let now = clock::next_ms();
    let today0 = local_today_start();
    // 每轮独立随机前缀：多设备各自生成不会撞同一 uuid（同步后按行合并而非互相覆盖）
    let run_uuid = uuid::Uuid::new_v4().simple().to_string();
    let run = &run_uuid[..8];

    let mut tx = pool.begin().await?;
    let cleared = delete_seed_rows(&mut tx).await?;
    let created = insert_seed_rows(&mut tx, task_count, run, now, today0).await?;
    tx.commit().await?;

    // 直写绕过 generic_repo 拼音钩子：置脏，首查自动对账（docs/07 #104）
    if let Err(e) = search_pinyin::mark_dirty(pool).await {
        log::warn!("dev_seed: 拼音索引置脏失败（首查对账兜底）：{e}");
    }
    emit_tables(&SEED_TABLES, DbOp::Insert);

    Ok(DevSeedResult {
        created,
        cleared,
        elapsed_ms: started.elapsed().as_millis() as i64,
    })
}

/// 只清除测试数据（按 uuid 前缀），不写新数据。
pub async fn clear_demo_data(pool: &SqlitePool) -> CoreResult<DevSeedClearResult> {
    let started = Instant::now();
    let mut tx = pool.begin().await?;
    let removed = delete_seed_rows(&mut tx).await?;
    tx.commit().await?;

    if removed.total() > 0 {
        if let Err(e) = search_pinyin::mark_dirty(pool).await {
            log::warn!("dev_seed: 拼音索引置脏失败（首查对账兜底）：{e}");
        }
        let touched: Vec<&str> = [
            ("todo_task_relations", removed.task_relations),
            ("todo_task_labels", removed.task_labels),
            ("todo_reminders", removed.reminders),
            ("todo_comments", removed.comments),
            ("todo_subtasks", removed.subtasks),
            ("todo_tasks", removed.tasks),
            ("todo_projects", removed.projects),
            ("todo_labels", removed.labels),
        ]
        .into_iter()
        .filter(|(_, n)| *n > 0)
        .map(|(table, _)| table)
        .collect();
        emit_tables(&touched, DbOp::Delete);
    }

    Ok(DevSeedClearResult {
        removed,
        elapsed_ms: started.elapsed().as_millis() as i64,
    })
}

/// 全部会被写入的表（失效链按表精确刷新；顺序 = 先子表后主表）
const SEED_TABLES: [&str; 8] = [
    "todo_task_relations",
    "todo_task_labels",
    "todo_reminders",
    "todo_comments",
    "todo_subtasks",
    "todo_tasks",
    "todo_projects",
    "todo_labels",
];

/// 示例项目：父项目按 [`PROJECTS`] 下标引用（落库时翻译成 parent_uuid）
struct SeedProject {
    title: &'static str,
    color: &'static str,
    parent: Option<usize>,
    archived: bool,
    /// 回顾周期（天）；`Some` 的项目会带「上次回顾 10 天前」，让回顾中心有数据
    review_days: Option<i64>,
}

const PROJECTS: &[SeedProject] = &[
    SeedProject {
        title: "工作",
        color: "#3B82F6",
        parent: None,
        archived: false,
        review_days: Some(7),
    },
    SeedProject {
        title: "研发",
        color: "#6366F1",
        parent: Some(0),
        archived: false,
        review_days: None,
    },
    SeedProject {
        title: "运营",
        color: "#8B5CF6",
        parent: Some(0),
        archived: false,
        review_days: None,
    },
    SeedProject {
        title: "生活",
        color: "#10B981",
        parent: None,
        archived: false,
        review_days: Some(14),
    },
    SeedProject {
        title: "家务",
        color: "#14B8A6",
        parent: Some(3),
        archived: false,
        review_days: None,
    },
    SeedProject {
        title: "学习",
        color: "#F59E0B",
        parent: None,
        archived: false,
        review_days: None,
    },
    SeedProject {
        title: "健康",
        color: "#EF4444",
        parent: None,
        archived: false,
        review_days: None,
    },
    SeedProject {
        title: "旧资料",
        color: "#6B7280",
        parent: None,
        archived: true,
        review_days: None,
    },
];

const LABELS: &[(&str, &str)] = &[
    ("紧急", "#EF4444"),
    ("重要", "#F97316"),
    ("等待中", "#A855F7"),
    ("家庭", "#10B981"),
    ("工作", "#3B82F6"),
    ("学习", "#F59E0B"),
];

/// 标题词库：中文便于验证 FTS trigram 与拼音首字母检索
const TITLE_HEADS: &[&str] = &[
    "整理季度报告",
    "准备周会材料",
    "复盘上周迭代",
    "采购办公用品",
    "读书笔记",
    "晨跑五公里",
    "缴纳水电费",
    "整理发票报销",
    "给家里打电话",
    "更新简历",
    "梳理需求池",
    "检查备份任务",
    "修复线上告警",
    "编写发布说明",
    "整理测试用例",
    "预约体检",
    "练习英语听力",
    "清理下载目录",
    "规划下季度目标",
    "跟进客户反馈",
];

const COMMENT_BODIES: &[&str] = &[
    "已和相关同事对齐，等对方补充数据",
    "这里需要再确认一次口径",
    "先按当前方案推进，下周复盘",
    "附：原始文件已放到共享目录",
];

/// 清掉上一批测试数据（按 uuid 前缀；先子表后主表，计数为 0 的项自然为 0）
async fn delete_seed_rows(tx: &mut Transaction<'_, Sqlite>) -> CoreResult<DevSeedCounts> {
    let like = format!("{SEED_UUID_PREFIX}%");
    Ok(DevSeedCounts {
        task_relations: delete_with_prefix(tx, "todo_task_relations", &like).await?,
        task_labels: delete_with_prefix(tx, "todo_task_labels", &like).await?,
        reminders: delete_with_prefix(tx, "todo_reminders", &like).await?,
        comments: delete_with_prefix(tx, "todo_comments", &like).await?,
        subtasks: delete_with_prefix(tx, "todo_subtasks", &like).await?,
        tasks: delete_with_prefix(tx, "todo_tasks", &like).await?,
        projects: delete_with_prefix(tx, "todo_projects", &like).await?,
        labels: delete_with_prefix(tx, "todo_labels", &like).await?,
    })
}

/// 表名只来自本模块常量，不拼接外部输入
async fn delete_with_prefix(
    tx: &mut Transaction<'_, Sqlite>,
    table: &str,
    like: &str,
) -> CoreResult<i64> {
    let sql = format!("DELETE FROM {table} WHERE uuid LIKE ?");
    let affected = sqlx::query(&sql)
        .bind(like)
        .execute(&mut **tx)
        .await?
        .rows_affected();
    Ok(affected as i64)
}

/// 写入项目 / 标签 / 任务及其子表。
///
/// 数据分布刻意覆盖每条读通道（与 `examples/seed_demo_db.rs` 同口径）：
/// - 30% 已完成（`done_at` 按「近密远疏」铺满 3 年，验 Logbook / 热力图年份切换 /
///   近 7 天与近 30 天卡片 / 连续完成天数）
/// - 20% 无截止（其中一半只有开始时间、一半完全未排期）、20% 逾期、
///   10% 今天到期、其余散在未来 30 天
/// - 约八成带 `start_date`：有截止的提前 1–4 天开工（每 13 条留一条只有截止），
///   完成行因此也带历史开始时间（验日历「开始」视图与时间轴 due ∪ start 并集）
/// - 每 13 条收藏、每 17 条进「我的一天」、每 19 条带重复规则
/// - 每 11 条未分组、每 50 条软删进回收站（2%）
/// - 每 4 条 2–3 个子任务、每 29 条 1 条提醒、每 23 条 1 条评论、
///   每 3 条挂 1–2 个标签、每 37 条 1 条任务关联
async fn insert_seed_rows(
    tx: &mut Transaction<'_, Sqlite>,
    task_count: i64,
    run: &str,
    now: i64,
    today0: i64,
) -> CoreResult<DevSeedCounts> {
    let mut counts = DevSeedCounts::default();
    let uuid_of = |kind: &str, n: i64| format!("{SEED_UUID_PREFIX}{run}-{kind}-{n:06}");

    // ── 项目（父清单 + 子清单 + 归档 + 回顾节奏）──
    let mut project_ids: Vec<i64> = Vec::with_capacity(PROJECTS.len());
    let mut project_uuids: Vec<String> = Vec::with_capacity(PROJECTS.len());
    for (i, project) in PROJECTS.iter().enumerate() {
        let uuid = uuid_of("proj", i as i64);
        let parent_uuid = project.parent.map(|idx| project_uuids[idx].clone());
        let review_last = project.review_days.map(|_| now - 10 * DAY_MS);
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_projects \
               (uuid, title, description, hex_color, sort_order, parent_uuid, \
                review_interval_days, review_last_at, is_archived, is_deleted, \
                created_at, updated_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(&uuid)
        .bind(format!("{SEED_TITLE_PREFIX}{}", project.title))
        .bind(format!(
            "{SEED_TITLE_PREFIX}项目说明：用于验证清单聚合、归档与回顾节奏。"
        ))
        .bind(project.color)
        .bind(i as f64)
        .bind(parent_uuid.as_deref())
        .bind(project.review_days)
        .bind(review_last)
        .bind(i32::from(project.archived))
        .bind(now)
        .bind(now)
        .fetch_one(&mut **tx)
        .await?;
        project_ids.push(id.0);
        project_uuids.push(uuid);
        counts.projects += 1;
    }

    // ── 标签 ──
    let mut label_ids: Vec<i64> = Vec::with_capacity(LABELS.len());
    for (i, (title, color)) in LABELS.iter().enumerate() {
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_labels (uuid, title, hex_color, is_deleted, created_at, updated_at, version) \
             VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(uuid_of("label", i as i64))
        .bind(format!("{SEED_TITLE_PREFIX}{title}"))
        .bind(*color)
        .bind(now)
        .bind(now)
        .fetch_one(&mut **tx)
        .await?;
        label_ids.push(id.0);
        counts.labels += 1;
    }

    // 归档项目不接新任务（归档语义 = 不再出现在默认列表）
    let live_projects: Vec<i64> = project_ids
        .iter()
        .enumerate()
        .filter(|(idx, _)| !PROJECTS[*idx].archived)
        .map(|(_, id)| *id)
        .collect();

    // ── 任务 + 子任务 / 提醒 / 评论 / 标签关联 / 任务关联 ──
    // 关联行只连「上一条存活任务」，故只留一个游标（不做无界累加容器）
    let mut prev_live_task: Option<i64> = None;
    // 完成时间按历史分布铺开（热力图按年切换要有往年数据）：先数出完成档总量，
    // 再让第 j 条完成落在 done_day_offset 给出的天偏移上
    let done_total = (0..task_count).filter(|i| i % 10 < 3).count() as i64;
    let mut done_index = 0i64;
    let history_salt = u64::from_str_radix(run, 16).unwrap_or(HISTORY_SALT);
    for i in 0..task_count {
        let head = TITLE_HEADS[(i as usize) % TITLE_HEADS.len()];
        let description = if i % 3 == 0 {
            Some(format!(
                "{SEED_TITLE_PREFIX}任务说明 #{i}：用于验证关键词搜索与列裁剪（标记 QP{i}）。"
            ))
        } else {
            None
        };

        // 每 11 条 1 条未分组；其余散到非归档项目。模数与完成/日期档互质，
        // 否则「未分组」会整段落在某个完成态上，分诊视图拿不到数据。
        let project_id = if i % 11 == 0 {
            None
        } else {
            Some(live_projects[((i % 7) as usize) % live_projects.len()])
        };

        let done = i % 10 < 3;
        // 完成时间：近 10 天每天一条保证连续天数/近 7 天有数，其余按
        // 「近密远疏」铺到 3 年前；今天算出的时刻若晚于当前时间就夹到「刚刚」
        let done_at = if done {
            let offset = done_day_offset(done_index, done_total, HISTORY_DAYS, history_salt);
            let h = hash64((done_index as u64) ^ history_salt);
            let at = today0 - offset * DAY_MS
                + (9 + (h % 10) as i64) * HOUR_MS
                + (((h >> 8) % 60) as i64) * 60_000;
            done_index += 1;
            Some(at.min(now - 60_000))
        } else {
            None
        };
        // 时间线自洽：created <= done <= updated（否则按创建时间排序会出现
        // 「三年前创建、今天才完成」这类不可能的极端值）
        let (created_at, updated_at) = if let Some(at) = done_at {
            (
                at - ((i % 20) + 1) * DAY_MS,
                (at + (i % 5) * HOUR_MS).min(now),
            )
        } else {
            let at = now - (i % 60) * 60_000;
            (at, at)
        };
        // 截止日期：完成行必须跟着 done_at 走，否则会出现「两年前完成、截止在下个月」
        let due_date = if let Some(at) = done_at {
            Some(if i % 9 == 0 {
                // 少数逾期后才完成（Logbook 里能看到逾期标记）
                at - ((i % 5) + 2) * DAY_MS
            } else {
                // 多数按时完成：截止就在完成当天（略早于完成时刻）
                at - (i % 3) * HOUR_MS
            })
        } else {
            // 与完成档（0..2）错开：3/4 才是「无截止」，否则无截止视图整段是已完成行
            match i % 10 {
                3 | 4 => None,
                5 | 6 => Some(today0 - ((i % 5) + 1) * DAY_MS),
                7 => Some(today0 + 10 * HOUR_MS),
                8 => Some(today0 + 3 * DAY_MS + 9 * HOUR_MS),
                _ => Some(today0 + ((i % 30) + 1) * DAY_MS),
            }
        };
        // 开始日期：日历「开始」视图与时间轴要铺得满，约八成任务带开始时间。
        // 有截止的提前 1–4 天开工（完成行因此也带历史开始时间），每 13 条留一条
        // 「只有截止」；无截止的只有 i%10==3 那档给开始时间，i%10==4 完全未排期
        // （验「无日期」入口）。
        let start_date = match due_date {
            Some(due) => {
                (i % 13 != 0).then(|| due - ((i % 4) + 1) * DAY_MS + (9 + (i % 6)) * HOUR_MS)
            }
            None => (i % 10 == 3).then(|| {
                if i % 2 == 0 {
                    today0 - ((i % 14) + 1) * DAY_MS + 10 * HOUR_MS
                } else {
                    today0 + ((i % 14) + 1) * DAY_MS + 10 * HOUR_MS
                }
            }),
        };

        let (repeat_after, repeat_mode, repeat_weekdays) = match i % 19 {
            0 => (1, 1, 0),         // 每天
            1 => (1, 2, 0b0111110), // 每周一~周五
            2 => (1, 3, 0),         // 每月
            _ => (0, 0, 0),
        };
        let status = if done {
            "done"
        } else if i % 8 == 0 {
            "doing"
        } else {
            "pending"
        };
        // 2% 软删：墓碑时间落在 7 天 TTL 内，避免被启动维护直接清掉
        let trashed = i > 0 && i % 50 == 0;

        let task_uuid = uuid_of("task", i);
        let task_id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks \
               (uuid, title, description, project_id, priority, status, done, done_at, \
                due_date, start_date, repeat_after, repeat_mode, repeat_weekdays, \
                percent_done, position, is_favorite, my_day_date, duration_minutes, \
                is_deleted, created_at, updated_at, deleted_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 0, ?, ?, NULL, 1) \
             RETURNING id",
        )
        .bind(&task_uuid)
        .bind(format!("{SEED_TITLE_PREFIX}{head} #{i:04}"))
        .bind(description.as_deref())
        .bind(project_id)
        .bind((i % 6) as i32)
        .bind(status)
        .bind(i32::from(done))
        .bind(done_at)
        .bind(due_date)
        .bind(start_date)
        .bind(repeat_after)
        .bind(repeat_mode)
        .bind(repeat_weekdays)
        .bind(i as f64)
        .bind(i32::from(i % 13 == 0))
        .bind((i % 17 == 0).then_some(today0))
        .bind((i % 6 == 0).then_some((i % 4 + 1) * 15))
        .bind(created_at)
        .bind(updated_at)
        .fetch_one(&mut **tx)
        .await?;
        let task_id = task_id.0;
        counts.tasks += 1;

        if trashed {
            // 先活行后墓碑：FTS 的 INSERT 触发器不看 is_deleted，UPDATE 触发器
            // 才会把软删行从索引摘掉（否则回收站任务会混进搜索结果）
            sqlx::query(
                "UPDATE todo_tasks SET is_deleted = 1, deleted_at = ?, updated_at = ?, \
                    version = version + 1 WHERE id = ?",
            )
            .bind(now - (i % 5) * DAY_MS)
            .bind(now - (i % 60) * 60_000)
            .bind(task_id)
            .execute(&mut **tx)
            .await?;
            continue; // 回收站任务不再挂子表（与业务删除后的残留语义无关）
        }

        // 子任务：每 4 条 2–3 个，首个子任务在 i%8==0 时已完成
        let mut subtask_total = 0i64;
        let mut subtask_done = 0i64;
        if i % 4 == 0 {
            let n = 2 + i % 2;
            for s in 0..n {
                let s_done = s == 0 && i % 8 == 0;
                sqlx::query(
                    "INSERT INTO todo_subtasks \
                       (uuid, task_id, title, done, done_at, position, is_deleted, \
                        created_at, updated_at, version) \
                     VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1)",
                )
                .bind(uuid_of("sub", i * 10 + s))
                .bind(task_id)
                .bind(format!("{SEED_TITLE_PREFIX}子步骤 {s}：{head}"))
                .bind(i32::from(s_done))
                .bind(s_done.then_some(now))
                .bind(s as f64)
                .bind(now)
                .bind(now)
                .execute(&mut **tx)
                .await?;
                counts.subtasks += 1;
                subtask_total += 1;
                if s_done {
                    subtask_done += 1;
                }
            }
            // 子任务勾选驱动父任务进度（业务侧由后端回算，这里保持一致）
            sqlx::query("UPDATE todo_tasks SET percent_done = ? WHERE id = ?")
                .bind(subtask_done as f64 * 100.0 / subtask_total as f64)
                .bind(task_id)
                .execute(&mut **tx)
                .await?;
        }

        // 提醒：每 29 条 1 条（落在未来 1–3 天，避免开发时被通知轰炸）
        if i % 29 == 0 {
            sqlx::query(
                "INSERT INTO todo_reminders (uuid, task_id, remind_at, is_deleted, created_at, updated_at, version) \
                 VALUES (?, ?, ?, 0, ?, ?, 1)",
            )
            .bind(uuid_of("rem", i))
            .bind(task_id)
            .bind(now + ((i % 3) + 1) * DAY_MS)
            .bind(now)
            .bind(now)
            .execute(&mut **tx)
            .await?;
            counts.reminders += 1;
        }

        // 评论：每 23 条 1 条
        if i % 23 == 0 {
            sqlx::query(
                "INSERT INTO todo_comments (uuid, task_id, content, is_deleted, created_at, updated_at, version) \
                 VALUES (?, ?, ?, 0, ?, ?, 1)",
            )
            .bind(uuid_of("cmt", i))
            .bind(task_id)
            .bind(format!(
                "{SEED_TITLE_PREFIX}{}",
                COMMENT_BODIES[(i as usize / 23) % COMMENT_BODIES.len()]
            ))
            .bind(now)
            .bind(now)
            .execute(&mut **tx)
            .await?;
            counts.comments += 1;
        }

        // 标签：每 3 条挂 1–2 个
        if i % 3 == 0 {
            for t in 0..(1 + i % 2) {
                let label_id = label_ids[((i + t) as usize) % label_ids.len()];
                sqlx::query(
                    "INSERT INTO todo_task_labels (uuid, task_id, label_id, is_deleted, created_at, updated_at, version) \
                     VALUES (?, ?, ?, 0, ?, ?, 1)",
                )
                .bind(uuid_of("tl", i * 10 + t))
                .bind(task_id)
                .bind(label_id)
                .bind(now)
                .bind(now)
                .execute(&mut **tx)
                .await?;
                counts.task_labels += 1;
            }
        }

        // 任务关联：每 37 条 1 条（列表行「有关联」徽标数据源）
        if i % 37 == 0
            && let Some(prev) = prev_live_task
        {
            sqlx::query(
                "INSERT INTO todo_task_relations \
                   (uuid, task_id, other_task_id, relation_type, is_deleted, created_at, updated_at, version) \
                 VALUES (?, ?, ?, 'relates_to', 0, ?, ?, 1)",
            )
            .bind(uuid_of("rel", i))
            .bind(task_id)
            .bind(prev)
            .bind(now)
            .bind(now)
            .execute(&mut **tx)
            .await?;
            counts.task_relations += 1;
        }

        prev_live_task = Some(task_id);
    }

    Ok(counts)
}

/// 历史跨度：3 年（覆盖 4 个自然年，够热力图按年切换）
const HISTORY_DAYS: i64 = 365 * 3 + 1;

/// 完成时间分布的散列盐（uuid 前缀解析失败时的回退值）
const HISTORY_SALT: u64 = 0x5EED_0B17;

/// 第 j 条完成记录距今多少天（0 = 今天，越大越早）。
///
/// 为什么不是全随机：统计页的「近 7 天 / 近 30 天」、连续完成天数与热力图是
/// 三种不同粒度的读数，任何一档断粮都会让对应卡片看着像坏了。这里按
/// 「近处密、远处疏」分四段：
/// - 前 10 条固定为最近 10 天各一条（连续天数与近 7 天必有数）；
/// - 前 18% 落在近两周；
/// - 18%–32% 落在 15–30 天（近 30 天卡片有数）；
/// - 32%–55% 落在 1–6 个月；
/// - 其余铺满 [`HISTORY_DAYS`]（往年热力图与年份切换有内容）。
///
/// 段内用 splitmix64 打散，避免「同一段每天条数完全相同」的机械感。
fn done_day_offset(j: i64, total: i64, history_days: i64, salt: u64) -> i64 {
    if j < 10 {
        return 9 - j;
    }
    let t = (j as f64 + 0.5) / total.max(1) as f64;
    let h = hash64((j as u64) ^ salt);
    let span = |n: i64| (h % n.max(1) as u64) as i64;
    if t < 0.18 {
        span(14)
    } else if t < 0.32 {
        14 + span(17)
    } else if t < 0.55 {
        31 + span(150)
    } else {
        181 + span(history_days - 181)
    }
}

/// splitmix64：确定性散列（同输入同输出，便于按 run 盐复现分布）
fn hash64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// 本地时区的今天零点（毫秒）：列表的「今天」、日历与统计都按本地日界分桶
fn local_today_start() -> i64 {
    let today = chrono::Local::now().date_naive();
    chrono::Local
        .from_local_datetime(&today.and_hms_opt(0, 0, 0).unwrap_or_default())
        .single()
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(clock::next_ms)
}

/// 批量写后按表补发一条 db-change：前端按表精确失效，一次刷新收敛。
///
/// `record_id` 恒 0、`record_uuid` 空串——批量变更没有单行语义，消费侧只用表名。
fn emit_tables(tables: &[&str], op: DbOp) {
    let device_id = crate::context::get_device_id()
        .unwrap_or_default()
        .to_string();
    let timestamp = clock::next_ms();
    for table in tables {
        EVENT_BUS.emit(DbEvent {
            table: (*table).to_string(),
            op,
            record_id: 0,
            record_uuid: String::new(),
            payload: None,
            device_id: device_id.clone(),
            timestamp,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup() -> SqlitePool {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn count(pool: &SqlitePool, table: &str) -> i64 {
        let sql = format!("SELECT COUNT(*) FROM {table}");
        let (n,): (i64,) = sqlx::query_as(&sql).fetch_one(pool).await.unwrap();
        n
    }

    async fn count_seeded(pool: &SqlitePool, table: &str) -> i64 {
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE uuid LIKE ?");
        let (n,): (i64,) = sqlx::query_as(&sql)
            .bind(format!("{SEED_UUID_PREFIX}%"))
            .fetch_one(pool)
            .await
            .unwrap();
        n
    }

    #[test]
    fn done_offsets_cover_recent_and_history() {
        let total = 1_000i64;
        let offsets: Vec<i64> = (0..total)
            .map(|j| done_day_offset(j, total, HISTORY_DAYS, HISTORY_SALT))
            .collect();

        // 前 10 条覆盖最近 10 天且不重复（连续天数与近 7 天卡片必有数）
        assert_eq!(offsets[0], 9);
        assert_eq!(offsets[9], 0);
        let head: std::collections::BTreeSet<i64> = offsets[..10].iter().copied().collect();
        assert_eq!(head.len(), 10);

        // 全部落在历史窗口内，且至少 30% 在一年以前（往年热力图不是空白）
        assert!(offsets.iter().all(|d| (0..=HISTORY_DAYS).contains(d)));
        let old = offsets.iter().filter(|d| **d > 365).count();
        assert!(
            old * 10 >= total as usize * 3,
            "往年占比过低：{old}/{total}"
        );

        // 确定性：同参数同结果（分布由 run 盐决定，重跑可复现）
        assert_eq!(
            done_day_offset(42, total, HISTORY_DAYS, HISTORY_SALT),
            offsets[42]
        );
    }

    #[tokio::test]
    async fn seed_writes_every_entity_and_is_idempotent() {
        let pool = setup().await;

        let first = seed_demo_data(&pool, &DevSeedPlan { tasks: 120 })
            .await
            .unwrap();
        assert_eq!(first.created.projects, PROJECTS.len() as i64);
        assert_eq!(first.created.labels, LABELS.len() as i64);
        assert_eq!(first.created.tasks, 120);
        assert!(first.created.subtasks > 0);
        assert!(first.created.reminders > 0);
        assert!(first.created.comments > 0);
        assert!(first.created.task_labels > 0);
        assert!(first.created.task_relations > 0);
        assert_eq!(first.cleared.total(), 0);

        // 再次生成：先清上一批，不叠数据
        let second = seed_demo_data(&pool, &DevSeedPlan { tasks: 60 })
            .await
            .unwrap();
        assert_eq!(second.cleared.tasks, 120);
        assert_eq!(second.created.tasks, 60);
        assert_eq!(count_seeded(&pool, "todo_tasks").await, 60);
        assert_eq!(
            count_seeded(&pool, "todo_projects").await,
            PROJECTS.len() as i64
        );
    }

    #[tokio::test]
    async fn seed_rows_carry_marker_prefix() {
        let pool = setup().await;
        seed_demo_data(&pool, &DevSeedPlan { tasks: 40 })
            .await
            .unwrap();

        let (bad,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid NOT LIKE ? OR title NOT LIKE ?",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .bind(format!("{SEED_TITLE_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(bad, 0, "示例任务必须同时带 uuid 与标题前缀");
    }

    #[tokio::test]
    async fn seed_shape_covers_all_read_paths() {
        let pool = setup().await;
        seed_demo_data(&pool, &DevSeedPlan { tasks: 600 })
            .await
            .unwrap();

        // 完成 / 逾期 / 无日期 / 回收站四档都要有数据
        let (done,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 0 AND done = 1",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        let (overdue,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 0 \
                AND done = 0 AND due_date < ?",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .bind(local_today_start())
        .fetch_one(&pool)
        .await
        .unwrap();
        let (undated,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 0 \
                AND due_date IS NULL",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        let (trashed,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 1")
                .bind(format!("{SEED_UUID_PREFIX}%"))
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(done > 0 && overdue > 0 && undated > 0 && trashed > 0);

        // 开始日期要铺得满（日历「开始」视图 / 时间轴），且不晚于截止；
        // 仍要保留完全未排期的一档（无截止也无开始）
        let (with_start,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 0 \
                AND start_date IS NOT NULL",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(with_start * 2 >= 600, "开始日期覆盖过少：{with_start}/600");

        let (bad_start,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND due_date IS NOT NULL \
                AND start_date IS NOT NULL AND start_date > due_date",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(bad_start, 0, "开始日期晚于截止日期");

        let (unscheduled,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND is_deleted = 0 \
                AND due_date IS NULL AND start_date IS NULL",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(unscheduled > 0, "缺少完全未排期的示例行");

        // 完成时间要跨年：近 7 天有数（连续天数/近 7 天卡片），且存在两年前
        // 的完成记录（热力图按年切换）
        let (last_week,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND done = 1 \
                AND done_at >= ?",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .bind(local_today_start() - 6 * DAY_MS)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(last_week >= 7, "近 7 天完成数过少：{last_week}");

        let (past_years,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND done = 1 \
                AND done_at < ?",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .bind(local_today_start() - 730 * DAY_MS)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(
            past_years > 0,
            "缺少两年前的完成记录（热力图年份切换无数据）"
        );

        // 时间线自洽：创建早于完成、更新时间不早于完成时间
        let (bad_timeline,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM todo_tasks WHERE uuid LIKE ? AND done = 1 \
                AND (created_at > done_at OR updated_at < done_at)",
        )
        .bind(format!("{SEED_UUID_PREFIX}%"))
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(bad_timeline, 0);

        // 软删行不得残留在全文索引（INSERT 触发器不看 is_deleted）
        let (leaked,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM fts_todo WHERE kind = 'task' AND ref_id IN \
                (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(leaked, 0);
    }

    #[tokio::test]
    async fn clear_only_removes_seed_rows() {
        let pool = setup().await;
        // 手工数据（uuid 无前缀）在清理中必须原样保留
        let now = clock::next_ms();
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, is_deleted, created_at, updated_at, version) \
             VALUES ('manual-task-1', '手工任务', 0, ?, ?, 1)",
        )
        .bind(now)
        .bind(now)
        .execute(&pool)
        .await
        .unwrap();

        seed_demo_data(&pool, &DevSeedPlan { tasks: 80 })
            .await
            .unwrap();
        let cleared = clear_demo_data(&pool).await.unwrap();
        assert_eq!(cleared.removed.tasks, 80);
        assert_eq!(count_seeded(&pool, "todo_tasks").await, 0);
        assert_eq!(count_seeded(&pool, "todo_projects").await, 0);
        assert_eq!(count(&pool, "todo_tasks").await, 1);
        let (title,): (String,) = sqlx::query_as("SELECT title FROM todo_tasks")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(title, "手工任务");
    }
}
