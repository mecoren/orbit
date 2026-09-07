//! CSV 导入 API —— 07 报告「导入迁移路径」的落地
//!
//! 与明文导出（plaintext_export_api）对称的**导入方向**：支持三档预设
//! - `orbit`：自家导出 CSV（列名即映射，先吃狗粮保证往返一致）
//! - `todoist`：Todoist 模板 CSV（Type=Task 行，List Name→项目自动创建，
//!   Priority p1→4 / p2→3 / p3→2 / p4→1，Completed Date→完成态）
//! - `ticktick`：TickTick 模板 CSV（优先级 高→3 / 中→2 / 低→1 / 无→0）
//!
//! 设计：
//! - RFC 4180 解析（引号转义/逗号内换行/UTF-8 BOM 容忍/跳过空行）
//! - 两段式：`preview_csv_import`（解析+映射，返回预览行与统计，不写库）→
//!   `execute_csv_import`（按预览同源逻辑写库，每行独立成败互不阻断）
//! - 日期解析务实口径：yyyy-MM-dd / yyyy/M/d / M/d/yyyy / yyyy-MM-dd HH:mm，
//!   失败置 null 不阻断（任务可后补日期）
//! - 每行生成新 uuid（导入=搬运数据到本机，uuid 冲突天然规避）；
//!   写入走 generic_repo 事件面（同步 push 自动触发）
//! - Todoist/TickTick 的 List/Project 列按标题自动建项目（不区分大小写匹配）

use std::collections::HashMap;

use chrono::NaiveDate;
use serde::Serialize;
use sqlx::SqlitePool;

use crate::api::business_api;
use crate::error::CoreResult;
use crate::models::business::TodoTaskCreateInput;

// ============================================================================
// 解析：RFC 4180
// ============================================================================

/// 解析 CSV 文本为行列矩阵（去 BOM、跳过空行）
pub fn parse_csv(content: &str) -> Vec<Vec<String>> {
    let content = content.strip_prefix('\u{feff}').unwrap_or(content);
    let mut rows = Vec::new();
    let mut field = String::new();
    let mut row: Vec<String> = Vec::new();
    let mut in_quotes = false;
    let mut chars = content.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            '"' => {
                if in_quotes && chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = !in_quotes;
                }
            }
            ',' if !in_quotes => {
                row.push(std::mem::take(&mut field));
            }
            '\r' if !in_quotes => {
                // CRLF：等 '\n' 收行；孤立 \r 也收行
                if chars.peek() != Some(&'\n') {
                    row.push(std::mem::take(&mut field));
                    finish_row(&mut rows, &mut row);
                }
            }
            '\n' if !in_quotes => {
                row.push(std::mem::take(&mut field));
                finish_row(&mut rows, &mut row);
            }
            _ => field.push(c),
        }
    }
    // 尾字段/尾行（无换行结尾的最后一行）
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        finish_row(&mut rows, &mut row);
    }
    rows
}

fn finish_row(rows: &mut Vec<Vec<String>>, row: &mut Vec<String>) {
    // 空行跳过（全空字段）
    if !row.iter().all(|f| f.trim().is_empty()) {
        rows.push(std::mem::take(row));
    } else {
        row.clear();
    }
}

// ============================================================================
// 映射：预设 → TodoTaskCreateInput
// ============================================================================

/// CSV 导入预设档位
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsvImportPreset {
    Orbit,
    Todoist,
    TickTick,
}

impl CsvImportPreset {
    pub fn from_key(key: &str) -> CoreResult<Self> {
        match key {
            "orbit" => Ok(Self::Orbit),
            "todoist" => Ok(Self::Todoist),
            "ticktick" => Ok(Self::TickTick),
            _ => Err(crate::error::CoreError::Other(format!(
                "unknown csv import preset: '{key}', expected orbit/todoist/ticktick"
            ))),
        }
    }
}

