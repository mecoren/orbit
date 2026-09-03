//! 明文数据导出 API —— 07 报告 #15「数据主权」叙事的落地
//!
//! 与 `.orsync` 加密备份（全量覆盖语义）并列的**明文**导出通道：
//! - `export_plaintext_json`：结构化 JSON 文档（8 张业务表全量，字段名
//!   与 DDL 对齐，时间戳为 Unix 秒）
//! - `export_plaintext_csv`：任务主视图 CSV（UTF-8 with BOM，Excel 直开），
//!   含项目名/标签聚合列，便于导入电子表格或第三方工具
//!
//! 安全边界：导出内容由调用方经系统保存对话框选择路径，本 API 只返回
//! 字节内容不落盘；明文导出在 PRIVACY.md §七有对用户的明示。

use std::collections::BTreeMap;

use serde::Serialize;
use sqlx::{Column, Row, SqlitePool};

use crate::db::sync_registry::SYNCABLE_TABLES;

/// 导出结果：文件内容字节 + 行统计（UI 提示用）
#[derive(Debug, Clone, Serialize)]
pub struct PlaintextExportResult {
    /// 文件内容（JSON 文本或 CSV 文本，UTF-8）
    pub content: String,
    /// 各表行数统计（表名 → 行数）
    pub table_counts: BTreeMap<String, usize>,
}

/// 读取单表全量行为 JSON 数组（列名按 DDL 原名；值转 JSON 标量）
///
/// `exclude_deleted`：true 时过滤 `is_deleted=1` 的墓碑行（明文导出
/// 的默认口径——用户导出的是"我的数据"而非同步账本）。
async fn fetch_table_rows(
    pool: &SqlitePool,
    table: &str,
    exclude_deleted: bool,
) -> sqlx::Result<Vec<serde_json::Value>> {
    // 表名来自编译期白名单常量，非用户输入，无注入面
    let sql = if exclude_deleted {
        format!("SELECT * FROM {table} WHERE is_deleted = 0")
    } else {
        format!("SELECT * FROM {table}")
    };
    let rows = sqlx::query(&sql).fetch_all(pool).await?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let mut obj = serde_json::Map::new();
        for col in row.columns() {
            let name = col.name();
            let val: serde_json::Value = match row.try_get::<Option<i64>, _>(name) {
                Ok(v) => v
                    .map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null),
                Err(_) => match row.try_get::<Option<f64>, _>(name) {
                    Ok(v) => v
                        .map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null),
                    Err(_) => match row.try_get::<Option<String>, _>(name) {
                        Ok(v) => v
                            .map(serde_json::Value::from)
                            .unwrap_or(serde_json::Value::Null),
                        Err(_) => serde_json::Value::Null,
                    },
                },
            };
            obj.insert(name.to_string(), val);
        }
        out.push(serde_json::Value::Object(obj));
    }
    Ok(out)
}

/// 导出结构化 JSON（全部 8 张业务表；默认排除墓碑行）
pub async fn export_plaintext_json(
    pool: &SqlitePool,
    exclude_deleted: bool,
) -> sqlx::Result<PlaintextExportResult> {
    let mut tables = serde_json::Map::new();
    let mut counts = BTreeMap::new();

    for table in SYNCABLE_TABLES {
        let rows = fetch_table_rows(pool, table, exclude_deleted).await?;
        counts.insert((*table).to_string(), rows.len());
        tables.insert((*table).to_string(), serde_json::Value::Array(rows));
    }

    let doc = serde_json::json!({
        "format": "orbit.plaintext-export",
        "version": 1,
        "exported_at": chrono::Utc::now().timestamp(),
        "tables": tables,
    });

    Ok(PlaintextExportResult {
        content: serde_json::to_string_pretty(&doc).expect("JSON 序列化不可失败"),
        table_counts: counts,
    })
}

/// CSV 任务主视图列定义（列名同时是 CSV 头）
const CSV_COLUMNS: &[&str] = &[
    "id",
    "title",
    "project",
    "labels",
    "priority",
    "status",
    "done",
    "done_at",
    "due_date",
    "start_date",
    "end_date",
    "percent_done",
    "description",
    "created_at",
    "updated_at",
];

/// RFC 4180 CSV 字段转义：含分隔符/引号/换行时加引号并双写引号
pub fn csv_escape(field: &str) -> String {
    if field.contains(',') || field.contains('"') || field.contains('\n') || field.contains('\r') {
        format!("\"{}\"", field.replace('"', "\"\""))
    } else {
        field.to_string()
    }
}

