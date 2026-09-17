//! db_loader — 从数据库按表加载同步数据（v2 表级粒度）
//!
//! v2 的分片单元是「表 + 桶」，因此加载入口一律按单表进行（不再有整模块
//! 全表加载），既减少单次物化体积，也天然避免"跨表同 uuid 互相覆盖"的隐患
//! （v1 的 `load_local_uuid_map` 用 uuid 做全局 key，同一 uuid 出现在两张表
//! 时后者覆盖前者，复活裁决会读到错误的删除状态）。
//!
//! ## 可同步表白名单
//! 唯一来源：`crate::db::sync_registry::SYNCABLE_TABLES`。
//!
//! ## 墓碑分桶
//! 墓碑按**本地时区**月份（`YYYY-MM`）分桶，键用于云端对象路径
//! `v2/tombstones/{table}/{YYYY-MM}.orsync`，并按同一键参与水位线回收。
//! 时区口径遵循项目约定（chrono::Local），不在 SQL 里按 UTC 分组。

use std::collections::{BTreeMap, HashMap};

use sqlx::{Column, Row, SqlitePool, TypeInfo};

use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::TombstoneEntry;
use crate::db::sync_registry::SYNCABLE_TABLES;

/// 判断表是否可同步（白名单唯一来源见 `db::sync_registry`）
pub fn is_syncable(table: &str) -> bool {
    SYNCABLE_TABLES.contains(&table)
}

/// 加载单表全部未删除记录
///
/// 返回原始行的 JSON 数组（不注入 `_table`：v2 的表归属由分桶载荷的
/// `table` 字段承载，写入侧已做白名单校验）。
pub async fn load_table_items(
    pool: &SqlitePool,
    table: &str,
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }

    let sql = format!("SELECT * FROM \"{table}\" WHERE is_deleted = 0");
    let rows = sqlx::query(&sql)
        .fetch_all(pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("加载表 {table} 失败: {e}"),
        })?;

    Ok(rows
        .iter()
        .map(|row| serde_json::Value::Object(sqlite_row_to_json(row)))
        .collect())
}

/// 单条记录的合并裁决状态（含软删除行，供复活裁决使用）
#[derive(Debug, Clone, Copy)]
pub struct LocalRecordState {
    /// 记录更新时间（LWW 回退键）
    pub updated_at: i64,
    /// 版本号（updated_at 平局次级裁决，缺失视为 0）
    pub version: i64,
    /// 是否处于软删除状态
    pub is_deleted: bool,
    /// 软删除时间（仅 is_deleted=true 时有意义）；
    /// 口径与 [`load_table_tombstones`] 一致：COALESCE(NULLIF(deleted_at,0), updated_at)
    pub deleted_at: i64,
}

/// 加载单表全部记录（含软删除）的 uuid 状态映射
///
/// 软删除记录必须纳入：merge 据此区分「INSERT 新记录」与「复活已有记录」。
pub async fn load_table_uuid_map(
    pool: &SqlitePool,
    table: &str,
) -> Result<HashMap<String, LocalRecordState>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }

    let sql = format!(
        "SELECT uuid, updated_at, version, is_deleted, \
         COALESCE(NULLIF(deleted_at, 0), updated_at) AS deleted_at \
         FROM \"{table}\""
    );
    let rows: Vec<(String, i64, i64, i64, i64)> =
        sqlx::query_as(&sql)
            .fetch_all(pool)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("加载表 {table} uuid 映射失败: {e}"),
            })?;

    let mut map = HashMap::with_capacity(rows.len());
    for (uuid, updated_at, version, is_deleted, deleted_at) in rows {
        if uuid.is_empty() {
            continue;
        }
        map.insert(
            uuid,
            LocalRecordState {
                updated_at,
                version,
                is_deleted: is_deleted != 0,
                deleted_at,
            },
        );
    }
    Ok(map)
}