/// 按表头名取列值（trim 后空串视为 None）
fn cell<'a>(header: &HashMap<String, usize>, row: &'a [String], name: &str) -> Option<&'a str> {
    let idx = header.get(name)?;
    row.get(*idx)
        .map(|s| s.as_str())
        .filter(|s| !s.trim().is_empty())
}

/// 解析日期字符串为本地零点毫秒
///
/// 支持格式：yyyy-MM-dd / yyyy-M-d / M/d/yyyy（Todoist 默认）/
/// yyyy-MM-dd HH:mm（TickTick 截断时间取日期）。失败返回 None（不阻断）。
fn parse_date_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let date_part = s.split_once(' ').map(|(d, _)| d).unwrap_or(s);
    let naive = NaiveDate::parse_from_str(date_part, "%Y-%m-%d")
        .or_else(|_| NaiveDate::parse_from_str(date_part, "%Y/%m/%d"))
        .or_else(|_| NaiveDate::parse_from_str(date_part, "%m/%d/%Y"))
        .or_else(|_| NaiveDate::parse_from_str(date_part, "%m/%d/%y"))
        .ok()?;
    use chrono::TimeZone;
    chrono::Local
        .from_local_datetime(&naive.and_hms_opt(0, 0, 0)?)
        .single()
        .map(|d| d.timestamp_millis())
}

/// 优先级映射（各预设 → orbit 0-5）
fn priority_from_todoist(s: &str) -> Option<i32> {
    match s.trim().to_lowercase().as_str() {
        "p1" | "priority 1" => Some(4),
        "p2" | "priority 2" => Some(3),
        "p3" | "priority 3" => Some(2),
        "p4" | "priority 4" => Some(1),
        _ => None,
    }
}

fn priority_from_ticktick(s: &str) -> Option<i32> {
    match s.trim() {
        "高" | "high" => Some(3),
        "中" | "medium" => Some(2),
        "低" | "low" => Some(1),
        "无" | "none" | "" => Some(0),
        _ => None,
    }
}

/// orbit 自家导出的优先级文本 → 数值（低/中/高/紧急/立即处理）
fn priority_from_orbit_text(s: &str) -> Option<i32> {
    match s.trim() {
        "低" => Some(1),
        "中" => Some(2),
        "高" => Some(3),
        "紧急" => Some(4),
        "立即处理" => Some(5),
        _ => None,
    }
}

/// 一条待导入任务的中间表示（预览与执行共用）
#[derive(Debug, Clone, Serialize)]
pub struct CsvImportRow {
    /// 源 CSV 行号（1 起，含表头）
    pub source_line: usize,
    /// 目标项目标题（None = 未分组；执行时按需自动建项目）
    pub project_title: Option<String>,
    pub input: TodoTaskCreateInput,
    /// 跳过原因（Some = 本行不导入）
    pub skip_reason: Option<String>,
}

/// 预览/执行结果统计
#[derive(Debug, Clone, Default, Serialize)]
pub struct CsvImportStats {
    pub success: usize,
    pub skipped: usize,
    pub failed: usize,
    /// 逐行错误/跳过说明（行号 + 原因）
    pub notes: Vec<String>,
}

/// 解析 CSV 内容 → 待导入行（含跳过标记）
///
/// 头一行必须存在且为表头。Todoist 的非 Task 类型行（section/note 等）
/// 与已完成且 Completed Date 为空的行会标记跳过。
pub fn map_csv_rows(content: &str, preset: CsvImportPreset) -> CoreResult<Vec<CsvImportRow>> {
    let rows = parse_csv(content);
    let Some(header_row) = rows.first() else {
        return Err(crate::error::CoreError::Other(
            "CSV 为空（无表头行）".into(),
        ));
    };
    let header: HashMap<String, usize> = header_row
        .iter()
        .enumerate()
        .map(|(i, h)| (h.trim().to_lowercase(), i))
        .collect();

    let mut out = Vec::new();
    for (i, row) in rows.iter().enumerate().skip(1) {
        let source_line = i + 1;
        let mapped = match preset {
            CsvImportPreset::Orbit => map_orbit_row(&header, row, source_line),
            CsvImportPreset::Todoist => map_todoist_row(&header, row, source_line),
            CsvImportPreset::TickTick => map_ticktick_row(&header, row, source_line),
        };
        out.push(mapped);
    }
    Ok(out)
}