/// 导出任务主视图 CSV（默认排除墓碑行；含项目名与标签聚合列）
pub async fn export_plaintext_csv(
    pool: &SqlitePool,
    exclude_deleted: bool,
) -> sqlx::Result<PlaintextExportResult> {
    // 项目 id → title 映射（含已删除项目：任务仍引用其 id 时应显示标题而非空）
    let projects: Vec<(i64, String)> = sqlx::query("SELECT id, title FROM todo_projects")
        .fetch_all(pool)
        .await?
        .iter()
        .map(|r| (r.get::<i64, _>("id"), r.get::<String, _>("title")))
        .collect();
    let project_title: BTreeMap<i64, String> =
        projects.iter().map(|(id, t)| (*id, t.clone())).collect();

    // 标签关联：task_id → "标签A;标签B"（分号分隔，避开 CSV 逗号）
    let label_rows: Vec<(i64, String)> = sqlx::query(
        "SELECT tl.task_id AS task_id, l.title AS title \
         FROM todo_task_labels tl JOIN todo_labels l ON l.id = tl.label_id \
         WHERE tl.is_deleted = 0 AND l.is_deleted = 0",
    )
    .fetch_all(pool)
    .await?
    .iter()
    .map(|r| (r.get::<i64, _>("task_id"), r.get::<String, _>("title")))
    .collect();
    let mut task_labels: BTreeMap<i64, Vec<String>> = BTreeMap::new();
    for (task_id, title) in label_rows {
        task_labels.entry(task_id).or_default().push(title);
    }

    // 任务行（可选墓碑过滤）
    let sql = if exclude_deleted {
        "SELECT * FROM todo_tasks WHERE is_deleted = 0"
    } else {
        "SELECT * FROM todo_tasks"
    };
    let rows = sqlx::query(sql).fetch_all(pool).await?;

    // UTF-8 BOM：Excel 直接双击打开中文不乱码
    let mut out = String::from("\u{feff}");
    out.push_str(&CSV_COLUMNS.join(","));
    out.push('\n');

    for row in &rows {
        let id: i64 = row.get("id");
        let title: String = row.get("title");
        let project_id: Option<i64> = row.get("project_id");
        let priority: i64 = row.get("priority");
        let status: String = row.get("status");
        let done: i64 = row.get("done");
        let done_at: Option<i64> = row.get("done_at");
        let due_date: Option<i64> = row.get("due_date");
        let start_date: Option<i64> = row.get("start_date");
        let end_date: Option<i64> = row.get("end_date");
        let percent_done: f64 = row.get("percent_done");
        let description: Option<String> = row.get("description");
        let created_at: i64 = row.get("created_at");
        let updated_at: i64 = row.get("updated_at");

        let project = project_id
            .and_then(|pid| project_title.get(&pid))
            .cloned()
            .unwrap_or_default();
        let labels = task_labels
            .get(&id)
            .map(|v| v.join(";"))
            .unwrap_or_default();

        let fields = [
            id.to_string(),
            title,
            project,
            labels,
            priority.to_string(),
            status,
            done.to_string(),
            done_at.map(|v| v.to_string()).unwrap_or_default(),
            due_date.map(|v| v.to_string()).unwrap_or_default(),
            start_date.map(|v| v.to_string()).unwrap_or_default(),
            end_date.map(|v| v.to_string()).unwrap_or_default(),
            percent_done.to_string(),
            description.unwrap_or_default(),
            created_at.to_string(),
            updated_at.to_string(),
        ];
        let line: Vec<String> = fields.iter().map(|f| csv_escape(f)).collect();
        out.push_str(&line.join(","));
        out.push('\n');
    }

    let mut counts = BTreeMap::new();
    counts.insert("todo_tasks".to_string(), rows.len());
    for t in SYNCABLE_TABLES.iter().filter(|t| **t != "todo_tasks") {
        counts.insert(
            (*t).to_string(),
            fetch_table_rows(pool, t, exclude_deleted).await?.len(),
        );
    }

    Ok(PlaintextExportResult {
        content: out,
        table_counts: counts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 迁移后的内存库（复用 import_api 的模式）
    async fn setup_migrated_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 种子：迁移自带「收件箱」项目（id=1）；追加 1 项目（id=2）/ 2 任务
    /// （id=2 存活、id=3 墓碑）/ 1 子任务 / 2 标签 + 关联 / 1 评论 / 1 提醒
    async fn seed(pool: &SqlitePool) {
        sqlx::query(
            "INSERT INTO todo_projects (id, title, hex_color) VALUES (2, '工作', '#3B82F6')",
        )
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO todo_tasks (id, uuid, title, project_id, priority, status, done, description, created_at, updated_at) \
             VALUES (2, 'seed-task-a', '买牛奶', 2, 2, 'pending', 0, '低脂', 100, 200), \
                    (3, 'seed-task-b', '已删除任务', 2, 0, 'pending', 0, NULL, 100, 200)",
        )
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1, deleted_at = 300 WHERE id = 3")
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO todo_subtasks (task_id, title, done) VALUES (2, '去超市', 0)")
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO todo_labels (id, uuid, title, hex_color) VALUES (3, 'seed-label-a', 'errand', '#6B7280'), (4, 'seed-label-b', '购物', '#FF0000')")
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO todo_task_labels (task_id, label_id, uuid) VALUES (2, 3, 'seed-tl-a'), (2, 4, 'seed-tl-b')")
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO todo_comments (task_id, content) VALUES (2, '备注, 含逗号')")
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO todo_reminders (task_id, remind_at) VALUES (2, 500)")
            .execute(pool)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn json_export_excludes_tombstones_by_default() {
        let pool = setup_migrated_db().await;
        seed(&pool).await;

        let result = export_plaintext_json(&pool, true).await.unwrap();
        assert_eq!(result.table_counts.get("todo_tasks"), Some(&1));
        assert_eq!(result.table_counts.get("todo_projects"), Some(&2)); // 收件箱 + 工作
        assert_eq!(result.table_counts.get("todo_subtasks"), Some(&1));
        assert_eq!(result.table_counts.get("todo_labels"), Some(&2));
        assert_eq!(result.table_counts.get("todo_task_labels"), Some(&2));
        assert_eq!(result.table_counts.get("todo_comments"), Some(&1));
        assert_eq!(result.table_counts.get("todo_reminders"), Some(&1));
        // 空表也在列（结构完整性）
        assert_eq!(result.table_counts.get("todo_task_relations"), Some(&0));

        let doc: serde_json::Value = serde_json::from_str(&result.content).unwrap();
        assert_eq!(doc["format"], "orbit.plaintext-export");
        assert_eq!(doc["version"], 1);
        assert_eq!(doc["tables"]["todo_tasks"].as_array().unwrap().len(), 1);
        assert_eq!(doc["tables"]["todo_tasks"][0]["title"], "买牛奶");
        // 墓碑任务不出现在默认导出
        let titles: Vec<&str> = doc["tables"]["todo_tasks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["title"].as_str().unwrap())
            .collect();
        assert!(!titles.contains(&"已删除任务"));
    }

    #[tokio::test]
    async fn json_export_can_include_tombstones() {
        let pool = setup_migrated_db().await;
        seed(&pool).await;

        let result = export_plaintext_json(&pool, false).await.unwrap();
        assert_eq!(result.table_counts.get("todo_tasks"), Some(&2));
    }

    #[tokio::test]
    async fn csv_export_has_bom_header_and_enriched_columns() {
        let pool = setup_migrated_db().await;
        seed(&pool).await;

        let result = export_plaintext_csv(&pool, true).await.unwrap();
        let content = &result.content;
        // UTF-8 BOM
        assert!(content.starts_with('\u{feff}'));
        // 表头
        let first_line = content
            .trim_start_matches('\u{feff}')
            .lines()
            .next()
            .unwrap();
        assert!(first_line.contains("id,title,project,labels"));
        assert!(first_line.contains("due_date,start_date,end_date"));
        assert!(first_line.contains(",description,created_at"));
        // 数据行：项目名聚合 + 标签分号聚合
        let data_line = content.lines().nth(1).unwrap();
        assert!(data_line.contains("买牛奶"));
        assert!(data_line.contains("工作"));
        // 两个标签分号聚合
        assert!(data_line.contains("errand;购物"));
        // 墓碑排除
        assert!(!content.contains("已删除任务"));
    }

    #[tokio::test]
    async fn csv_export_escapes_commas_quotes_and_newlines() {
        let pool = setup_migrated_db().await;
        seed(&pool).await;

        // 标题字段含逗号与引号 → 触发 RFC 4180 转义（整字段加引号 + 引号双写）
        sqlx::query("UPDATE todo_tasks SET title = '含,逗号\"引号' WHERE id = 2")
            .execute(&pool)
            .await
            .unwrap();
        let result = export_plaintext_csv(&pool, true).await.unwrap();
        assert!(result.content.contains("\"含,逗号\"\"引号\""));
    }

    #[test]
    fn csv_escape_rfc4180() {
        assert_eq!(csv_escape("plain"), "plain");
        assert_eq!(csv_escape("a,b"), "\"a,b\"");
        assert_eq!(csv_escape("say \"hi\""), "\"say \"\"hi\"\"\"");
        assert_eq!(csv_escape("line\nbreak"), "\"line\nbreak\"");
    }

    #[tokio::test]
    async fn empty_db_exports_valid_empty_documents() {
        let pool = setup_migrated_db().await;
        let json = export_plaintext_json(&pool, true).await.unwrap();
        assert_eq!(json.table_counts.get("todo_tasks"), Some(&0));
        let csv = export_plaintext_csv(&pool, true).await.unwrap();
        // 仅 BOM + 头行
        assert_eq!(csv.content.lines().count(), 1);
    }
}
