//! ICS 文件导入 API —— D6（只吃 VTODO）
//!
//! 与 ICS 导出（ics_export_api）对称的**导入方向**：把别处（或自家导出）的
//! `.ics` 日历文件搬回任务库。刻意只做文件导入，不做入站订阅/CalDAV
//! （第五轮 §五已否决：网络轮询 + 外部凭据；本项与 CSV 导入同一权限面）。
//!
//! 设计（便宜的原因）：
//! - 解析产物直接喂 `CsvImportRow`（来源无关 IR），`execute_csv_import`
//!   的逐行写入 + 项目自动创建 + 大小写去重逻辑原样复用；
//! - 预设走既有字符串键：`csv_import_preview/execute` 传 `preset="ics"`
//!   即接通，零新命令、零 DTO/FRB/mock 镜像链改动；
//! - 只认 `VTODO`：`VEVENT`（日历事件）不是待办，无时间语义映射规则，不做；
//! - 零新 crate：RFC 5545 的 unfold（CRLF + 空白续行）与 TEXT 转义的手写
//!   逆函数即可（`ical` 会拖进 nom/idna，为解析自家写导出的格式不值）。
//!
//! 字段映射（导出函数的精确逆）：
//! - SUMMARY → title（空标题跳过）；DESCRIPTION → description；
//! - CATEGORIES → project_title（执行侧自动建项目，去重不惧重复导入）；
//! - PRIORITY 1→5 … 5→1（与导出同表），6-9/缺失/非法 → 0（无）；
//! - DUE（`YYYYMMDD`/`YYYYMMDDTHHMMSS` 本地、`...Z` UTC）→ due_date；
//! - DTSTART;VALUE=DATE → start_date（本地零点）；
//! - STATUS:COMPLETED → done=1（COMPLETED 时间戳 → done_at），
//!   IN-PROCESS → doing，其余 → pending。

use chrono::{Local, TimeZone, Utc};

use crate::api::csv_import_api::CsvImportRow;
use crate::error::CoreResult;
use crate::models::business::TodoTaskCreateInput;

// ============================================================================
// RFC 5545 行展开与 TEXT 反转义
// ============================================================================

/// 行展开：CRLF（容忍裸 LF）后紧跟空格/TAB 的续行拼回上一行。
pub fn unfold_ics(content: &str) -> Vec<String> {
    let normalized = content.replace("\r\n", "\n").replace('\r', "\n");
    let mut out: Vec<String> = Vec::new();
    for raw in normalized.split('\n') {
        if raw.is_empty() {
            continue;
        }
        if let Some(first) = raw.chars().next()
            && (first == ' ' || first == '\t')
            && !out.is_empty()
        {
            // 续行：去掉首个空白字符后拼回（UTF-8 按字符切，不按字节）
            let cont = &raw[first.len_utf8()..];
            if let Some(last) = out.last_mut() {
                last.push_str(cont);
            }
        } else {
            out.push(raw.to_string());
        }
    }
    out
}

/// TEXT 反转义（`ics_export_api::escape_ics_text` 的精确逆函数）。
///
/// 导出侧顺序：`\`→`\\` 先行，故 `\\n` 字面量在原文是反斜杠+n；
/// 此处必须逐字符扫描（链式 replace 会把 `\\n` 先误读成换行）。
pub fn unescape_ics_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') | Some('N') => out.push('\n'),
            Some('\\') => out.push('\\'),
            Some(';') => out.push(';'),
            Some(',') => out.push(','),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

// ============================================================================
// VTODO → CsvImportRow
// ============================================================================

/// 内容行拆分：第一个 `:` 左为名（含参数），右为值（值内冒号合法，TEXT 不转义冒号）。
fn split_content_line(line: &str) -> Option<(&str, &str)> {
    let idx = line.find(':')?;
    Some((&line[..idx], &line[idx + 1..]))
}

/// 属性名去掉参数（`DUE;TZID=X` → `DUE`），大小写不敏感比较用大写。
fn prop_name(field: &str) -> &str {
    field.split(';').next().unwrap_or(field)
}