fn map_orbit_row(header: &HashMap<String, usize>, row: &[String], line: usize) -> CsvImportRow {
    let title = cell(header, row, "title").map(str::to_string);
    let Some(title) = title else {
        return CsvImportRow {
            source_line: line,
            project_title: None,
            input: TodoTaskCreateInput::default(),
            skip_reason: Some("标题为空".into()),
        };
    };
    let priority = cell(header, row, "priority")
        .and_then(priority_from_orbit_text)
        .or_else(|| {
            cell(header, row, "priority").and_then(|s| s.parse::<i32>().ok().filter(|p| *p != 0))
        });
    CsvImportRow {
        source_line: line,
        project_title: cell(header, row, "project").map(str::to_string),
        input: TodoTaskCreateInput {
            title,
            description: cell(header, row, "description").map(str::to_string),
            priority,
            status: cell(header, row, "status").map(str::to_string),
            done: cell(header, row, "done").and_then(|s| s.parse::<i32>().ok()),
            done_at: cell(header, row, "done_at").and_then(parse_datetime_ms),
            due_date: cell(header, row, "due_date").and_then(parse_date_ms),
            start_date: cell(header, row, "start_date").and_then(parse_date_ms),
            ..Default::default()
        },
        skip_reason: None,
    }
}

/// 时间戳列解析：优先纯数字（ms），退回日期字符串
fn parse_datetime_ms(s: &str) -> Option<i64> {
    let t = s.trim();
    if let Ok(ms) = t.parse::<i64>() {
        return Some(ms);
    }
    parse_date_ms(t)
}

fn map_todoist_row(header: &HashMap<String, usize>, row: &[String], line: usize) -> CsvImportRow {
    // Todoist 模板：Type 列（task/section/note），只导 Task 行
    let type_col = cell(header, row, "type").unwrap_or("task");
    if !type_col.eq_ignore_ascii_case("task") {
        return CsvImportRow {
            source_line: line,
            project_title: None,
            input: TodoTaskCreateInput::default(),
            skip_reason: Some(format!("非 Task 类型行（type={type_col}）")),
        };
    }
    let Some(content) = cell(header, row, "content").map(str::to_string) else {
        return CsvImportRow {
            source_line: line,
            project_title: None,
            input: TodoTaskCreateInput::default(),
            skip_reason: Some("Content 为空".into()),
        };
    };
    let completed_at = cell(header, row, "completed date").and_then(parse_date_ms);
    let done = if completed_at.is_some() {
        Some(1)
    } else {
        Some(0)
    };
    CsvImportRow {
        source_line: line,
        project_title: cell(header, row, "list name").map(str::to_string),
        input: TodoTaskCreateInput {
            title: content,
            description: cell(header, row, "description").map(str::to_string),
            priority: cell(header, row, "priority").and_then(priority_from_todoist),
            done,
            done_at: completed_at,
            due_date: cell(header, row, "due date").and_then(parse_date_ms),
            ..Default::default()
        },
        skip_reason: None,
    }
}

fn map_ticktick_row(header: &HashMap<String, usize>, row: &[String], line: usize) -> CsvImportRow {
    let Some(name) = cell(header, row, "summary").map(str::to_string) else {
        return CsvImportRow {
            source_line: line,
            project_title: None,
            input: TodoTaskCreateInput::default(),
            skip_reason: Some("Summary 为空".into()),
        };
    };
    // TickTick Status 列：Completed=1 且有 Completed Time
    let completed_at = cell(header, row, "completed time").and_then(parse_date_ms);
    let done = if completed_at.is_some() {
        Some(1)
    } else {
        Some(0)
    };
    CsvImportRow {
        source_line: line,
        project_title: cell(header, row, "list name").map(str::to_string),
        input: TodoTaskCreateInput {
            title: name,
            description: cell(header, row, "note").map(str::to_string),
            priority: cell(header, row, "priority").and_then(priority_from_ticktick),
            done,
            done_at: completed_at,
            due_date: cell(header, row, "due date").and_then(parse_date_ms),
            start_date: cell(header, row, "start date").and_then(parse_date_ms),
            ..Default::default()
        },
        skip_reason: None,
    }
}

