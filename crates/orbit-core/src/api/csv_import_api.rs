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
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use chrono::NaiveDate;
use once_cell::sync::Lazy;
use serde::Serialize;
use sqlx::SqlitePool;

use crate::api::business_api;
use crate::error::CoreResult;
use crate::models::business::TodoTaskCreateInput;

// ============================================================================
// 导入硬上限（docs/13 §6.2 M2）
// ============================================================================

/// 单个导入文件的字节上限（UTF-8 原文长度，不含解码余量）。
///
/// 取值口径：真实用户样本里 Todoist/TickTick 全量导出多在数 MB 量级，
/// 20MB 对应约 10 万条任务，已远超单人待办库的合理规模；再大基本是
/// 误选文件（如整份数据库 dump）。超限直接拒绝而不是截断——截断会让
/// 用户以为「导入成功」却丢数据。
pub const IMPORT_MAX_BYTES: usize = 20 * 1024 * 1024;

/// 单个导入文件的数据行上限（不含表头行 / 非 VTODO 块）。
///
/// 与 [`IMPORT_MAX_BYTES`] 互补：纯短标题的 CSV 可以在 20MB 内塞进
/// 上百万行，行数上限防的是「字节没超但行数爆炸」的那类文件。
pub const IMPORT_MAX_ROWS: usize = 200_000;

/// 预览返回的行数上限（超出只截断预览载荷，统计仍按全量扫描）
pub const IMPORT_PREVIEW_MAX_ROWS: usize = 200;

/// 限额校验失败的可读说明（前端直接展示给用户）
fn limit_error_bytes(len: usize) -> crate::error::CoreError {
    crate::error::CoreError::Other(format!(
        "文件过大（{:.1} MB，上限 {} MB），请拆分后分批导入",
        len as f64 / (1024.0 * 1024.0),
        IMPORT_MAX_BYTES / (1024 * 1024)
    ))
}

fn limit_error_rows(rows: usize) -> crate::error::CoreError {
    crate::error::CoreError::Other(format!(
        "行数过多（{rows} 行，上限 {IMPORT_MAX_ROWS} 行），请拆分后分批导入"
    ))
}

/// 导入前的字节数预检（桥层在读文件前先拦，省一次整份读入）
pub fn check_import_bytes(len: usize) -> crate::error::CoreResult<()> {
    if len > IMPORT_MAX_BYTES {
        return Err(limit_error_bytes(len));
    }
    Ok(())
}

/// 导入限额快照（桥层下发给 UI，用于选文件后即时提示，不必先 invoke 导入）
#[derive(Debug, Clone, Copy, Serialize)]
pub struct ImportLimits {
    /// 单文件字节上限
    pub max_bytes: usize,
    /// 单文件数据行上限
    pub max_rows: usize,
}

/// 取当前导入限额（单一来源在 core，双端 UI 不各自硬编码）
pub fn import_limits() -> ImportLimits {
    ImportLimits {
        max_bytes: IMPORT_MAX_BYTES,
        max_rows: IMPORT_MAX_ROWS,
    }
}

// ============================================================================
// 解析：RFC 4180（流式，逐行回调）
// ============================================================================

/// CSV 行迭代器：按需产出「一行字段」，不预先把整份文件物化。
///
/// 存在的理由是**执行路径需要 `await`**：写库是异步的，而闭包回调无法
/// `await`。迭代器让调用方用 `for row in CsvRows::new(content)` 逐行取，
/// 每写若干行再 `await` 一次，解析进度天然停在行边界上。
///
/// 解析口径（RFC 4180）：BOM 剥离、引号转义（`""` → `"`）、引号内逗号与
/// 换行合法、CRLF / 孤立 CR / 裸 LF 均可收行、无换行结尾的尾行也收、
/// 全空字段行跳过。
pub struct CsvRows<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
    /// 已把首字符的 BOM 剥掉（只做一次）
    bom_checked: bool,
    finished: bool,
}

