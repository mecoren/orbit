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
//! - 每 11 条收藏、每 13 条进「我的一天」、每 6 条有时长
//! - 每 10 条 1 条未分组；2% 软删（验回收站）
//! - 每 4 条 2–3 个子任务、每 9 条 1 条提醒、每 20 条 1 条评论、每 3 条挂 1–2 个标签
//!
//! ## 同步端到端测试档（`docs/17_同步端到端测试手册.md`）
//!
//! `--projects` / `--history` / `--labels` / `--attachments` 四项把种子从
//! 「几千行看首屏」扩到「跨年 + 多表 + 附件」的同步压测画像：
//! - `--projects N`：0 号为历史项目（日期落在 `--history` 区间），1..N-2 为
//!   近期项目，N-1 为归档项目（N≥4）；前 6 个保留原「父清单 + 子清单」结构
//! - `--history A:B`：历史项目日期区间（默认 `1999:2018`），覆盖统计按年聚合、
//!   墓碑按月分桶、日历跨年范围
//! - `--labels N`：标签数（默认 6），多于 6 时自动补「标签 NN」
//! - `--attachments N`：附件数（默认 0），其中 `--big-attachments M` 个为
//!   8.5MiB（≥8MiB 走 WebDAV 分片通道 `assets_parts/{hash}/`）
//!
//! 附件二进制写入 `--attachments-out`（默认输出库同级的 `attachments/`），
//! 库内 `sys_attachments.local_path` 写 NULL——push 到真机后由引擎回落到
//! `{app_data_dir}/attachments/{hash}`，因此**目录要一起推**（见下方流程）。
//!
//! 项目树刻意做成「父清单 + 子清单」，验清单聚合（父视图含后代项目任务）。
//! 迁移基线取仓库最新（`init_pool_unencrypted` 自动 `migrate!`），与真机同版本。
//!
//! 用法：
//! ```text
//! # 看首屏（默认档）
//! cargo run --release -p orbit-core --example seed_demo_db -- \
//!   --out target/seed/orbit.db --rows 3000
//!
//! # 同步端到端测试档：8 项目 / 4 万主任务 / 历史 1999–2018 / 300 附件
//! cargo run --release -p orbit-core --example seed_demo_db -- \
//!   --out target/seed/orbit.db --rows 40000 --projects 8 \
//!   --history 1999:2018 --labels 40 --attachments 300 --big-attachments 2
//! ```
//!
//! 真机替换流程（**先备份原库**；<serial> 形如 `127.0.0.1:16384`）：
//! ```text
//! adb -s <serial> shell am force-stop cn.wait.orbit
//! adb -s <serial> pull /data/data/cn.wait.orbit/files/orbit.db  backup.db
//! adb -s <serial> push target/seed/orbit.db /data/local/tmp/orbit.db
//! adb -s <serial> shell run-as cn.wait.orbit cp /data/local/tmp/orbit.db files/orbit.db
//! adb -s <serial> shell run-as cn.wait.orbit rm -f files/orbit.db-wal files/orbit.db-shm
//! # 有附件时（--attachments > 0）：目录一起推，否则 push 侧读不到明文文件
//! adb -s <serial> shell rm -rf /data/local/tmp/attachments
//! adb -s <serial> push target/seed/attachments /data/local/tmp/attachments
//! adb -s <serial> shell run-as cn.wait.orbit rm -rf files/attachments
//! adb -s <serial> shell run-as cn.wait.orbit cp -r /data/local/tmp/attachments files/attachments
//! adb -s <serial> shell am start -n cn.wait.orbit/.MainActivity
//! ```
//!
//! 注意：真机若启用了主密码，库是 SQLCipher 加密的，本工具产出的明文库
//! 不能直接替换；改用应用内 `.orfullsync` 导入，或临时关闭主密码后恢复。

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::{Local, TimeZone};
use orbit_core::crypto::sha256::sha256_hex;
use orbit_core::db::pool::init_pool_unencrypted;
use sqlx::Connection;