/// 加载单表墓碑并按本地时区月份分桶
///
/// 返回 `bucket(YYYY-MM) -> 墓碑条目`（BTreeMap 保证键升序，便于水位线比较）。
/// 不含任何上限：墓碑条数即真实删除数（回收由 `gc` 按水位线执行）。
pub async fn load_table_tombstones(
    pool: &SqlitePool,
    table: &str,
) -> Result<BTreeMap<String, Vec<TombstoneEntry>>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }

    // deleted_at 优先，为 0/NULL 时回退 updated_at（与 LocalRecordState 同口径）
    let sql = format!(
        "SELECT uuid, COALESCE(NULLIF(deleted_at, 0), updated_at) AS ts \
         FROM \"{table}\" WHERE is_deleted = 1"
    );
    let rows = sqlx::query(&sql)
        .fetch_all(pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("加载表 {table} 墓碑失败: {e}"),
        })?;

    let mut buckets: BTreeMap<String, Vec<TombstoneEntry>> = BTreeMap::new();
    for row in rows {
        let uuid: String = row.try_get("uuid").unwrap_or_default();
        let ts: i64 = row.try_get("ts").unwrap_or(0);
        if uuid.is_empty() {
            continue;
        }
        buckets
            .entry(local_month_key(ts))
            .or_default()
            .push(TombstoneEntry::new(uuid, ts));
    }
    Ok(buckets)
}

/// 毫秒时间戳 → 本地时区月份键（`YYYY-MM`）
///
/// 落在本地时区日界口径上（与项目日期分桶约定一致）；异常时间戳
/// （超范围）回退为 `1970-01`，保证不 panic 且可参与比较。
pub fn local_month_key(ts_ms: i64) -> String {
    use chrono::{Local, TimeZone};
    match Local.timestamp_millis_opt(ts_ms).single() {
        Some(dt) => dt.format("%Y-%m").to_string(),
        None => "1970-01".to_string(),
    }
}

/// 将 sqlx SqliteRow 转为 serde_json::Map
///
/// 按 SQLite 动态类型分派解码（与 `business_api::sqlite_row_to_json` 同口径）。
pub fn sqlite_row_to_json(
    row: &sqlx::sqlite::SqliteRow,
) -> serde_json::Map<String, serde_json::Value> {
    let mut obj = serde_json::Map::new();
    for (i, col) in row.columns().iter().enumerate() {
        let name = col.name().to_string();
        let type_name = col.type_info().name();
        let val = match type_name {
            "INTEGER" | "INT" | "INTEGER8" => {
                let v: Option<i64> = row.try_get(i).unwrap_or(None);
                serde_json::Value::from(v)
            }
            "REAL" | "FLOAT" | "DOUBLE" | "REAL8" => {
                let v: Option<f64> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            "TEXT" | "VARCHAR" | "CHAR" => {
                let v: Option<String> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            _ => {
                if let Ok(v) = row.try_get::<Option<i64>, _>(i) {
                    serde_json::Value::from(v)
                } else if let Ok(v) = row.try_get::<Option<f64>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else if let Ok(v) = row.try_get::<Option<String>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else {
                    serde_json::Value::Null
                }
            }
        };
        obj.insert(name, val);
    }
    obj
}

/// 当前时间（Unix 毫秒）
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syncable_tables_match_registry() {
        for t in crate::db::sync_registry::SYNCABLE_TABLES {
            assert!(is_syncable(t), "白名单内的表应可同步: {t}");
        }
        assert!(!is_syncable("sync_configs"));
        assert!(!is_syncable("cfg_kv"));
    }

    #[test]
    fn month_key_uses_local_calendar() {
        // 2026-09-15 12:00:00 UTC 在任意时区都落在 2026-09
        let ts = 1_789_473_600_000i64;
        assert_eq!(local_month_key(ts), "2026-09");
    }

    #[test]
    fn month_key_handles_out_of_range() {
        assert_eq!(local_month_key(i64::MAX), "1970-01");
    }

    #[test]
    fn now_ms_returns_positive() {
        assert!(now_ms() > 0);
    }
}
