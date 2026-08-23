//! import_type_validator — 导入字段类型规范化
//!
//! 在通用 JSON 写入路径之前，根据目标表的 `PRAGMA table_info` 声明类型
//! 对字段值进行校验/转换，防止字符串值被存入 INTEGER 列等类型不匹配问题。

use serde_json::Value;
use sqlx::{Row, SqlitePool};
use std::collections::HashMap;

use crate::error::{CoreError, CoreResult};

/// 列声明类型（SQLite affinity 的简化抽象）
#[derive(Debug, Clone, PartialEq)]
pub enum ColumnSqlType {
    /// INTEGER / INT / BIGINT / SMALLINT …
    Integer,
    /// REAL / FLOAT / DOUBLE …
    Real,
    /// TEXT / VARCHAR / CHAR / NUMERIC / DATETIME …
    Text,
    /// BLOB（按字符串/JSON 处理）
    Blob,
}

/// 列元数据
#[derive(Debug, Clone)]
pub struct ColumnMeta {
    pub name: String,
    pub sql_type: ColumnSqlType,
    pub not_null: bool,
    pub dflt_value: Option<String>,
}

/// 将 SQLite 声明类型字符串解析为 ColumnSqlType
fn parse_sql_type(type_str: Option<&str>) -> ColumnSqlType {
    let s = type_str.unwrap_or("TEXT").trim().to_uppercase();
    if s.contains("INT") {
        ColumnSqlType::Integer
    } else if s.contains("REAL")
        || s.contains("FLOAT")
        || s.contains("DOUBLE")
        || s.contains("NUMERIC") && s != "DATETIME"
    {
        ColumnSqlType::Real
    } else if s.contains("BLOB") {
        ColumnSqlType::Blob
    } else {
        // TEXT / VARCHAR / CHAR / DATETIME / 空类型 统一按 Text 处理
        ColumnSqlType::Text
    }
}

/// 读取目标表列元数据（在事务中使用可变连接）
///
/// 表名由调用方保证安全（已通过白名单校验）。
pub async fn load_table_columns_in_tx(
    conn: &mut sqlx::SqliteConnection,
    table: &str,
) -> CoreResult<HashMap<String, ColumnMeta>> {
    crate::db::repository::generic_repo::validate_column_name(table)?;

    let sql = format!("PRAGMA table_info(\"{}\")", table);
    let rows = sqlx::query(&sql).fetch_all(conn).await?;

    let mut map = HashMap::with_capacity(rows.len());
    for row in rows {
        let name: String = row.try_get("name")?;
        let type_str: Option<String> = row.try_get("type")?;
        let not_null: bool = row.try_get::<i32, _>("notnull")? != 0;
        let dflt_value: Option<String> = row.try_get("dflt_value")?;
        let sql_type = parse_sql_type(type_str.as_deref());
        map.insert(
            name.clone(),
            ColumnMeta {
                name,
                sql_type,
                not_null,
                dflt_value,
            },
        );
    }
    Ok(map)
}

/// 读取目标表列元数据
///
/// 表名由调用方保证安全（已通过白名单校验）。
pub async fn load_table_columns(
    pool: &SqlitePool,
    table: &str,
) -> CoreResult<HashMap<String, ColumnMeta>> {
    let mut conn = pool.acquire().await?;
    load_table_columns_in_tx(&mut conn, table).await
}

/// 判断列是否为 INTEGER 类型的时间戳语义列
fn is_timestamp_column(name: &str, sql_type: &ColumnSqlType) -> bool {
    matches!(sql_type, ColumnSqlType::Integer)
        && (name.ends_with("_at") || name.ends_with("_date") || name.ends_with("_time"))
}