struct Args {
    out: PathBuf,
    /// 主任务总数（子任务/评论/标签关联按比例派生）
    rows: usize,
    /// 项目数（0 号历史、末位归档）
    projects: usize,
    /// 历史项目日期区间 `YYYY:YYYY`
    history: (i32, i32),
    /// 标签数
    labels: usize,
    /// 附件数
    attachments: usize,
    /// 其中 ≥8MiB 的大附件数（触发 WebDAV 分片）
    big_attachments: usize,
    /// 附件二进制输出目录
    attachments_out: PathBuf,
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
    let num = |k: &str, default: &str| -> Result<usize, String> {
        get(k, default).parse().map_err(|e| format!("{k}: {e}"))
    };
    let history = parse_history(&get("history", "1999:2018"))?;
    if history.0 > history.1 {
        return Err(format!(
            "--history 起始年不得晚于结束年：{}>{}",
            history.0, history.1
        ));
    }
    let out = PathBuf::from(get("out", "target/seed/orbit.db"));
    // 附件目录默认与库同级，便于整目录 adb push
    let default_attachments_out = out
        .parent()
        .map(|d| d.join("attachments"))
        .unwrap_or_else(|| PathBuf::from("attachments"));
    let attachments_out = map
        .get("attachments-out")
        .map(PathBuf::from)
        .unwrap_or(default_attachments_out);
    Ok(Args {
        out,
        rows: num("rows", "3000")?,
        projects: num("projects", "8")?,
        history,
        labels: num("labels", "6")?,
        attachments: num("attachments", "0")?,
        big_attachments: num("big-attachments", "0")?,
        attachments_out,
    })
}

/// 解析 `YYYY:YYYY`；年份限定 1970–2100，避免 chrono 构造 panic。
fn parse_history(s: &str) -> Result<(i32, i32), String> {
    let (a, b) = s
        .split_once(':')
        .ok_or_else(|| format!("--history 需要 YYYY:YYYY，收到 {s}"))?;
    let parse = |v: &str| -> Result<i32, String> {
        let y: i32 = v
            .trim()
            .parse()
            .map_err(|e| format!("--history {v}: {e}"))?;
        if !(1970..=2100).contains(&y) {
            return Err(format!("--history 年份需在 1970–2100，收到 {y}"));
        }
        Ok(y)
    };
    Ok((parse(a)?, parse(b)?))
}

struct ProjectDef {
    title: String,
    color: &'static str,
    /// 父项目在当前 Vec 中的下标（parent_uuid 由插入顺序解析）
    parent: Option<usize>,
    archived: bool,
}

const PROJECT_COLORS: &[&str] = &[
    "#3B82F6", "#6366F1", "#8B5CF6", "#10B981", "#14B8A6", "#F59E0B", "#EF4444", "#EC4899",
];

/// 按 `--projects N` 生成项目布局：
/// - 0 号 = 历史项目（任务日期落在 `--history` 区间）
/// - 1..N-2 = 近期项目（前 5 个保留原「父清单 + 子清单」结构）
/// - N-1 = 归档项目（N≥4；归档项目不承接新任务，验「归档不进列表」）
fn build_projects(n: usize, hist_from: i32, hist_to: i32) -> Vec<ProjectDef> {
    let n = n.max(2);
    let mut v: Vec<ProjectDef> = Vec::with_capacity(n);
    v.push(ProjectDef {
        title: format!("历史项目 {hist_from}–{hist_to}"),
        color: "#6B7280",
        parent: None,
        archived: false,
    });
    let fixed: [(&str, &str, Option<usize>); 5] = [
        ("工作", "#3B82F6", None),
        ("研发", "#6366F1", Some(1)),
        ("运营", "#8B5CF6", Some(1)),
        ("生活", "#10B981", None),
        ("家务", "#14B8A6", Some(4)),
    ];
    for (title, color, parent) in fixed {
        // 至少给归档位留一格
        if v.len() + 1 >= n {
            break;
        }
        v.push(ProjectDef {
            title: title.into(),
            color,
            parent,
            archived: false,
        });
    }
    let archived_at = (n >= 4).then_some(n - 1);
    while v.len() < n {
        if Some(v.len()) == archived_at {
            v.push(ProjectDef {
                title: "旧项目（归档）".into(),
                color: "#6B7280",
                parent: None,
                archived: true,
            });
        } else {
            let idx = v.len();
            v.push(ProjectDef {
                title: format!("项目 {:02}", idx + 1),
                color: PROJECT_COLORS[idx % PROJECT_COLORS.len()],
                parent: None,
                archived: false,
            });
        }
    }
    v
}

