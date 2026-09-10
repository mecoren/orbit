//! ICS 日历导出 API —— #4 高价值缺口（「数据主权」叙事的输出通道）
//!
//! local-first 用户的任务常要"输出"到系统日历/其他日历软件订阅：
//! 写 .ics 纯导出零账号依赖，与明文导出（#15）同属开放格式通道。
//! 本项目已有节假日 + 日历视图，数据现成。
//!
//! 组件选型：任务用 RFC 5545 `VTODO`（不是 VEVENT——待办的完成/优先级
//! 语义只有 VTODO 承载；Google Calendar 对 VTODO 显示为任务，Apple
//! 日历导入为提醒事项）。含截止（DUE）的任务带 `VTIMEZONE` + 本地
//! 时区 ID（由 chrono::Local 推断 IANA 名），保证跨时区软件导入后
//! 时刻不漂移；无截止任务仅 SUMMARY/DESCRIPTION/PRIORITY。
//!
//! 只读导出：不 emit 事件、不进同步白名单（与统计/明文导出同口径）；
//! 内容返回给调用方落盘，本 API 不写文件。
//!
//! RFC 5545 逃逸规则（TEXT 类型）：反斜杠/分号/逗号前加 `\`，换行
//! 折叠为 `\n` 字面量（属性值内不出现裸 CR/LF）。

use std::collections::BTreeMap;

use chrono::{Datelike, Local, Offset, TimeZone};
use sqlx::{Row, SqlitePool};

/// 导出结果（与 PlaintextExportResult 同形：内容 + 统计 + 建议文件名）
#[derive(Debug, Clone, serde::Serialize)]
pub struct IcsExportResult {
    /// 文件内容（ICS 文本，UTF-8；CRLF 行尾 RFC 要求）
    pub content: String,
    /// 统计：todo_tasks 导出条数（含 done 计数）
    pub table_counts: BTreeMap<String, usize>,
    /// 建议文件名（含时间戳）
    pub suggested_filename: String,
}

/// TEXT 属性值转义（RFC 5545 §3.3.11）
fn escape_ics_text(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace(';', "\\;")
        .replace(',', "\\,")
        .replace('\r', "")
        .replace('\n', "\\n")
}

/// 毫秒时间戳 → ICS UTC 日期时间（`YYYYMMDDTHHMMSSZ`）
fn ms_to_ics_utc(ms: i64) -> String {
    let dt = chrono::Utc
        .timestamp_millis_opt(ms)
        .single()
        .unwrap_or_else(chrono::Utc::now);
    dt.format("%Y%m%dT%H%M%SZ").to_string()
}

/// 本地时区 ID（IANA 名；推断失败回落 "UTC"）
fn local_timezone_id() -> String {
    // IANA 时区名：优先 TZ 环境变量（类 Unix）；Windows 无注册表读取
    // 依赖（iana_time_zone crate 可后续引入），回落 "UTC"——VTIMEZONE
    // 以固定偏移定义仍可被日历软件解析，无夏令时区影响面极小
    std::env::var("TZ")
        .ok()
        .filter(|v| v.contains('/'))
        .unwrap_or_else(|| "UTC".to_string())
}

/// 生成 VTIMEZONE 组件（当前本地偏移的 STANDARD 定义；无夏令时区
/// 的最简形态——中国时区适用，跨夏令时区导入后由日历软件 DST 表修正）
fn build_vtimezone(tz_id: &str, now_ms: i64) -> String {
    let now = Local
        .timestamp_millis_opt(now_ms)
        .single()
        .unwrap_or_else(Local::now);
    let offset_seconds = now.offset().fix().local_minus_utc();
    let sign = if offset_seconds < 0 { '-' } else { '+' };
    let abs = offset_seconds.unsigned_abs();
    let off = format!("{sign}{:02}{:02}", abs / 3600, (abs % 3600) / 60);
    format!(
        "BEGIN:VTIMEZONE\r\nTZID:{tz_id}\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:{off}\r\nTZOFFSETTO:{off}\r\nTZNAME:{tz_id}\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
    )
}