/// ICS 日期时间 → 毫秒时间戳。
///
/// - `YYYYMMDD` → 本地零点；
/// - `YYYYMMDDTHHMMSS` → 本地时刻（导出侧 DUE 口径）；
/// - `YYYYMMDDTHHMMSSZ` → UTC 瞬时。
fn parse_ics_datetime(value: &str) -> Option<i64> {
    let v = value.trim();
    if v.len() == 8 {
        let date = chrono::NaiveDate::parse_from_str(v, "%Y%m%d").ok()?;
        return Local
            .from_local_datetime(&date.and_hms_opt(0, 0, 0)?)
            .single()
            .map(|d| d.timestamp_millis());
    }
    if let Some(stripped) = v.strip_suffix('Z')
        && stripped.len() == 15
    {
        let dt = chrono::NaiveDateTime::parse_from_str(stripped, "%Y%m%dT%H%M%S").ok()?;
        return Some(Utc.from_utc_datetime(&dt).timestamp_millis());
    }
    if v.len() == 15 {
        let dt = chrono::NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S").ok()?;
        return Local
            .from_local_datetime(&dt)
            .single()
            .map(|d| d.timestamp_millis());
    }
    None
}

/// PRIORITY 逆映射（导出表：任务 5→ics 1 … 1→ics 5；0 省略）。
fn priority_from_ics(value: &str) -> Option<i32> {
    match value.trim() {
        "1" => Some(5),
        "2" => Some(4),
        "3" => Some(3),
        "4" => Some(2),
        "5" => Some(1),
        _ => Some(0),
    }
}