/// 尝试把 ISO8601 / RFC3339 字符串解析为毫秒时间戳
fn parse_iso_to_millis(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.timestamp_millis())
        .ok()
        .or_else(|| {
            chrono::DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%z")
                .map(|dt| dt.timestamp_millis())
                .ok()
        })
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S")
                .ok()
                .map(|naive| naive.and_utc().timestamp_millis())
        })
        .or_else(|| {
            chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
                .ok()
                .map(|date| {
                    date.and_hms_opt(0, 0, 0)
                        .unwrap()
                        .and_utc()
                        .timestamp_millis()
                })
        })
}

/// 将单个 JSON 值按目标列元数据规范化
///
/// - Null 值在 NOT NULL 列上自动转为类型默认值（Text→""、Integer→0、Real→0.0），
///   避免导入时违反约束；在可空列上保持 Null。
/// - 成功返回规范后的 Value；失败返回人类可读错误信息。
pub fn normalize_value(value: &Value, meta: &ColumnMeta) -> Result<Value, String> {
    match value {
        // NOT NULL 列收到显式 null 值时，自动填充类型合适的默认值，
        // 避免 INSERT 时违反 NOT NULL 约束导致整条记录导入失败
        // （如 rec_movies.poster_path / imdb_url / douban_url / original_title 等字段）
        Value::Null => {
            if meta.not_null {
                match meta.sql_type {
                    ColumnSqlType::Integer => Ok(Value::Number(0i64.into())),
                    ColumnSqlType::Real => Ok(Value::Number(
                        serde_json::Number::from_f64(0.0).unwrap_or_else(|| 0.into()),
                    )),
                    ColumnSqlType::Text | ColumnSqlType::Blob => Ok(Value::String(String::new())),
                }
            } else {
                Ok(Value::Null)
            }
        }
        Value::Bool(b) => match meta.sql_type {
            ColumnSqlType::Integer => Ok(Value::Number(if *b { 1i64.into() } else { 0i64.into() })),
            ColumnSqlType::Real => Ok(Value::Number(
                serde_json::Number::from_f64(if *b { 1.0 } else { 0.0 })
                    .unwrap_or_else(|| 0.into()),
            )),
            ColumnSqlType::Text | ColumnSqlType::Blob => Ok(Value::String(b.to_string())),
        },
        Value::Number(n) => match meta.sql_type {
            ColumnSqlType::Integer => {
                if let Some(i) = n.as_i64() {
                    Ok(Value::Number(i.into()))
                } else if let Some(f) = n.as_f64() {
                    Ok(Value::Number((f as i64).into()))
                } else {
                    Err(format!("无法将数值 '{}' 转为整数", n))
                }
            }
            ColumnSqlType::Real => {
                if let Some(f) = n.as_f64() {
                    Ok(Value::Number(
                        serde_json::Number::from_f64(f).unwrap_or_else(|| 0.into()),
                    ))
                } else {
                    Err(format!("无法将数值 '{}' 转为浮点数", n))
                }
            }
            ColumnSqlType::Text | ColumnSqlType::Blob => Ok(Value::String(n.to_string())),
        },
        Value::String(s) => match meta.sql_type {
            ColumnSqlType::Integer => {
                if is_timestamp_column(&meta.name, &meta.sql_type)
                    && let Some(ms) = parse_iso_to_millis(s)
                {
                    return Ok(Value::Number(ms.into()));
                }
                s.parse::<i64>()
                    .map(|i| Value::Number(i.into()))
                    .map_err(|_| format!("无法将字符串 '{}' 转为整数", s))
            }
            ColumnSqlType::Real => s
                .parse::<f64>()
                .map(|f| Value::Number(serde_json::Number::from_f64(f).unwrap_or_else(|| 0.into())))
                .map_err(|_| format!("无法将字符串 '{}' 转为浮点数", s)),
            ColumnSqlType::Text | ColumnSqlType::Blob => Ok(Value::String(s.clone())),
        },
        Value::Array(_) | Value::Object(_) => match meta.sql_type {
            ColumnSqlType::Text | ColumnSqlType::Blob => Ok(Value::String(value.to_string())),
            ColumnSqlType::Integer => Err(format!("数组/对象无法存入整数列 '{}'", meta.name)),
            ColumnSqlType::Real => Err(format!("数组/对象无法存入浮点列 '{}'", meta.name)),
        },
    }
}