impl<'a> CsvRows<'a> {
    pub fn new(content: &'a str) -> Self {
        Self {
            chars: content.chars().peekable(),
            bom_checked: false,
            finished: false,
        }
    }
}

impl Iterator for CsvRows<'_> {
    type Item = Vec<String>;

    fn next(&mut self) -> Option<Vec<String>> {
        if self.finished {
            return None;
        }
        if !self.bom_checked {
            self.bom_checked = true;
            if self.chars.peek() == Some(&'\u{feff}') {
                self.chars.next();
            }
        }

        let mut field = String::new();
        let mut row: Vec<String> = Vec::new();
        let mut in_quotes = false;
        let mut any = false; // 是否读到过任何字符（区分空文件与空行）

        while let Some(c) = self.chars.next() {
            any = true;
            match c {
                '"' => {
                    if in_quotes && self.chars.peek() == Some(&'"') {
                        self.chars.next();
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
                    if self.chars.peek() != Some(&'\n') {
                        row.push(std::mem::take(&mut field));
                        return self.finish_row(row);
                    }
                }
                '\n' if !in_quotes => {
                    row.push(std::mem::take(&mut field));
                    return self.finish_row(row);
                }
                _ => field.push(c),
            }
        }

        if !any {
            self.finished = true;
            return None;
        }
        // 尾字段/尾行（无换行结尾的最后一行）
        row.push(field);
        self.finished = true;
        self.finish_row(row)
    }
}

impl CsvRows<'_> {
    /// 空行跳过（全空字段）——跳过时继续取下一条，直到拿到非空行或到尾部
    fn finish_row(&mut self, mut row: Vec<String>) -> Option<Vec<String>> {
        if !row.iter().all(|f| f.trim().is_empty()) {
            return Some(row);
        }
        row.clear();
        self.next()
    }
}

/// 解析 CSV 文本为行列矩阵（去 BOM、跳过空行）。
///
/// 保留为测试与外部便利入口：内部导入路径走 [`CsvRows`] /
/// [`parse_csv_stream`]，不再整份物化。
pub fn parse_csv(content: &str) -> Vec<Vec<String>> {
    CsvRows::new(content).collect()
}

// ============================================================================
// 映射：预设 → TodoTaskCreateInput
// ============================================================================

/// CSV 导入预设档位（`ics` 是 ICS 文件导入：内容走 VTODO 解析，
/// 产物喂同一 CsvImportRow IR，经同一预览/执行与项目自动创建链路）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsvImportPreset {
    Orbit,
    Todoist,
    TickTick,
    Ics,
}