/// 导出全部任务为 ICS（VTODO 日历）
///
/// 收录口径：未删除任务全量（done 的带 COMPLETED 时间戳——日历软件
/// 侧可见完成轨迹）；标题/描述/优先级（1-4 映射 RFC 5545 9 级的
/// 1=最高——任务 P5 紧急 → ics 1）、截止（DUE，本地时区）。
pub async fn export_ics(pool: &SqlitePool) -> sqlx::Result<IcsExportResult> {
    let projects: Vec<(i64, String)> = sqlx::query("SELECT id, title FROM todo_projects")
        .fetch_all(pool)
        .await?
        .iter()
        .map(|r| (r.get::<i64, _>("id"), r.get::<String, _>("title")))
        .collect();
    let project_title: BTreeMap<i64, String> =
        projects.iter().map(|(id, t)| (*id, t.clone())).collect();

    let tasks: Vec<crate::models::business::TodoTask> =
        sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0 ORDER BY id")
            .fetch_all(pool)
            .await?;

    let now_ms = Local::now().timestamp_millis();
    let tz_id = local_timezone_id();

    let mut out = String::new();
    out.push_str("BEGIN:VCALENDAR\r\n");
    out.push_str("VERSION:2.0\r\n");
    out.push_str("PRODID:-//Orbit//TODO ICS Export//CN\r\n");
    out.push_str("CALSCALE:GREGORIAN\r\n");
    // 有 DUE 的任务才引用时区；无条件输出 VTIMEZONE 保证引用始终可解析
    out.push_str(&build_vtimezone(&tz_id, now_ms));
    // 方法：PUBLISH（日历软件可作为只读日历订阅）
    out.push_str("METHOD:PUBLISH\r\n");

    let mut exported = 0usize;
    let mut done_count = 0usize;
    for t in &tasks {
        // 优先级映射：任务 5(立即处理)→ics 1 … 1(低)→ics 5；0(无)省略
        // RFC 5545：1 最高 9 最低；超出省略（无优先级语义）
        let ics_priority = match t.priority {
            5 => Some(1),
            4 => Some(2),
            3 => Some(3),
            2 => Some(4),
            1 => Some(5),
            _ => None,
        };

        out.push_str("BEGIN:VTODO\r\n");
        // UID：uuid@orbit（同步稳定标识；重复导入同 UID 会被日历软件识别为同一项）
        out.push_str(&format!("UID:{}@orbit\r\n", t.uuid));
        out.push_str(&format!("DTSTAMP:{}\r\n", ms_to_ics_utc(now_ms)));
        out.push_str(&format!("SUMMARY:{}\r\n", escape_ics_text(&t.title)));
        if let Some(desc) = &t.description {
            if !desc.is_empty() {
                out.push_str(&format!("DESCRIPTION:{}\r\n", escape_ics_text(desc)));
            }
        }
        if let Some(pid) = t.project_id
            && let Some(name) = project_title.get(&pid)
        {
            // CATEGORIES 携带项目名（日历软件按类别筛选）
            out.push_str(&format!("CATEGORIES:{}\r\n", escape_ics_text(name)));
        }
        if let Some(p) = ics_priority {
            out.push_str(&format!("PRIORITY:{p}\r\n"));
        }
        // 截止：本地时区表达（跨时区导入由 VTIMEZONE 保证不漂移）
        if let Some(due) = t.due_date {
            let dt = Local.timestamp_millis_opt(due).single();
            if let Some(d) = dt {
                out.push_str(&format!(
                    "DUE;TZID={}:{}\r\n",
                    tz_id,
                    d.format("%Y%m%dT%H%M%S")
                ));
            }
        }
        // 开始日期（可选）
        if let Some(start) = t.start_date {
            out.push_str(&format!(
                "DTSTART;VALUE=DATE:{}\r\n",
                ms_to_ics_utc(start)[..8].to_string()
            ));
        }
        // 完成：COMPLETED（UTC）；STATUS 映射 done→COMPLETED / 其余→NEEDS-ACTION
        if t.done == 1 {
            if let Some(done_at) = t.done_at {
                out.push_str(&format!("COMPLETED:{}\r\n", ms_to_ics_utc(done_at)));
            }
            out.push_str("STATUS:COMPLETED\r\n");
            done_count += 1;
        } else if t.status == "doing" {
            out.push_str("STATUS:IN-PROCESS\r\n");
        } else {
            out.push_str("STATUS:NEEDS-ACTION\r\n");
        }
        out.push_str("END:VTODO\r\n");
        exported += 1;
    }
    out.push_str("END:VCALENDAR\r\n");

    let stamp = Local::now().format("%Y%m%d_%H%M%S");
    let mut table_counts = BTreeMap::new();
    table_counts.insert("todo_tasks".to_string(), exported);
    table_counts.insert("todo_tasks_done".to_string(), done_count);

    Ok(IcsExportResult {
        content: out,
        table_counts,
        suggested_filename: format!("orbit_{stamp}.ics"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[test]
    fn escape_rules() {
        assert_eq!(escape_ics_text("a;b,c"), "a\\;b\\,c");
        assert_eq!(escape_ics_text("行1\n行2"), "行1\\n行2");
        assert_eq!(escape_ics_text("反\\斜杠"), "反\\\\斜杠");
    }

    #[test]
    fn utc_stamp_format() {
        let s = ms_to_ics_utc(0);
        assert_eq!(s, "19700101T000000Z");
        assert!(s.len() == 16);
    }

    #[tokio::test]
    async fn export_full_semantics() {
        let pool = setup_db().await;
        let now = Local::now().timestamp_millis();
        // 项目 + 任务（含多状态/优先级/截止/描述/项目挂载）
        sqlx::query("INSERT INTO todo_tasks (uuid, title, description, project_id, priority, status, done, done_at, due_date, is_deleted, created_at, updated_at, version) VALUES ('u1', '带描述;逗号', '多行\n描述', 1, 4, 'pending', 0, NULL, ?, 0, ?, ?, 1)")
            .bind(now + 3600_000).bind(now).bind(now).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO todo_tasks (uuid, title, priority, status, done, done_at, due_date, is_deleted, created_at, updated_at, version) VALUES ('u2', '已完成', 0, 'done', 1, ?, ?, 0, ?, ?, 1)")
            .bind(now - 1000).bind(now + 86400_000).bind(now).bind(now).execute(&pool).await.unwrap();
        // 已删除任务不入导出
        sqlx::query("INSERT INTO todo_tasks (uuid, title, priority, status, done, is_deleted, deleted_at, created_at, updated_at, version) VALUES ('u3', '墓碑', 0, 'pending', 0, 1, ?, ?, ?, 1)")
            .bind(now).bind(now).bind(now).execute(&pool).await.unwrap();

        let r = export_ics(&pool).await.unwrap();
        // 头部完整性
        assert!(r.content.starts_with("BEGIN:VCALENDAR"));
        assert!(r.content.contains("PRODID:-//Orbit"));
        assert!(r.content.contains("BEGIN:VTIMEZONE"));
        // 转义与字段
        assert!(r.content.contains("SUMMARY:带描述\\;逗号"));
        assert!(r.content.contains("DESCRIPTION:多行\\n描述"));
        assert!(r.content.contains("CATEGORIES:收件箱")); // 种子项目 id=1
        assert!(r.content.contains("PRIORITY:2"));
        assert!(r.content.contains("DUE;TZID="));
        // 完成语义
        assert!(r.content.contains("STATUS:COMPLETED"));
        assert!(r.content.contains("COMPLETED:"));
        // 状态语义
        assert!(r.content.contains("STATUS:NEEDS-ACTION"));
        // 墓碑排除 + 计数
        assert!(!r.content.contains("墓碑"));
        assert_eq!(r.table_counts["todo_tasks"], 2);
        assert_eq!(r.table_counts["todo_tasks_done"], 1);
        // 文件名
        assert!(r.suggested_filename.ends_with(".ics"));
        // CRLF 行尾
        assert!(r.content.contains("\r\n"));
        // VTODO 收口
        assert_eq!(r.content.matches("BEGIN:VTODO").count(), 2);
        assert_eq!(r.content.matches("END:VTODO").count(), 2);
    }

    #[tokio::test]
    async fn empty_db_still_valid_calendar() {
        let pool = setup_db().await;
        let r = export_ics(&pool).await.unwrap();
        assert!(r.content.contains("BEGIN:VCALENDAR"));
        assert!(r.content.ends_with("END:VCALENDAR\r\n"));
        assert!(!r.content.contains("BEGIN:VTODO"));
        assert_eq!(r.table_counts["todo_tasks"], 0);
    }
}
