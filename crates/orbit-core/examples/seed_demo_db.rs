//! seed_demo_db — 生成「结构完整」的明文演示库，供真机/桌面功能验收使用
//! （与 `pragma_eval` / `operation_probe` 同惯例：本地手动跑的探针，不是产品代码）。
//!
//! 为什么需要它：真机上手工点几十条任务只够看首屏，翻页续拉（页长 200）、
//! 看板列总数、日历范围查询、统计聚合、筛选器全部测不到边界。这里直写
//! `todo_tasks` 等表（**不经过业务 API**，事务批量，几千行秒级），FTS 索引
//! 由 `0001_init.sql` 的触发器自动维护；拼音索引留给查询入口的 reconcile
//! （`search_pinyin_state.dirty=1` 种子行，首查自动补）。
//!
//! 数据分布（默认 3000 行，可用 `--rows` 覆盖）刻意覆盖每条读通道：
//! - 30% 已完成（done_at 落在过去 30 天，验 Logbook / done_at 排序档）
//! - 20% 无截止（验「未排期」/无日期视图）
//! - 20% 逾期 / 20% 今天到期 / 其余散在未来 30 天（验逾期置顶段、近7天）
//! - 每 7 条带 start_date（验日历时间轴 due ∪ start 两路并集）
//! - 每 11 条收藏、每 13 条进「我的一天」、每 17 条带重复规则、每 6 条有时长
//! - 每 10 条 1 条未分组；2% 软删（验回收站）
//! - 每 4 条 2–3 个子任务、每 9 条 1 条提醒、每 20 条 1 条评论、每 3 条挂 1–2 个标签
//!
//! 项目树刻意做成「父清单 + 子清单」，验清单聚合（父视图含后代项目任务）。
//! 迁移基线取仓库最新（`init_pool_unencrypted` 自动 `migrate!`），与真机同版本。
//!
//! 用法：
//! ```text
//! cargo run --release -p orbit-core --example seed_demo_db -- \
//!   --out target/seed/orbit.db --rows 3000
//! ```
//!
//! 真机替换流程（**先备份原库**）：
//! ```text
//! adb shell am force-stop cn.wait.orbit
//! adb pull /data/data/cn.wait.orbit/files/orbit.db  backup.db
//! adb push target/seed/orbit.db /data/local/tmp/orbit.db
//! adb shell run-as cn.wait.orbit cp /data/local/tmp/orbit.db files/orbit.db
//! adb shell run-as cn.wait.orbit rm -f files/orbit.db-wal files/orbit.db-shm
//! adb shell am start -n cn.wait.orbit/.MainActivity
//! ```

use std::path::PathBuf;

use chrono::{Local, TimeZone};
use orbit_core::db::pool::init_pool_unencrypted;
use sqlx::Connection;

struct Args {
    out: PathBuf,
    rows: usize,
}

fn parse_args() -> Result<Args, String> {
    let mut map = std::collections::HashMap::new();
    let mut iter = std::env::args().skip(1);
    while let Some(key) = iter.next() {
        if !key.starts_with("--") {
            return Err(format!("无法识别的参数：{key}"));
        }
        let value = iter.next().ok_or_else(|| format!("{key} 缺少取值"))?;
        map.insert(key.trim_start_matches("--").to_string(), value);
    }
    let get = |k: &str, default: &str| map.get(k).cloned().unwrap_or_else(|| default.into());
    Ok(Args {
        out: PathBuf::from(get("out", "target/seed/orbit.db")),
        rows: get("rows", "3000")
            .parse()
            .map_err(|e| format!("rows: {e}"))?,
    })
}

/// 项目清单：`(标题, 颜色, 父项目序号, 是否归档)`
const PROJECTS: &[(&str, &str, Option<usize>, bool)] = &[
    ("工作", "#3B82F6", None, false),
    ("研发", "#6366F1", Some(0), false),
    ("运营", "#8B5CF6", Some(0), false),
    ("生活", "#10B981", None, false),
    ("家务", "#14B8A6", Some(3), false),
    ("学习", "#F59E0B", None, false),
    ("健康", "#EF4444", None, false),
    ("旧项目（归档）", "#6B7280", None, true),
];