/// 规范化导入字段 Map（使用已加载的列元数据）
///
/// - 对 `fields` 中存在的字段按声明类型转换。
/// - 未在表中定义的字段会被**移除**，避免写入未知列。
/// - `strict=true`：任何字段转换失败立即返回错误。
/// - `strict=false`：转换失败的字段置为 Null（可空时）或返回错误（非空时）。
pub fn normalize_fields_with_columns(
    fields: &serde_json::Map<String, Value>,
    columns: &HashMap<String, ColumnMeta>,
    strict: bool,
) -> CoreResult<serde_json::Map<String, Value>> {
    let mut normalized = serde_json::Map::with_capacity(fields.len());

    for (key, val) in fields.iter() {
        // 防御性校验字段名；虽然表中通常不会有非法列，但导入数据可能包含恶意键名
        if crate::db::repository::generic_repo::validate_column_name(key).is_err() {
            continue;
        }

        let Some(meta) = columns.get(key) else {
            // 未知字段：导入时不写入，避免破坏 schema
            continue;
        };

        match normalize_value(val, meta) {
            Ok(v) => {
                normalized.insert(key.clone(), v);
            }
            Err(e) => {
                if strict {
                    return Err(CoreError::Other(format!(
                        "字段 '{}' 类型错误：期望 {:?}，得到 {}（{}）",
                        key,
                        meta.sql_type,
                        value_kind(val),
                        e
                    )));
                }
                // 非严格模式：可空字段转 Null，非空字段报错
                if meta.not_null {
                    return Err(CoreError::Other(format!(
                        "字段 '{}' 类型错误且不允许为空：期望 {:?}，得到 {}（{}）",
                        key,
                        meta.sql_type,
                        value_kind(val),
                        e
                    )));
                }
                normalized.insert(key.clone(), Value::Null);
            }
        }
    }

    Ok(normalized)
}

/// 规范化导入字段 Map
///
/// 内部先通过 `PRAGMA table_info` 加载列元数据，再调用 [`normalize_fields_with_columns`]。
pub async fn normalize_import_fields(
    pool: &SqlitePool,
    table: &str,
    fields: &serde_json::Map<String, Value>,
    strict: bool,
) -> CoreResult<serde_json::Map<String, Value>> {
    let columns = load_table_columns(pool, table).await?;
    normalize_fields_with_columns(fields, &columns, strict)
}