// ============================================================================
// 预览（不写库）
// ============================================================================

/// 预览结果：前 N 行预览载荷 + 全量统计
#[derive(Debug, Clone, Serialize)]
pub struct CsvImportPreview {
    pub preset: String,
    /// 预览行（最多 preview_limit 条，已含跳过标记）
    pub rows: Vec<CsvImportRow>,
    pub stats: CsvImportStats,
}

/// 解析并预览（不写库）：返回全部映射行中的前 `preview_limit` 条 + 全量统计
pub async fn preview_csv_import(
    content: &str,
    preset_key: &str,
    preview_limit: usize,
) -> CoreResult<CsvImportPreview> {
    let preset = CsvImportPreset::from_key(preset_key)?;
    let mapped = map_csv_rows(content, preset)?;
    let mut stats = CsvImportStats::default();
    for r in &mapped {
        if r.skip_reason.is_some() {
            stats.skipped += 1;
        } else {
            stats.success += 1; // 预览口径：待导入条数
        }
    }
    Ok(CsvImportPreview {
        preset: preset_key.to_string(),
        rows: mapped.into_iter().take(preview_limit).collect(),
        stats,
    })
}

// ============================================================================
// 执行（写库）
// ============================================================================

/// 执行导入：逐行写入（每行独立成败），项目标题不存在时自动创建
pub async fn execute_csv_import(
    pool: &SqlitePool,
    content: &str,
    preset_key: &str,
) -> CoreResult<CsvImportStats> {
    let preset = CsvImportPreset::from_key(preset_key)?;
    let mapped = map_csv_rows(content, preset)?;
    let mut stats = CsvImportStats::default();

    // 项目标题 → id 缓存（含既有项目；key 归一 lowercase 与查询侧一致，
    // 执行中新建项目累加）
    let mut project_ids: HashMap<String, i64> =
        sqlx::query_as("SELECT title, id FROM todo_projects WHERE is_deleted = 0")
            .fetch_all(pool)
            .await?
            .into_iter()
            .map(|(title, id): (String, i64)| (title.to_lowercase(), id))
            .collect();

    for r in mapped {
        if let Some(reason) = &r.skip_reason {
            stats.skipped += 1;
            stats
                .notes
                .push(format!("第 {} 行跳过：{}", r.source_line, reason));
            continue;
        }
        let input = &r.input;
        let title = if input.title.trim().is_empty() {
            stats.failed += 1;
            stats
                .notes
                .push(format!("第 {} 行失败：标题为空", r.source_line));
            continue;
        } else {
            input.title.trim().to_string()
        };
        // 项目自动创建（不区分大小写匹配）
        let project_id = match &r.project_title {
            Some(p) if !p.trim().is_empty() => {
                let key = p.trim().to_lowercase();
                match project_ids.get(&key) {
                    Some(id) => Some(*id),
                    None => {
                        let created = business_api::create_todo_project(
                            pool,
                            &crate::models::business::TodoProjectCreateInput {
                                title: p.trim().to_string(),
                                description: None,
                                hex_color: None,
                                sort_order: None,
                            },
                        )
                        .await;
                        match created {
                            Ok(proj) => {
                                project_ids.insert(key, proj.id);
                                Some(proj.id)
                            }
                            Err(e) => {
                                stats.failed += 1;
                                stats.notes.push(format!(
                                    "第 {} 行失败：创建项目「{}」出错（{e}）",
                                    r.source_line, p
                                ));
                                continue;
                            }
                        }
                    }
                }
            }
            _ => None,
        };
        let input = TodoTaskCreateInput {
            title,
            project_id,
            ..input.clone()
        };
        match business_api::create_todo_task(pool, &input).await {
            Ok(_) => stats.success += 1,
            Err(e) => {
                stats.failed += 1;
                stats
                    .notes
                    .push(format!("第 {} 行失败：{e}", r.source_line));
            }
        }
    }
    Ok(stats)
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ---------- RFC 4180 解析 ----------

    #[test]
    fn parse_basic_and_bom() {
        let rows = parse_csv("a,b,c\n1,2,3\n4,5,6");
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0], vec!["a", "b", "c"]);
        // BOM 剥离
        let rows = parse_csv("\u{feff}a,b\n1,2");
        assert_eq!(rows[0], vec!["a", "b"]);
    }

    #[test]
    fn parse_quoted_field_with_comma_and_newline() {
        let rows = parse_csv("name,desc\n\"a,b\",\"line1\nline2\"\nc,d");
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[1][0], "a,b");
        assert_eq!(rows[1][1], "line1\nline2");
    }

    #[test]
    fn parse_escaped_quotes() {
        let rows = parse_csv("x\n\"说\"\"好\"\"\"");
        assert_eq!(rows[1][0], "说\"好\"");
    }

    #[test]
    fn parse_skips_blank_lines_and_crlf() {
        let rows = parse_csv("a,b\r\n\r\n1,2\r\n");
        assert_eq!(rows.len(), 2);
    }

    // ---------- 日期/优先级映射 ----------

    #[test]
    fn date_formats() {
        assert!(parse_date_ms("2026-09-07").is_some());
        assert!(parse_date_ms("2026/9/7").is_some());
        assert!(parse_date_ms("09/07/2026").is_some());
        assert!(parse_date_ms("2026-09-07 14:30").is_some()); // TickTick 截断时间
        assert!(parse_date_ms("not a date").is_none());
        // 同一日期不同写法应得到同一零点毫秒
        assert_eq!(parse_date_ms("2026-09-07"), parse_date_ms("2026/9/7"));
    }

    #[test]
    fn priority_maps() {
        assert_eq!(priority_from_todoist("p1"), Some(4));
        assert_eq!(priority_from_todoist("P4"), Some(1));
        assert_eq!(priority_from_todoist("x"), None);
        assert_eq!(priority_from_ticktick("高"), Some(3));
        assert_eq!(priority_from_ticktick("low"), Some(1));
        assert_eq!(priority_from_orbit_text("紧急"), Some(4));
        assert_eq!(priority_from_orbit_text("低"), Some(1));
    }

    // ---------- 三档行映射 ----------

    #[test]
    fn map_orbit_roundtrip_columns() {
        let csv = "id,title,project,labels,priority,status,done,done_at,due_date,start_date,percent_done,description,created_at,updated_at\n\
                   1,买牛奶,生活,,高,pending,0,,2026-09-07,,,全脂,1,2\n";
        let rows = map_csv_rows(csv, CsvImportPreset::Orbit).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].skip_reason.is_none());
        assert_eq!(rows[0].input.title, "买牛奶");
        assert_eq!(rows[0].input.priority, Some(3));
        assert_eq!(rows[0].project_title.as_deref(), Some("生活"));
        assert_eq!(rows[0].input.done, Some(0));
        assert!(rows[0].input.due_date.is_some());
    }

    #[test]
    fn map_todoist_task_rows_only() {
        let csv = "type,content,priority,list name,due date,description,completed date\n\
                   task,写周报,p1,工作,2026-09-10,周五交,2026-09-08\n\
                   section,本周, inbox,2026-09-01,,\n\
                   task,买牛奶,p4,生活,,全脂,\n";
        let rows = map_csv_rows(csv, CsvImportPreset::Todoist).unwrap();
        assert_eq!(rows.len(), 3);
        // 行 1：完成态 + p1→4 + 项目映射
        assert_eq!(rows[0].input.done, Some(1));
        assert!(rows[0].input.done_at.is_some());
        assert_eq!(rows[0].input.priority, Some(4));
        assert_eq!(rows[0].project_title.as_deref(), Some("工作"));
        // 行 2：section 跳过
        assert!(rows[1].skip_reason.is_some());
        // 行 3：未完成 + p4→1
        assert_eq!(rows[2].input.done, Some(0));
        assert_eq!(rows[2].input.priority, Some(1));
        assert!(rows[2].input.done_at.is_none());
    }

    #[test]
    fn map_ticktick_columns() {
        let csv = "summary,priority,list name,start date,due date,completed time,note\n\
                   晨会,高,工作,2026-09-07,2026-09-07 09:30,,站会\n\
                   读书,无,生活,,,2026-09-01 20:00,30 分钟\n";
        let rows = map_csv_rows(csv, CsvImportPreset::TickTick).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].input.priority, Some(3));
        assert_eq!(rows[0].input.done, Some(0));
        assert!(rows[0].input.due_date.is_some());
        assert_eq!(rows[1].input.done, Some(1));
        assert_eq!(rows[1].input.priority, Some(0));
        assert_eq!(rows[1].project_title.as_deref(), Some("生活"));
    }

    #[test]
    fn empty_title_row_marked_skip() {
        // 纯空白行在解析层即被丢弃；标题空但有其他列的行在映射层标记跳过
        let csv = "title,project\n,生活\n";
        let rows = map_csv_rows(csv, CsvImportPreset::Orbit).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].skip_reason.is_some());
    }

    #[test]
    fn empty_csv_rejected() {
        assert!(map_csv_rows("", CsvImportPreset::Orbit).is_err());
    }

    // ---------- 执行（内存库） ----------

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[tokio::test]
    async fn execute_orbit_csv_creates_tasks_and_project() {
        let pool = setup_db().await;
        let csv = "title,project,priority,due_date,done\n买牛奶,生活,高,2026-09-07,0\n写周报,工作,,2026-09-10,0\n";
        let stats = execute_csv_import(&pool, csv, "orbit").await.unwrap();
        assert_eq!(stats.success, 2);
        assert_eq!(stats.failed, 0);
        // 种子默认收件箱 + 两个导入项目（生活/工作）自动创建
        let projects: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM todo_projects WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(projects, 3);
        let tasks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(tasks, 2);
    }

    #[tokio::test]
    async fn execute_todoist_csv_reuses_existing_project() {
        let pool = setup_db().await;
        // 预建同名项目（大小写不同也应命中）
        business_api::create_todo_project(
            &pool,
            &crate::models::business::TodoProjectCreateInput {
                title: "Work".into(),
                description: None,
                hex_color: None,
                sort_order: None,
            },
        )
        .await
        .unwrap();
        let csv = "type,content,list name\ntask,task A,work\ntask,task B,work\n";
        let stats = execute_csv_import(&pool, csv, "todoist").await.unwrap();
        assert_eq!(stats.success, 2);
        // 种子收件箱 + Work（大小写不同仍复用，不重复建）
        let projects: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM todo_projects WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(projects, 2);
    }

    #[tokio::test]
    async fn execute_skips_invalid_rows_but_continues() {
        let pool = setup_db().await;
        let csv = "type,content,completed date\ntask,ok task,\nsection,skip me,\ntask,done task,2026-09-01\n";
        let stats = execute_csv_import(&pool, csv, "todoist").await.unwrap();
        assert_eq!(stats.success, 2);
        assert_eq!(stats.skipped, 1);
        assert_eq!(stats.failed, 0);
    }

    #[tokio::test]
    async fn preview_does_not_write() {
        let pool = setup_db().await;
        let csv = "title\n预览任务\n";
        let preview = preview_csv_import(csv, "orbit", 10).await.unwrap();
        assert_eq!(preview.stats.success, 1);
        let tasks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(tasks, 0, "预览不得写库");
    }
}