const LABELS: &[(&str, &str)] = &[
    ("紧急", "#EF4444"),
    ("重要", "#F97316"),
    ("等待中", "#A855F7"),
    ("家庭", "#10B981"),
    ("工作", "#3B82F6"),
    ("学习", "#F59E0B"),
];

/// 标题词库：中文便于验证 FTS trigram 与拼音（用拼音首字母搜得到）
const TITLE_HEADS: &[&str] = &[
    "整理季度报告", "准备周会材料", "复盘上周迭代", "采购办公用品", "读书笔记",
    "晨跑五公里", "缴纳水电费", "整理发票报销", "给家里打电话", "更新简历",
    "梳理需求池", "检查备份任务", "修复线上告警", "编写发布说明", "整理测试用例",
    "预约体检", "练习英语听力", "清理下载目录", "规划下季度目标", "跟进客户反馈",
];

const COMMENT_BODIES: &[&str] = &[
    "已和相关同事对齐，等对方补充数据",
    "这里需要再确认一次口径",
    "先按当前方案推进，下周复盘",
    "附：原始文件已放到共享目录",
];

#[tokio::main]
async fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("参数错误：{e}");
            std::process::exit(2);
        }
    };
    if let Err(e) = run(&args).await {
        eprintln!("生成失败：{e}");
        std::process::exit(1);
    }
}