fn value_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "布尔值",
        Value::Number(_) => "数值",
        Value::String(_) => "字符串",
        Value::Array(_) => "数组",
        Value::Object(_) => "对象",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn meta(name: &str, sql_type: ColumnSqlType, not_null: bool) -> ColumnMeta {
        ColumnMeta {
            name: name.to_string(),
            sql_type,
            not_null,
            dflt_value: None,
        }
    }

    #[test]
    fn normalize_release_year_string_to_int() {
        let m = meta("release_year", ColumnSqlType::Integer, false);
        assert_eq!(normalize_value(&json!("2023"), &m).unwrap(), json!(2023));
    }

    #[test]
    fn normalize_invalid_release_year_fails_in_strict_mode() {
        let m = meta("release_year", ColumnSqlType::Integer, false);
        let err = normalize_value(&json!("abc"), &m).unwrap_err();
        assert!(err.contains("abc"));
    }

    #[test]
    fn normalize_optional_int_invalid_becomes_null_in_non_strict_mode() {
        // normalize_value 本身不处理 strict；由调用方在失败时决定。
        // 此处仅验证它返回 Err，便于上层置 Null。
        let m = meta("release_year", ColumnSqlType::Integer, false);
        assert!(normalize_value(&json!("abc"), &m).is_err());
    }

    #[test]
    fn normalize_iso_datetime_to_millis_for_integer_timestamp_column() {
        let m = meta("watched_at", ColumnSqlType::Integer, false);
        let v = normalize_value(&json!("2023-01-01T00:00:00Z"), &m).unwrap();
        assert_eq!(v, json!(1672531200000i64));
    }

    #[test]
    fn normalize_text_column_accepts_any_value() {
        let m = meta("title", ColumnSqlType::Text, false);
        assert_eq!(normalize_value(&json!(123), &m).unwrap(), json!("123"));
        assert_eq!(
            normalize_value(&json!(["a", "b"]), &m).unwrap(),
            json!("[\"a\",\"b\"]")
        );
    }

    #[test]
    fn normalize_bool_to_integer() {
        let m = meta("is_watched", ColumnSqlType::Integer, false);
        assert_eq!(normalize_value(&json!(true), &m).unwrap(), json!(1));
        assert_eq!(normalize_value(&json!(false), &m).unwrap(), json!(0));
    }

    #[test]
    fn normalize_null_on_not_null_text_returns_empty_string() {
        // 模拟 rec_movies.poster_path (TEXT NOT NULL DEFAULT '') 收到 null 的场景
        let m = meta("poster_path", ColumnSqlType::Text, true);
        assert_eq!(normalize_value(&Value::Null, &m).unwrap(), json!(""));
    }

    #[test]
    fn normalize_null_on_not_null_integer_returns_zero() {
        let m = meta("is_watched", ColumnSqlType::Integer, true);
        assert_eq!(normalize_value(&Value::Null, &m).unwrap(), json!(0));
    }

    #[test]
    fn normalize_null_on_nullable_column_stays_null() {
        let m = meta("release_year", ColumnSqlType::Integer, false);
        assert_eq!(normalize_value(&Value::Null, &m).unwrap(), Value::Null);
    }

    #[tokio::test]
    async fn load_table_columns_reads_movies_schema() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::query(
            "CREATE TABLE rec_movies (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                release_year INTEGER,
                rating REAL
            )",
        )
        .execute(&pool)
        .await
        .unwrap();

        let cols = load_table_columns(&pool, "rec_movies").await.unwrap();
        assert_eq!(
            cols.get("release_year").unwrap().sql_type,
            ColumnSqlType::Integer
        );
        assert_eq!(cols.get("title").unwrap().sql_type, ColumnSqlType::Text);
        assert_eq!(cols.get("rating").unwrap().sql_type, ColumnSqlType::Real);
    }

    #[tokio::test]
    async fn normalize_import_fields_removes_unknown_columns() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::query(
            "CREATE TABLE rec_movies (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                release_year INTEGER
            )",
        )
        .execute(&pool)
        .await
        .unwrap();

        let mut fields = serde_json::Map::new();
        fields.insert("title".to_string(), json!("Test"));
        fields.insert("release_year".to_string(), json!("2023"));
        fields.insert("evil_column".to_string(), json!("should be removed"));

        let normalized = normalize_import_fields(&pool, "rec_movies", &fields, true)
            .await
            .unwrap();
        assert_eq!(normalized.get("title").unwrap(), &json!("Test"));
        assert_eq!(normalized.get("release_year").unwrap(), &json!(2023));
        assert!(!normalized.contains_key("evil_column"));
    }

    #[tokio::test]
    async fn normalize_import_fields_strict_fails_on_bad_integer() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::query(
            "CREATE TABLE rec_movies (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                release_year INTEGER
            )",
        )
        .execute(&pool)
        .await
        .unwrap();

        let mut fields = serde_json::Map::new();
        fields.insert("title".to_string(), json!("Test"));
        fields.insert("release_year".to_string(), json!("abc"));

        let err = normalize_import_fields(&pool, "rec_movies", &fields, true)
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("release_year"), "{}", msg);
        assert!(msg.contains("整数"), "{}", msg);
    }
}