/// ICS 内容 → 待导入行（只收 VTODO；VEVENT 等其余组件整块忽略）。
pub fn map_ics_rows(content: &str) -> CoreResult<Vec<CsvImportRow>> {
    let lines = unfold_ics(content);
    let mut out = Vec::new();
    let mut in_vtodo = false;
    let mut props: Vec<(String, String)> = Vec::new();
    // source_line 用 VTODO 块序号（文件行号经 unfold 已错位，块序号更诚实）
    let mut block_no = 0usize;

    // 显式 finish（字段缺失返回默认值，不做 ? 传播——单块坏不阻断整文件）
    let finish_block =
        |props: &[(String, String)], block_no: usize, out: &mut Vec<CsvImportRow>| {
            let get = |name: &str| {
                props
                    .iter()
                    .rev()
                    .find(|(k, _)| prop_name(k).eq_ignore_ascii_case(name))
                    .map(|(_, v)| v.as_str())
            };
            let Some(summary) = get("SUMMARY").map(unescape_ics_text) else {
                out.push(CsvImportRow {
                    source_line: block_no,
                    project_title: None,
                    input: TodoTaskCreateInput::default(),
                    skip_reason: Some("VTODO 无 SUMMARY".into()),
                });
                return;
            };
            if summary.trim().is_empty() {
                out.push(CsvImportRow {
                    source_line: block_no,
                    project_title: None,
                    input: TodoTaskCreateInput::default(),
                    skip_reason: Some("标题为空".into()),
                });
                return;
            }
            let status = get("STATUS").unwrap_or("NEEDS-ACTION").to_ascii_uppercase();
            let (done, status_out, done_at) = match status.as_str() {
                "COMPLETED" => (
                    Some(1),
                    Some("done".to_string()),
                    get("COMPLETED").and_then(parse_ics_datetime),
                ),
                "IN-PROCESS" => (Some(0), Some("doing".to_string()), None),
                _ => (Some(0), Some("pending".to_string()), None),
            };
            out.push(CsvImportRow {
                source_line: block_no,
                project_title: get("CATEGORIES").map(unescape_ics_text),
                input: TodoTaskCreateInput {
                    title: summary,
                    description: get("DESCRIPTION").map(unescape_ics_text),
                    priority: get("PRIORITY").and_then(priority_from_ics),
                    done,
                    done_at,
                    due_date: get("DUE").and_then(parse_ics_datetime),
                    start_date: get("DTSTART").and_then(parse_ics_datetime),
                    status: status_out,
                    ..Default::default()
                },
                skip_reason: None,
            });
        };

    for line in &lines {
        let Some((field, value)) = split_content_line(line) else {
            continue;
        };
        let upper = field.to_ascii_uppercase();
        if upper == "BEGIN" && value.eq_ignore_ascii_case("VTODO") {
            in_vtodo = true;
            props.clear();
            block_no += 1;
            continue;
        }
        if upper == "END" && value.eq_ignore_ascii_case("VTODO") {
            if in_vtodo {
                in_vtodo = false;
                finish_block(&props, block_no, &mut out);
                props.clear();
            }
            continue;
        }
        if in_vtodo {
            props.push((field.to_string(), value.to_string()));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unfold_joins_continuation_lines() {
        let content = "SUMMARY:第一行\r\n 第二行\r\n\t第三行\r\nDUE:20260919\r\n";
        let lines = unfold_ics(content);
        assert_eq!(lines, vec!["SUMMARY:第一行第二行第三行", "DUE:20260919"]);
    }

    #[test]
    fn unescape_is_exact_inverse_of_export() {
        // 导出转义：`\`→`\\`、`;`→`\;`、`,`→`\,`、换行→`\n`
        assert_eq!(unescape_ics_text("a\\\\b"), "a\\b");
        assert_eq!(unescape_ics_text("a\\;b\\,c"), "a;b,c");
        assert_eq!(unescape_ics_text("line1\\nline2"), "line1\nline2");
        // `\\n`（反斜杠+n）不得误读成换行：链式 replace 会错，扫描器才对
        assert_eq!(unescape_ics_text("C:\\\\new"), "C:\\new");
    }

    #[test]
    fn split_keeps_colons_in_value() {
        // DESCRIPTION 值内冒号合法（TEXT 不转义冒号），必须按首个冒号切
        assert_eq!(
            split_content_line("DESCRIPTION:12:30 开会"),
            Some(("DESCRIPTION", "12:30 开会"))
        );
        assert_eq!(
            split_content_line("DUE;TZID=Asia/Shanghai:20260919T180000"),
            Some(("DUE;TZID=Asia/Shanghai", "20260919T180000"))
        );
    }

    #[test]
    fn parses_full_vtodo_block() {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\
            BEGIN:VTODO\r\nUID:abc@orbit\r\n\
            SUMMARY:买牛奶\\, 全脂\r\nDESCRIPTION:超市\\n二楼\r\n\
            CATEGORIES:生活\r\nPRIORITY:3\r\nDUE:20260919\r\n\
            STATUS:NEEDS-ACTION\r\nEND:VTODO\r\n\
            BEGIN:VEVENT\r\nSUMMARY:日历事件不导入\r\nEND:VEVENT\r\n\
            END:VCALENDAR\r\n";
        let rows = map_ics_rows(ics).unwrap();
        // VEVENT 整块忽略，只收 1 行 VTODO
        assert_eq!(rows.len(), 1);
        let r = &rows[0];
        assert!(r.skip_reason.is_none());
        assert_eq!(r.input.title, "买牛奶, 全脂");
        assert_eq!(r.input.description.as_deref(), Some("超市\n二楼"));
        assert_eq!(r.project_title.as_deref(), Some("生活"));
        assert_eq!(r.input.priority, Some(3));
        assert_eq!(r.input.status.as_deref(), Some("pending"));
        assert!(r.input.due_date.is_some());
    }

    #[test]
    fn completed_maps_done_and_done_at() {
        let ics = "BEGIN:VTODO\r\nSUMMARY:已完成\r\nSTATUS:COMPLETED\r\n\
            COMPLETED:20260918T120000Z\r\nEND:VTODO\r\n";
        let rows = map_ics_rows(ics).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].input.done, Some(1));
        assert_eq!(rows[0].input.status.as_deref(), Some("done"));
        assert!(rows[0].input.done_at.is_some());
    }

    #[test]
    fn missing_or_empty_summary_skips() {
        let no_summary = "BEGIN:VTODO\r\nDUE:20260919\r\nEND:VTODO\r\n";
        let rows = map_ics_rows(no_summary).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].skip_reason.is_some());
        let empty = "BEGIN:VTODO\r\nSUMMARY:   \r\nEND:VTODO\r\n";
        let rows = map_ics_rows(empty).unwrap();
        assert!(rows[0].skip_reason.is_some());
    }

    #[test]
    fn priority_inverse_table_matches_export() {
        // 导出：任务 5→1 … 1→5；导入逆回去；6-9/非法→0
        for (ics, orbit) in [("1", 5), ("2", 4), ("3", 3), ("4", 2), ("5", 1)] {
            assert_eq!(priority_from_ics(ics), Some(orbit));
        }
        for ics in ["0", "6", "9", "high", ""] {
            assert_eq!(priority_from_ics(ics), Some(0));
        }
    }

    #[test]
    fn datetime_forms_parse() {
        assert!(parse_ics_datetime("20260919").is_some());
        assert!(parse_ics_datetime("20260919T180000").is_some());
        assert!(parse_ics_datetime("20260919T100000Z").is_some());
        assert!(parse_ics_datetime("not-a-date").is_none());
    }
}