async fn run(args: &Args) -> Result<(), String> {
    if let Some(dir) = args.out.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    // 每次重建：旧 WAL/SHM 一起清，否则新库会叠在旧日志上
    for suffix in ["", "-wal", "-shm"] {
        let p = PathBuf::from(format!("{}{suffix}", args.out.display()));
        let _ = std::fs::remove_file(p);
    }

    let pool = init_pool_unencrypted(&args.out)
        .await
        .map_err(|e| e.to_string())?;
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;
    let mut tx = conn.begin().await.map_err(|e| e.to_string())?;

    let now = Local::now();
    let now_ms = now.timestamp_millis();
    let today0 = Local
        .from_local_datetime(&now.date_naive().and_hms_opt(0, 0, 0).unwrap())
        .unwrap()
        .timestamp_millis();
    let day = 86_400_000i64;

    // ── 项目（父清单 + 子清单 + 归档）──
    let mut project_ids: Vec<i64> = Vec::with_capacity(PROJECTS.len());
    let mut project_uuids: Vec<String> = Vec::with_capacity(PROJECTS.len());
    for (i, (title, color, parent, archived)) in PROJECTS.iter().enumerate() {
        let uuid = format!("seed-proj-{i:03}");
        let parent_uuid = parent.map(|p| project_uuids[p].as_str());
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_projects \
               (uuid, title, hex_color, sort_order, parent_uuid, is_archived, is_deleted, \
                created_at, updated_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(&uuid)
        .bind(*title)
        .bind(*color)
        .bind(i as f64)
        .bind(parent_uuid)
        .bind(i32::from(*archived))
        .bind(now_ms)
        .bind(now_ms)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| format!("项目 {title}: {e}"))?;
        project_ids.push(id.0);
        project_uuids.push(uuid);
    }

    // ── 标签 ──
    let mut label_ids: Vec<i64> = Vec::with_capacity(LABELS.len());
    for (i, (title, color)) in LABELS.iter().enumerate() {
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_labels (uuid, title, hex_color, is_deleted, created_at, updated_at, version) \
             VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(format!("seed-label-{i:03}"))
        .bind(*title)
        .bind(*color)
        .bind(now_ms)
        .bind(now_ms)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| format!("标签 {title}: {e}"))?;
        label_ids.push(id.0);
    }

    // ── 任务 + 子任务 / 提醒 / 评论 / 标签关联 / 回收站 ──
    let mut counters = Counters::default();
    for i in 0..args.rows {
        let head = TITLE_HEADS[i % TITLE_HEADS.len()];
        let title = format!("{head} #{i:04}");
        let description = if i % 3 == 0 {
            Some(format!(
                "自动生成的任务描述 #{i}：用于验证列裁剪与关键词搜索（含唯一标记 QP{i}）。"
            ))
        } else {
            None
        };

        // 每 11 条 1 条未分组；其余按「二阶取模」散到非归档项目。
        // 模数与 done(10)/due(10) 刻意互质：否则「未分组」会整段落在某个完成态上，
        // 未分组视图/分诊拿不到数据（首版种子就踩了这个坑）。
        let project_id = if i % 11 == 0 {
            None
        } else {
            let live: Vec<i64> = project_ids
                .iter()
                .enumerate()
                .filter(|(idx, _)| !PROJECTS[*idx].3)
                .map(|(_, id)| *id)
                .collect();
            Some(live[(i % 7) % live.len()])
        };

        let done = i % 10 < 3;
        let done_at = if done {
            Some(now_ms - (i as i64 % 30) * day - 3_600_000)
        } else {
            None
        };
        // 与 done 档（0..2 = 已完成）错开：3/4 才是「无日期」，否则未分组/无日期
        // 视图会整段落在已完成行上（首版种子的坑）
        let (due_date, start_date) = match i % 10 {
            3 | 4 => (None, None),                                        // 无日期（未完成）
            5 | 6 => (Some(today0 - ((i as i64 % 5) + 1) * day), None),   // 逾期 1–5 天
            7 => (Some(today0 + 10 * 3_600_000), None),                   // 今天到期
            8 => (Some(today0 + 3 * day + 9 * 3_600_000), None),          // 近 7 天
            _ => (Some(today0 + ((i as i64 % 30) + 1) * day), None),      // 未来 1–30 天
        };
        // 每 7 条给 start_date（日历时间轴），与 due 错开形成跨天块
        let start_date = if i % 7 == 0 {
            Some(today0 + ((i as i64 % 14) - 3) * day + 14 * 3_600_000)
        } else {
            start_date
        };

        let (repeat_after, repeat_mode, repeat_weekdays) = match i % 17 {
            0 => (1, 1, 0),      // 每天
            1 => (1, 2, 0b0111110), // 每周一~周五
            2 => (1, 3, 0),      // 每月
            _ => (0, 0, 0),
        };
        let priority = (i % 6) as i32;
        let is_favorite = i32::from(i % 11 == 0);
        let my_day_date = if i % 13 == 0 { Some(today0) } else { None };
        let duration_minutes = if i % 6 == 0 {
            Some(((i % 4 + 1) * 15) as i64)
        } else {
            None
        };
        let status = if done {
            "done"
        } else if i % 8 == 0 {
            "doing"
        } else {
            "pending"
        };
        // 2% 软删（回收站）；墓碑时间在 7 天 TTL 内，避免被启动维护直接清掉
        let trashed = i % 50 == 0 && i > 0;
        let is_deleted = i32::from(trashed);
        let deleted_at = if trashed {
            Some(now_ms - (i as i64 % 5) * day)
        } else {
            None
        };

        let task_uuid = format!("seed-task-{i:05}");
        let task_id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, description, project_id, priority, status, done, done_at, \
                due_date, start_date, repeat_after, repeat_mode, repeat_weekdays, percent_done, position, \
                is_favorite, my_day_date, duration_minutes, is_deleted, created_at, updated_at, deleted_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 1) RETURNING id",
        )
        .bind(&task_uuid)
        .bind(&title)
        .bind(description.as_deref())
        .bind(project_id)
        .bind(priority)
        .bind(status)
        .bind(i32::from(done))
        .bind(done_at)
        .bind(due_date)
        .bind(start_date)
        .bind(repeat_after)
        .bind(repeat_mode)
        .bind(repeat_weekdays)
        .bind(i as f64)
        .bind(is_favorite)
        .bind(my_day_date)
        .bind(duration_minutes)
        .bind(is_deleted)
        .bind(now_ms - (i as i64 % 60) * 60_000)
        .bind(now_ms - (i as i64 % 60) * 60_000)
        .bind(deleted_at)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| format!("任务 {i}: {e}"))?;
        let task_id = task_id.0;
        counters.tasks += 1;
        if trashed {
            counters.trashed += 1;
            continue; // 回收站任务不再挂子任务/标签（与业务删除前的残留语义不同，简化）
        }

        // 子任务：每 4 条 2–3 个，部分完成
        if i % 4 == 0 {
            for s in 0..(2 + i % 2) {
                let s_done = s == 0 && i % 8 == 0;
                sqlx::query(
                    "INSERT INTO todo_subtasks (uuid, task_id, title, done, done_at, position, is_deleted, \
                        created_at, updated_at, version) \
                     VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1)",
                )
                .bind(format!("seed-sub-{i:05}-{s}"))
                .bind(task_id)
                .bind(format!("子步骤 {s}：{head}"))
                .bind(i32::from(s_done))
                .bind(if s_done { Some(now_ms) } else { None })
                .bind(s as f64)
                .bind(now_ms)
                .bind(now_ms)
                .execute(&mut *tx)
                .await
                .map_err(|e| format!("子任务 {i}/{s}: {e}"))?;
                counters.subtasks += 1;
            }
        }

        // 提醒：每 9 条 1 条（未来 1–3 天，避免落进已过期窗口）
        if i % 9 == 0 {
            sqlx::query(
                "INSERT INTO todo_reminders (uuid, task_id, remind_at, is_deleted, created_at, updated_at, version) \
                 VALUES (?, ?, ?, 0, ?, ?, 1)",
            )
            .bind(format!("seed-rem-{i:05}"))
            .bind(task_id)
            .bind(now_ms + ((i as i64 % 3) + 1) * day)
            .bind(now_ms)
            .bind(now_ms)
            .execute(&mut *tx)
            .await
            .map_err(|e| format!("提醒 {i}: {e}"))?;
            counters.reminders += 1;
        }

        // 评论：每 20 条 1 条
        if i % 20 == 0 {
            sqlx::query(
                "INSERT INTO todo_comments (uuid, task_id, content, is_deleted, created_at, updated_at, version) \
                 VALUES (?, ?, ?, 0, ?, ?, 1)",
            )
            .bind(format!("seed-cmt-{i:05}"))
            .bind(task_id)
            .bind(COMMENT_BODIES[(i / 20) % COMMENT_BODIES.len()])
            .bind(now_ms)
            .bind(now_ms)
            .execute(&mut *tx)
            .await
            .map_err(|e| format!("评论 {i}: {e}"))?;
            counters.comments += 1;
        }

        // 标签：每 3 条挂 1–2 个
        if i % 3 == 0 {
            let n = 1 + i % 2;
            for t in 0..n {
                let label_id = label_ids[(i + t) % label_ids.len()];
                sqlx::query(
                    "INSERT INTO todo_task_labels (uuid, task_id, label_id, is_deleted, created_at, updated_at, version) \
                     VALUES (?, ?, ?, 0, ?, ?, 1)",
                )
                .bind(format!("seed-tl-{i:05}-{t}"))
                .bind(task_id)
                .bind(label_id)
                .bind(now_ms)
                .bind(now_ms)
                .execute(&mut *tx)
                .await
                .map_err(|e| format!("标签关联 {i}/{t}: {e}"))?;
                counters.task_labels += 1;
            }
        }
    }

    tx.commit().await.map_err(|e| e.to_string())?;
    drop(conn);
    // WAL 收回到主文件：push 到设备时只需传一个 .db
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(&pool)
        .await
        .map_err(|e| e.to_string())?;
    pool.close().await;

    let bytes = std::fs::metadata(&args.out).map(|m| m.len()).unwrap_or(0);
    println!(
        "SEED_OK out={} bytes={} tasks={} subtasks={} reminders={} comments={} task_labels={} trashed={}",
        args.out.display(),
        bytes,
        counters.tasks,
        counters.subtasks,
        counters.reminders,
        counters.comments,
        counters.task_labels,
        counters.trashed
    );
    Ok(())
}

#[derive(Default)]
struct Counters {
    tasks: usize,
    subtasks: usize,
    reminders: usize,
    comments: usize,
    task_labels: usize,
    trashed: usize,
}