const LABEL_PRESETS: &[(&str, &str)] = &[
    ("紧急", "#EF4444"),
    ("重要", "#F97316"),
    ("等待中", "#A855F7"),
    ("家庭", "#10B981"),
    ("工作", "#3B82F6"),
    ("学习", "#F59E0B"),
];

fn build_labels(n: usize) -> Vec<(String, &'static str)> {
    let n = n.max(1);
    let mut v: Vec<(String, &'static str)> = Vec::with_capacity(n);
    for (i, (title, color)) in LABEL_PRESETS.iter().enumerate() {
        if i >= n {
            break;
        }
        v.push(((*title).to_string(), *color));
    }
    while v.len() < n {
        let i = v.len();
        v.push((
            format!("标签 {:02}", i + 1),
            PROJECT_COLORS[i % PROJECT_COLORS.len()],
        ));
    }
    v
}

/// 确定性伪随机（splitmix64）。
///
/// 原种子用 `(i % 7) % live.len()` 分项目，项目数 >7 时会**永远漏掉尾部的项目**
/// （`i%7` 上限 6）；且与 `i % 10` 的完成/日期档一旦同模会整段耦合。这里改用
/// 哈希散列，与任何档位模数无结构关系。
fn mix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn year_start_ms(y: i32) -> i64 {
    Local
        .with_ymd_and_hms(y, 1, 1, 0, 0, 0)
        .single()
        .expect("--history 年份已限定 1970–2100")
        .timestamp_millis()
}

/// 标题词库：中文便于验证 FTS trigram 与拼音（用拼音首字母搜得到）
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

    // 附件二进制先落盘（事务外做 IO，避免持写锁搬 8.5MiB 文件）
    let attachment_seeds = build_attachments(
        args.attachments,
        args.big_attachments,
        &args.attachments_out,
    )?;

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

    // 历史区间取 [from 年 1 月 1 日, to 年 12 月 31 日 23:59:59.999]
    let hist_from = year_start_ms(args.history.0);
    let hist_to = year_start_ms(args.history.1 + 1) - 1;
    // 近期项目里的「跨年历史任务」从 2019 起（与历史区间留出可辨识的断点）
    let recent_from = year_start_ms(2019);

    let projects = build_projects(args.projects, args.history.0, args.history.1);
    let labels = build_labels(args.labels);

    // ── 项目（历史 + 父清单 + 子清单 + 归档）──
    let mut project_ids: Vec<i64> = Vec::with_capacity(projects.len());
    let mut project_uuids: Vec<String> = Vec::with_capacity(projects.len());
    for (i, project) in projects.iter().enumerate() {
        let uuid = format!("seed-proj-{i:03}");
        let parent_uuid = project.parent.map(|p| project_uuids[p].as_str());
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_projects \
               (uuid, title, hex_color, sort_order, parent_uuid, is_archived, is_deleted, \
                created_at, updated_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(&uuid)
        .bind(&project.title)
        .bind(project.color)
        .bind(i as f64)
        .bind(parent_uuid)
        .bind(i32::from(project.archived))
        .bind(now_ms)
        .bind(now_ms)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| format!("项目 {}: {e}", project.title))?;
        project_ids.push(id.0);
        project_uuids.push(uuid);
    }
    // 承接任务的项目：跳过归档（0 号是历史项目，单独走时间档）
    let live_projects: Vec<usize> = projects
        .iter()
        .enumerate()
        .filter(|(_, p)| !p.archived)
        .map(|(i, _)| i)
        .collect();

    // ── 标签 ──
    let mut label_ids: Vec<i64> = Vec::with_capacity(labels.len());
    for (i, (title, color)) in labels.iter().enumerate() {
        let id: (i64,) = sqlx::query_as(
            "INSERT INTO todo_labels (uuid, title, hex_color, is_deleted, created_at, updated_at, version) \
             VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING id",
        )
        .bind(format!("seed-label-{i:03}"))
        .bind(title)
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
    // 活任务 id（附件关联的抽取池）；4 万行 ≈ 320KB，无需流式
    let mut alive_task_ids: Vec<i64> = Vec::with_capacity(args.rows);
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

        // 每 11 条 1 条未分组；其余按 splitmix 散到非归档项目。
        // 不用 `i % k` 分项目：项目数 >7 时会漏掉尾部项目，且与 done(10)/due(10)
        // 的模数档位耦合，会让某类视图整段落在同一完成态上（首版种子踩过）。
        let project_idx = if i % 11 == 0 {
            None
        } else {
            Some(live_projects[(mix64(i as u64) as usize) % live_projects.len()])
        };
        let project_id = project_idx.map(|p| project_ids[p]);
        let is_history = project_idx == Some(0);

        let tp = time_profile(
            i,
            is_history,
            hist_from,
            hist_to,
            recent_from,
            today0,
            now_ms,
            day,
        );
        let (done, done_at, due_date, start_date) = (tp.done, tp.done_at, tp.due, tp.start);
        let created_at = tp.created;

        // 重复规则：五种模式全铺开（含按年、按第 N 个星期 X、两种结束条件）
        let (
            repeat_after,
            repeat_mode,
            repeat_weekdays,
            repeat_end_type,
            repeat_end_param,
            repeat_month_mode,
            repeat_nth_week,
        ) = repeat_profile(i, now_ms, day);
        let priority = (i % 6) as i32;
        let is_favorite = i32::from(i % 11 == 0);
        // 历史任务不进「我的一天」（否则今日视图会被历史项目刷满）
        let my_day_date = if !is_history && i % 13 == 0 {
            Some(today0)
        } else {
            None
        };
        let duration_minutes = if i % 6 == 0 {
            Some(((i % 4 + 1) * 15) as i64)
        } else {
            None
        };
        let status = if done {
            "done"
        } else if !is_history && i % 8 == 0 {
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
                due_date, start_date, repeat_after, repeat_mode, repeat_weekdays, repeat_end_type, \
                repeat_end_param, repeat_month_mode, repeat_nth_week, percent_done, position, \
                is_favorite, my_day_date, duration_minutes, is_deleted, created_at, updated_at, deleted_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 1) RETURNING id",
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
        .bind(repeat_end_type)
        .bind(repeat_end_param)
        .bind(repeat_month_mode)
        .bind(repeat_nth_week)
        .bind(i as f64)
        .bind(is_favorite)
        .bind(my_day_date)
        .bind(duration_minutes)
        .bind(is_deleted)
        .bind(created_at)
        // 与生产删除语义一致：软删行的 updated_at 就是删除时刻（不是创建时刻）
        .bind(deleted_at.unwrap_or(created_at))
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
        alive_task_ids.push(task_id);

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

    // ── 附件（sys_attachments 账本 + 任务关联；二进制已落盘）──
    if !attachment_seeds.is_empty() && !alive_task_ids.is_empty() {
        let mut used: HashSet<(i64, String)> = HashSet::new();
        for (k, att) in attachment_seeds.iter().enumerate() {
            sqlx::query(
                "INSERT OR IGNORE INTO sys_attachments \
                   (hash, original_name, mime_type, size_bytes, local_path, is_uploaded, \
                    is_local_cached, created_at, last_accessed_at) \
                 VALUES (?, ?, ?, ?, NULL, 0, 1, ?, ?)",
            )
            .bind(&att.hash)
            .bind(&att.name)
            .bind(att.mime)
            .bind(att.size)
            .bind(now_ms)
            .bind(now_ms)
            .execute(&mut *tx)
            .await
            .map_err(|e| format!("附件账本 {k}: {e}"))?;
            counters.attachments += 1;

            // 每个附件挂 1 条活任务；前 3 个额外共享到另一条任务，
            // 验「同 hash 多行引用」的内容寻址去重（上传只发生一次）
            let links = 1 + usize::from(k < 3);
            for j in 0..links {
                let task_id = alive_task_ids
                    [(mix64((k as u64) * 131 + j as u64) as usize) % alive_task_ids.len()];
                if !used.insert((task_id, att.hash.clone())) {
                    continue;
                }
                sqlx::query(
                    "INSERT INTO todo_task_attachments \
                       (uuid, task_id, hash, is_deleted, created_at, updated_at, version) \
                     VALUES (?, ?, ?, 0, ?, ?, 1)",
                )
                .bind(format!("seed-att-{k:03}-{j}"))
                .bind(task_id)
                .bind(&att.hash)
                .bind(now_ms)
                .bind(now_ms)
                .execute(&mut *tx)
                .await
                .map_err(|e| format!("附件关联 {k}/{j}: {e}"))?;
                counters.attachment_links += 1;
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
        "SEED_OK out={} bytes={} projects={} labels={} tasks={} subtasks={} reminders={} \
         comments={} task_labels={} trashed={} attachments={} attachment_links={} attachments_dir={}",
        args.out.display(),
        bytes,
        projects.len(),
        labels.len(),
        counters.tasks,
        counters.subtasks,
        counters.reminders,
        counters.comments,
        counters.task_labels,
        counters.trashed,
        counters.attachments,
        counters.attachment_links,
        args.attachments_out.display()
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
    attachments: usize,
    attachment_links: usize,
}

/// 任务时间档：历史项目落在 `--history` 区间；近期项目每 3 条有 1 条落在
/// [2019-01-01, 今天-30 天)，其余保持「逾期 / 今天 / 近 7 天 / 未来 30 天」
/// 的读通道覆盖（这些档位是列表分诊、日历、统计的验收基座，不能全改成历史）。
struct TimeProfile {
    due: Option<i64>,
    start: Option<i64>,
    created: i64,
    done: bool,
    done_at: Option<i64>,
}

#[allow(clippy::too_many_arguments)]
fn time_profile(
    i: usize,
    is_history: bool,
    hist_from: i64,
    hist_to: i64,
    recent_from: i64,
    today0: i64,
    now_ms: i64,
    day: i64,
) -> TimeProfile {
    // 历史项目：确定性散点铺满区间（≈5000 条覆盖 20 年，统计按年都有数）
    if is_history {
        let span = (hist_to - hist_from).max(day);
        let due = hist_from + (mix64(i as u64) % span as u64) as i64;
        let done = i % 10 != 9; // 90% 已完成，留 10% 历史遗留未完成（验逾期）
        let done_at = done.then(|| (due + ((i as i64 % 5) + 1) * day).min(now_ms - 3_600_000));
        return TimeProfile {
            due: Some(due),
            start: (i.is_multiple_of(7)).then_some(due - 2 * 3_600_000),
            created: due - ((i as i64 % 14) + 3) * day,
            done,
            done_at,
        };
    }

    // 近期项目的跨年档：2019 起铺到「今天-30 天」，与历史区间留出断点
    let recent_end = today0 - 30 * day;
    if i.is_multiple_of(3) && recent_end > recent_from {
        let span = recent_end - recent_from;
        let due = recent_from + (mix64((i as u64) ^ 0xA5A5_A5A5) % span as u64) as i64;
        let done = i % 10 != 9; // 90% 已完成（历史档同理）
        let done_at = done.then(|| (due + ((i as i64 % 7) + 1) * day).min(now_ms - 3_600_000));
        return TimeProfile {
            due: Some(due),
            start: (i.is_multiple_of(7)).then_some(due - 2 * 3_600_000),
            created: due - ((i as i64 % 21) + 1) * day,
            done,
            done_at,
        };
    }

    // 当前档：原种子口径（30% 完成、20% 无日期、20% 逾期、今天/近7天/未来）
    let done = i % 10 < 3;
    let done_at = done.then_some(now_ms - (i as i64 % 30) * day - 3_600_000);
    // 与 done 档（0..2 = 已完成）错开：3/4 才是「无日期」，否则未分组/无日期
    // 视图会整段落在已完成行上（首版种子的坑）
    let (due, mut start) = match i % 10 {
        3 | 4 => (None, None),                                      // 无日期（未完成）
        5 | 6 => (Some(today0 - ((i as i64 % 5) + 1) * day), None), // 逾期 1–5 天
        7 => (Some(today0 + 10 * 3_600_000), None),                 // 今天到期
        8 => (Some(today0 + 3 * day + 9 * 3_600_000), None),        // 近 7 天
        _ => (Some(today0 + ((i as i64 % 30) + 1) * day), None),    // 未来 1–30 天
    };
    // 每 7 条给 start_date（日历时间轴），与 due 错开形成跨天块
    if i.is_multiple_of(7) {
        start = Some(today0 + ((i as i64 % 14) - 3) * day + 14 * 3_600_000);
    }
    TimeProfile {
        due,
        start,
        created: now_ms - (i as i64 % 60) * 60_000,
        done,
        done_at,
    }
}

/// 重复规则档：`(after, mode, weekdays, end_type, end_param, month_mode, nth_week)`。
/// 覆盖日/周/月/年、工作日掩码、每 2 周、每月第 2 个周二、按日期结束、按次数结束。
#[allow(clippy::type_complexity)]
fn repeat_profile(i: usize, now_ms: i64, day: i64) -> (i64, i32, i32, i32, i64, i32, i32) {
    match i % 23 {
        0 => (1, 1, 0, 0, 0, 0, 0),                  // 每天
        1 => (1, 2, 0b0111110, 0, 0, 0, 0),          // 每周一~周五
        2 => (1, 3, 0, 0, 0, 0, 0),                  // 每月（按日号）
        3 => (1, 4, 0, 0, 0, 0, 0),                  // 每年
        5 => (2, 2, 0b0000101, 0, 0, 0, 0),          // 每 2 周（周一 + 周五）
        7 => (1, 3, 0, 0, 0, 1, 2),                  // 每月第 2 个周二
        9 => (1, 3, 0, 0, 0, 1, 6),                  // 每月最后一个周五
        11 => (1, 1, 0, 2, 10, 0, 0),                // 每天，重复 10 次后结束
        13 => (1, 2, 0, 1, now_ms + 90 * day, 0, 0), // 每周，按日期结束
        _ => (0, 0, 0, 0, 0, 0, 0),
    }
}

/// 生成附件二进制并算出内容寻址 hash。
///
/// 前 `big` 个为 8.5MiB（≥8MiB 触发 WebDAV 分片通道），其余 8–15KB。
/// 内容确定性生成，同一参数重跑得到同一组 hash（便于对账）。
struct AttachmentSeed {
    hash: String,
    name: String,
    mime: &'static str,
    size: i64,
}

fn build_attachments(n: usize, big: usize, dir: &Path) -> Result<Vec<AttachmentSeed>, String> {
    if n == 0 {
        return Ok(Vec::new());
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("附件目录 {}: {e}", dir.display()))?;
    let big = big.min(n);
    let mut seeds = Vec::with_capacity(n);
    for k in 0..n {
        let size: usize = if k < big {
            8 * 1024 * 1024 + 512 * 1024 // 8.5MiB
        } else {
            8 * 1024 + (k % 8) * 1024
        };
        let mut data = vec![0u8; size];
        let seed = (k as u64).wrapping_mul(0x9E37_79B9);
        for (p, byte) in data.iter_mut().enumerate() {
            *byte = ((p as u64).wrapping_mul(31) ^ seed) as u8;
        }
        let hash = sha256_hex(&data);
        std::fs::write(dir.join(&hash), &data)
            .map_err(|e| format!("写附件 {}: {e}", dir.join(&hash).display()))?;
        seeds.push(AttachmentSeed {
            hash,
            name: format!("seed-{k:03}.{}", if k < big { "bin" } else { "txt" }),
            mime: if k < big {
                "application/octet-stream"
            } else {
                "text/plain"
            },
            size: size as i64,
        });
    }
    Ok(seeds)
}