impl CsvImportPreset {
    pub fn from_key(key: &str) -> CoreResult<Self> {
        match key {
            "orbit" => Ok(Self::Orbit),
            "todoist" => Ok(Self::Todoist),
            "ticktick" => Ok(Self::TickTick),
            "ics" => Ok(Self::Ics),
            _ => Err(crate::error::CoreError::Other(format!(
                "unknown csv import preset: '{key}', expected orbit/todoist/ticktick/ics"
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
///
/// 便利入口：返回全部映射行。导入的真实路径（预览/执行）走
/// [`stream_csv_rows`]，不把全部行驻留内存。
pub fn map_csv_rows(content: &str, preset: CsvImportPreset) -> CoreResult<Vec<CsvImportRow>> {
    let mut out = Vec::new();
    stream_csv_rows(content, preset, |row| {
        out.push(row);
        Ok(())
    })?;
    Ok(out)
}

/// 逐行映射 CSV / ICS 内容（流式，导入的真实路径）。
///
/// 与 [`map_csv_rows`] 的差别只在交付方式：本函数不累积行，内存与
/// **单行宽度**相关，与文件行数无关。回调返回 `Err` 即中止（行数超限）。
///
/// 超限口径：字节数与数据行数都按 [`IMPORT_MAX_BYTES`] / [`IMPORT_MAX_ROWS`]
/// 判，超出即整体拒绝——不做截断，避免用户以为导入完整却丢数据。
pub fn stream_csv_rows<F>(content: &str, preset: CsvImportPreset, mut on_row: F) -> CoreResult<()>
where
    F: FnMut(CsvImportRow) -> CoreResult<()>,
{
    // ICS 走 VTODO 解析（ics_import_api），CSV 走表头映射；产物同为 CsvImportRow
    if preset == CsvImportPreset::Ics {
        check_import_bytes(content.len())?;
        let rows = crate::api::ics_import_api::map_ics_rows(content)?;
        if rows.len() > IMPORT_MAX_ROWS {
            return Err(limit_error_rows(rows.len()));
        }
        for row in rows {
            on_row(row)?;
        }
        return Ok(());
    }

    check_import_bytes(content.len())?;
    for row in csv_import_rows(content, preset)? {
        on_row(row?)?;
    }
    Ok(())
}

/// CSV 内容 → 待导入行迭代器（表头已定型的流式入口）。
///
/// 与 [`stream_csv_rows`] 的区别：返回 `Iterator` 而非回调，供**异步**
/// 执行路径 `for` 循环逐行取、按批 `await` 写库。空文件（无表头）在
/// 迭代器构造时即报错。
pub fn csv_import_rows<'a>(
    content: &'a str,
    preset: CsvImportPreset,
) -> CoreResult<CsvImportRows<'a>> {
    check_import_bytes(content.len())?;
    let mut iter = CsvRows::new(content);
    let Some(header_row) = iter.next() else {
        return Err(crate::error::CoreError::Other(
            "CSV 为空（无表头行）".into(),
        ));
    };
    let header: HashMap<String, usize> = header_row
        .iter()
        .enumerate()
        .map(|(i, h)| (h.trim().to_lowercase(), i))
        .collect();
    Ok(CsvImportRows {
        iter,
        preset,
        header,
        data_rows: 0,
    })
}

/// [`csv_import_rows`] 的迭代器：逐行映射，行数超限即报错。
pub struct CsvImportRows<'a> {
    iter: CsvRows<'a>,
    preset: CsvImportPreset,
    header: HashMap<String, usize>,
    data_rows: usize,
}

impl Iterator for CsvImportRows<'_> {
    type Item = CoreResult<CsvImportRow>;

    fn next(&mut self) -> Option<CoreResult<CsvImportRow>> {
        let row = self.iter.next()?;
        self.data_rows += 1;
        if self.data_rows > IMPORT_MAX_ROWS {
            return Some(Err(limit_error_rows(self.data_rows)));
        }
        // source_line 与旧口径一致：表头占第 1 行，数据行从第 2 行起
        let source_line = self.data_rows + 1;
        let mapped = match self.preset {
            CsvImportPreset::Orbit => map_orbit_row(&self.header, &row, source_line),
            CsvImportPreset::Todoist => map_todoist_row(&self.header, &row, source_line),
            CsvImportPreset::TickTick => map_ticktick_row(&self.header, &row, source_line),
            // ICS 已在入口分流到 VTODO 解析，不会走到 CSV 行映射
            CsvImportPreset::Ics => unreachable!("ICS preset 已分流"),
        };
        Some(Ok(mapped))
    }
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
///
/// 流式实现：统计按全量扫描累加，但只驻留前 `preview_limit` 行。
/// `preview_limit` 由 [`IMPORT_PREVIEW_MAX_ROWS`] 封顶（调用方传更大值
/// 也不会让预览载荷无界）。
pub async fn preview_csv_import(
    content: &str,
    preset_key: &str,
    preview_limit: usize,
) -> CoreResult<CsvImportPreview> {
    let preset = CsvImportPreset::from_key(preset_key)?;
    let limit = preview_limit.min(IMPORT_PREVIEW_MAX_ROWS);
    let mut stats = CsvImportStats::default();
    let mut rows: Vec<CsvImportRow> = Vec::new();
    stream_csv_rows(content, preset, |r| {
        if r.skip_reason.is_some() {
            stats.skipped += 1;
        } else {
            stats.success += 1; // 预览口径：待导入条数
        }
        if rows.len() < limit {
            rows.push(r);
        }
        Ok(())
    })?;
    Ok(CsvImportPreview {
        preset: preset_key.to_string(),
        rows,
        stats,
    })
}

// ============================================================================
// 可取消的导入任务（进度 + 取消；docs/13 §6.2 M2 第 3/5 点）
// ============================================================================

/// 导入任务状态快照（双端 UI 轮询用）
#[derive(Debug, Clone, Serialize)]
pub struct ImportJobStatus {
    /// 任务 id（调用方持有，用于轮询与取消）
    pub job_id: String,
    /// 已处理行数（含跳过/失败）
    pub processed: usize,
    /// 预计总行数（解析阶段先数一遍；未知时为 None）
    pub total: Option<usize>,
    /// 是否已结束（完成 / 失败 / 取消）
    pub finished: bool,
    /// 是否被取消（finished 且 cancelled 才是「用户取消」）
    pub cancelled: bool,
    /// 结束时的统计（未结束时为 None）
    pub stats: Option<CsvImportStats>,
    /// 结束时的错误说明（失败时）
    pub error: Option<String>,
}

/// 导入任务的共享状态（进程内，按 job_id 索引）
///
/// 有界性：条目在任务结束时保留、由调用方 `csv_import_job_drop` 或下一次
/// `start` 时清理已完成且超龄的条目；同时最多保留
/// [`IMPORT_JOB_KEEP_FINISHED`] 条已结束任务，超出按结束时间淘汰。
pub struct ImportJob {
    job_id: String,
    processed: AtomicUsize,
    total: AtomicUsize, // 0 = 未知
    finished: AtomicBool,
    cancelled: AtomicBool,
    stats: Mutex<Option<CsvImportStats>>,
    error: Mutex<Option<String>>,
    finished_at: Mutex<Option<std::time::Instant>>,
}

/// 进程内任务表上限（已结束任务按结束时间淘汰；运行中的不淘汰）
const IMPORT_JOB_KEEP_FINISHED: usize = 8;

// bounded: 最多 IMPORT_JOB_KEEP_FINISHED 条已结束任务，超龄/超量即淘汰
static IMPORT_JOBS: Lazy<Mutex<HashMap<String, Arc<ImportJob>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 生成任务 id（时间戳 + 进程内自增，避免引入 uuid 依赖差异）
fn next_job_id() -> String {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let ts = chrono::Local::now().timestamp_millis();
    format!("import-{ts}-{n}")
}

/// 淘汰已结束的旧任务（保留最近 [`IMPORT_JOB_KEEP_FINISHED`] 条）
fn prune_finished_jobs(map: &mut HashMap<String, Arc<ImportJob>>) {
    let mut finished: Vec<(String, std::time::Instant)> = map
        .iter()
        .filter(|(_, j)| j.finished.load(Ordering::Relaxed))
        .map(|(k, j)| {
            let at = j
                .finished_at
                .lock()
                .ok()
                .and_then(|g| *g)
                .unwrap_or_else(std::time::Instant::now);
            (k.clone(), at)
        })
        .collect();
    if finished.len() <= IMPORT_JOB_KEEP_FINISHED {
        return;
    }
    finished.sort_by_key(|(_, at)| *at);
    let excess = finished.len() - IMPORT_JOB_KEEP_FINISHED;
    for (k, _) in finished.into_iter().take(excess) {
        map.remove(&k);
    }
}

/// 启动一次可取消的导入（后台执行，调用方轮询 [`csv_import_job_status`]）。
///
/// 与 [`execute_csv_import`] 的差别只有「可观测 + 可中断」：行级写入语义
/// 完全一致（单行失败不阻断其余行、项目按标题自动创建）。取消在**行边界**
/// 生效——已写入的行保留（导入本就是增量写入，不做整批回滚），这与
/// 「取消后无半写状态」的口径一致：不会留下半行。
pub fn start_csv_import_job(
    pool: SqlitePool,
    content: String,
    preset_key: String,
) -> CoreResult<String> {
    // 先做一次同步预检（限额 / 预设），把可立即发现的错误在启动前抛出，
    // 不让用户在「任务已启动」之后才看到失败。
    // 行数必须在启动前数清：行数校验藏在迭代器里，若留给后台任务，
    // 超限会变成「跑了一会儿才失败」，且已写入的行无法收回。
    let preset = CsvImportPreset::from_key(&preset_key)?;
    check_import_bytes(content.len())?;
    let total_rows = count_import_rows(&content, preset)?;

    let job_id = next_job_id();
    let job = Arc::new(ImportJob {
        job_id: job_id.clone(),
        processed: AtomicUsize::new(0),
        // 启动前已数过行，total 立即就绪（UI 可显示真实百分比）
        total: AtomicUsize::new(total_rows),
        finished: AtomicBool::new(false),
        cancelled: AtomicBool::new(false),
        stats: Mutex::new(None),
        error: Mutex::new(None),
        finished_at: Mutex::new(None),
    });

    {
        let mut map = IMPORT_JOBS.lock().unwrap_or_else(|e| e.into_inner());
        prune_finished_jobs(&mut map);
        map.insert(job_id.clone(), job.clone());
    }

    let spawned = job.clone();
    tokio::spawn(async move {
        let outcome = run_import_job(&spawned, &pool, &content, preset).await;
        match outcome {
            Ok(stats) => {
                if let Ok(mut g) = spawned.stats.lock() {
                    *g = Some(stats);
                }
            }
            Err(e) => {
                if let Ok(mut g) = spawned.error.lock() {
                    *g = Some(e.to_string());
                }
            }
        }
        spawned.finished.store(true, Ordering::Relaxed);
        if let Ok(mut g) = spawned.finished_at.lock() {
            *g = Some(std::time::Instant::now());
        }
    });

    Ok(job_id)
}

/// 数一遍数据行数（启动前预检；超限即报错）。
///
/// 代价是解析两次（一次数行、一次写库），换来两个好处：①超限在启动前
/// 同步拒绝；②任务启动即有精确 `total`，UI 能显示真实百分比。
/// 解析本身不物化行矩阵，两次扫描的内存都是单行宽度。
fn count_import_rows(content: &str, preset: CsvImportPreset) -> CoreResult<usize> {
    if preset == CsvImportPreset::Ics {
        let rows = crate::api::ics_import_api::map_ics_rows(content)?;
        if rows.len() > IMPORT_MAX_ROWS {
            return Err(limit_error_rows(rows.len()));
        }
        return Ok(rows.len());
    }
    let mut n = 0usize;
    for next in csv_import_rows(content, preset)? {
        next?;
        n += 1;
    }
    Ok(n)
}

/// 任务执行体：逐行写库，每行检查取消标记并更新进度
async fn run_import_job(
    job: &ImportJob,
    pool: &SqlitePool,
    content: &str,
    preset: CsvImportPreset,
) -> CoreResult<CsvImportStats> {
    let mut stats = CsvImportStats::default();
    let mut project_ids: HashMap<String, i64> =
        sqlx::query_as("SELECT title, id FROM todo_projects WHERE is_deleted = 0")
            .fetch_all(pool)
            .await?
            .into_iter()
            .map(|(title, id): (String, i64)| (title.to_lowercase(), id))
            .collect();

    // 行数与限额已在 start_csv_import_job 同步预检过（total 已就绪），
    // 这里不再重复校验，只负责逐行写 + 取消检查。
    if preset == CsvImportPreset::Ics {
        for r in crate::api::ics_import_api::map_ics_rows(content)? {
            if job.cancelled.load(Ordering::Relaxed) {
                break;
            }
            write_import_row(pool, &mut project_ids, &mut stats, r).await;
            job.processed.fetch_add(1, Ordering::Relaxed);
        }
        return Ok(stats);
    }

    for next in csv_import_rows(content, preset)? {
        if job.cancelled.load(Ordering::Relaxed) {
            break;
        }
        write_import_row(pool, &mut project_ids, &mut stats, next?).await;
        job.processed.fetch_add(1, Ordering::Relaxed);
    }
    Ok(stats)
}

/// 轮询任务状态
pub fn csv_import_job_status(job_id: &str) -> CoreResult<ImportJobStatus> {
    let job = {
        let map = IMPORT_JOBS.lock().unwrap_or_else(|e| e.into_inner());
        map.get(job_id).cloned()
    };
    let Some(job) = job else {
        return Err(crate::error::CoreError::NotFound(format!(
            "导入任务不存在或已结束清理：{job_id}"
        )));
    };
    let total = job.total.load(Ordering::Relaxed);
    Ok(ImportJobStatus {
        job_id: job.job_id.clone(),
        processed: job.processed.load(Ordering::Relaxed),
        total: if total == 0 { None } else { Some(total) },
        finished: job.finished.load(Ordering::Relaxed),
        cancelled: job.cancelled.load(Ordering::Relaxed),
        stats: job.stats.lock().ok().and_then(|g| g.clone()),
        error: job.error.lock().ok().and_then(|g| g.clone()),
    })
}

/// 请求取消任务（行边界生效；已写入的行保留，不做整批回滚）
pub fn csv_import_job_cancel(job_id: &str) -> CoreResult<()> {
    let map = IMPORT_JOBS.lock().unwrap_or_else(|e| e.into_inner());
    let Some(job) = map.get(job_id) else {
        return Err(crate::error::CoreError::NotFound(format!(
            "导入任务不存在：{job_id}"
        )));
    };
    job.cancelled.store(true, Ordering::Relaxed);
    Ok(())
}

/// 释放任务条目（调用方在拿到终态后调用，避免任务表滞留）
pub fn csv_import_job_drop(job_id: &str) {
    let mut map = IMPORT_JOBS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(job) = map.get(job_id)
        && job.finished.load(Ordering::Relaxed)
    {
        map.remove(job_id);
    }
}

/// 执行导入：逐行写入（每行独立成败），项目标题不存在时自动创建
///
/// 流式实现：解析与写库**交错**进行（[`csv_import_rows`] 逐行产出 →
/// 立即写库），内存只保留当前行。早期版本先 `map_csv_rows` 物化全部映射行
/// 再逐条写库，峰值与文件行数线性相关；现在峰值与行数无关。
///
/// 语义不变：单行失败不阻断其余行；项目按标题自动创建（大小写不敏感复用）。
pub async fn execute_csv_import(
    pool: &SqlitePool,
    content: &str,
    preset_key: &str,
) -> CoreResult<CsvImportStats> {
    let preset = CsvImportPreset::from_key(preset_key)?;
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

    // ICS 与 CSV 的解析产物同为 CsvImportRow，但迭代器是两种具体类型
    // （不能装箱成 `Box<dyn Iterator>`：非 Send，跨 await 会破坏 FRB 的
    // 线程约束）。故分两条路径各自驱动，写库逻辑共用 write_import_row。
    if preset == CsvImportPreset::Ics {
        check_import_bytes(content.len())?;
        let parsed = crate::api::ics_import_api::map_ics_rows(content)?;
        if parsed.len() > IMPORT_MAX_ROWS {
            return Err(limit_error_rows(parsed.len()));
        }
        for r in parsed {
            write_import_row(pool, &mut project_ids, &mut stats, r).await;
        }
        return Ok(stats);
    }

    for next in csv_import_rows(content, preset)? {
        write_import_row(pool, &mut project_ids, &mut stats, next?).await;
    }
    Ok(stats)
}

/// 写入单条导入行并累加统计（失败只记 note，不中断整批）
async fn write_import_row(
    pool: &SqlitePool,
    project_ids: &mut HashMap<String, i64>,
    stats: &mut CsvImportStats,
    r: CsvImportRow,
) {
    if let Some(reason) = &r.skip_reason {
        stats.skipped += 1;
        stats
            .notes
            .push(format!("第 {} 行跳过：{}", r.source_line, reason));
        return;
    }
    let input = &r.input;
    let title = if input.title.trim().is_empty() {
        stats.failed += 1;
        stats
            .notes
            .push(format!("第 {} 行失败：标题为空", r.source_line));
        return;
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
                            parent_uuid: None,
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
                            return;
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
                parent_uuid: None,
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

    // ---------- M2 导入限额与流式（docs/13 §6.2） ----------

    #[test]
    fn byte_limit_rejects_oversized_before_parsing() {
        // 超限即拒，且错误文案要能直接给用户看（含实际大小与上限）
        let err = check_import_bytes(IMPORT_MAX_BYTES + 1).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("文件过大"), "文案应可读：{msg}");
        assert!(msg.contains("上限 20 MB"), "应给出上限：{msg}");
        // 恰好等于上限时放行（边界含等于）
        assert!(check_import_bytes(IMPORT_MAX_BYTES).is_ok());
    }

    #[test]
    fn row_limit_rejects_and_reports_count() {
        // 行数超限：字节没超也要拒（纯短标题能把行数堆到上限之上）
        let mut csv = String::from("title\n");
        for _ in 0..(IMPORT_MAX_ROWS + 1) {
            csv.push_str("a\n");
        }
        let err = map_csv_rows(&csv, CsvImportPreset::Orbit).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("行数过多"), "文案应可读：{msg}");
        assert!(
            msg.contains(&(IMPORT_MAX_ROWS + 1).to_string()),
            "应报出实际行数：{msg}"
        );
    }

    #[test]
    fn preview_caps_rows_but_keeps_full_stats() {
        // 预览只留前 N 行，统计仍按全量——这是 M2 的核心口径
        let mut csv = String::from("title\n");
        for i in 0..50 {
            csv.push_str(&format!("任务{i}\n"));
        }
        let preview = futures_block_on(preview_csv_import(&csv, "orbit", 10)).unwrap();
        assert_eq!(preview.rows.len(), 10, "预览载荷受 limit 约束");
        assert_eq!(preview.stats.success, 50, "统计必须是全量");
    }

    #[test]
    fn preview_limit_is_clamped_to_max() {
        // 调用方传超大 limit 也不能让预览载荷无界
        let mut csv = String::from("title\n");
        for i in 0..(IMPORT_PREVIEW_MAX_ROWS + 5) {
            csv.push_str(&format!("任务{i}\n"));
        }
        let preview = futures_block_on(preview_csv_import(&csv, "orbit", usize::MAX)).unwrap();
        assert_eq!(preview.rows.len(), IMPORT_PREVIEW_MAX_ROWS);
        assert_eq!(preview.stats.success, IMPORT_PREVIEW_MAX_ROWS + 5);
    }

    #[test]
    fn streaming_parser_matches_materialized_one() {
        // 迭代器与物化入口必须同口径（BOM / 引号 / CRLF / 空行 / 尾行）
        let cases = [
            "a,b,c\n1,2,3\n4,5,6",
            "\u{feff}a,b\n1,2",
            "name,desc\n\"a,b\",\"line1\nline2\"\nc,d",
            "a,b\r\n\r\n1,2\r\n",
            "x\n\"说\"\"好\"\"\"",
        ];
        for content in cases {
            let materialized = parse_csv(content);
            let streamed: Vec<Vec<String>> = CsvRows::new(content).collect();
            assert_eq!(materialized, streamed, "内容：{content:?}");
        }
    }

    #[test]
    fn empty_and_blank_only_files_yield_no_rows() {
        assert!(parse_csv("").is_empty());
        assert!(parse_csv("\n\n\r\n").is_empty());
        assert!(parse_csv("\u{feff}").is_empty());
    }

    #[test]
    fn source_line_numbers_stay_1_based_with_header() {
        // source_line 与旧口径一致：表头占第 1 行，数据行从第 2 行起
        let csv = "title\n甲\n乙\n";
        let rows = map_csv_rows(csv, CsvImportPreset::Orbit).unwrap();
        assert_eq!(rows[0].source_line, 2);
        assert_eq!(rows[1].source_line, 3);
    }

    /// 同步块里跑 async（仅测试用；避免为一处断言引入 tokio runtime 依赖）
    fn futures_block_on<F: std::future::Future>(fut: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(fut)
    }

    // ---------- 可取消导入任务（进度 + 取消） ----------

    #[tokio::test]
    async fn job_runs_to_completion_and_reports_stats() {
        let pool = setup_db().await;
        let csv = "title\n甲\n乙\n丙\n".to_string();
        let job_id = start_csv_import_job(pool.clone(), csv, "orbit".into()).unwrap();

        // 轮询到终态（最多 2s）
        let mut status = None;
        for _ in 0..200 {
            let s = csv_import_job_status(&job_id).unwrap();
            if s.finished {
                status = Some(s);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        let s = status.expect("任务应在 2s 内结束");
        assert!(s.error.is_none(), "不应有错误：{:?}", s.error);
        let stats = s.stats.expect("终态必须带统计");
        assert_eq!(stats.success, 3);
        assert_eq!(s.processed, 3, "processed 应与行数一致");
        assert!(!s.cancelled);

        let tasks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(tasks, 3, "三行都应落库");
        csv_import_job_drop(&job_id);
        assert!(
            csv_import_job_status(&job_id).is_err(),
            "drop 后任务应被清理"
        );
    }

    #[tokio::test]
    async fn job_cancel_stops_at_row_boundary() {
        let pool = setup_db().await;
        // 行数够多，确保取消能在跑完前生效
        let mut csv = String::from("title\n");
        for i in 0..5000 {
            csv.push_str(&format!("任务{i}\n"));
        }
        let job_id = start_csv_import_job(pool.clone(), csv, "orbit".into()).unwrap();

        // 等到开始有进展再取消
        for _ in 0..200 {
            let s = csv_import_job_status(&job_id).unwrap();
            if s.processed > 0 || s.finished {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        csv_import_job_cancel(&job_id).unwrap();

        let mut final_status = None;
        for _ in 0..400 {
            let s = csv_import_job_status(&job_id).unwrap();
            if s.finished {
                final_status = Some(s);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        let s = final_status.expect("取消后任务应结束");
        assert!(s.cancelled, "cancelled 标记应为真");
        let written: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        // 行边界语义：已写入的行保留（增量导入不回滚），但必须少于全量
        assert!(
            written < 5000,
            "取消应中止后续行，实写 {written} 行（不应是全量 5000）"
        );
        assert_eq!(
            written as usize, s.processed,
            "processed 必须等于实际写入行数（无半行状态）"
        );
        csv_import_job_drop(&job_id);
    }

    #[test]
    fn job_start_rejects_oversized_synchronously() {
        // 超限在 start 时同步拒绝，不让用户等到任务跑起来才看到失败
        let big = "title\n".to_string() + &"a\n".repeat(IMPORT_MAX_ROWS + 1);
        let err = futures_block_on(async {
            let pool = setup_db().await;
            start_csv_import_job(pool, big, "orbit".into())
        })
        .unwrap_err();
        assert!(err.to_string().contains("行数过多"), "{}", err);
    }

    #[test]
    fn unknown_job_id_is_not_found() {
        assert!(csv_import_job_status("import-nope").is_err());
        assert!(csv_import_job_cancel("import-nope").is_err());
        // drop 未知 id 不报错（幂等）
        csv_import_job_drop("import-nope");
    }
}
