//! db_loader — 从数据库按表加载同步数据（表级粒度）
//!
//! 分片单元是「表 + 桶」，因此加载入口一律按单表进行，既减少单次物化体积，
//! 也天然避免"跨表同 uuid 互相覆盖"的隐患（曾用 uuid 做全局 key 时，
//! 同一 uuid 出现在两张表时后者覆盖前者，复活裁决会读到错误的删除状态）。
//!
//! ## 可同步表白名单
//! 唯一来源：`crate::db::sync_registry::SYNCABLE_TABLES`。
//!
//! ## 墓碑分桶
//! 墓碑按**本地时区**月份（`YYYY-MM`）分桶，键用于云端对象路径
//! `tombstones/{table}/{YYYY-MM}.orsync`，并按同一键参与水位线回收。
//! 时区口径遵循项目约定（chrono::Local），不在 SQL 里按 UTC 分组。

use std::collections::{BTreeMap, HashMap, HashSet};

use sqlx::{Column, Row, SqlitePool, TypeInfo};

use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::TombstoneEntry;
use crate::db::sync_registry::SYNCABLE_TABLES;

/// 判断表是否可同步（白名单唯一来源见 `db::sync_registry`）
pub fn is_syncable(table: &str) -> bool {
    SYNCABLE_TABLES.contains(&table)
}

/// 载荷外键标记的键名：`{"project_id": "<父行 uuid>", ...}`
///
/// 由 `load_table_items` 注入、`merge::resolve_foreign_keys` 消费、
/// `fingerprint` 据此把对应整数列排除出指纹。三处共用此常量。
pub const FK_MARK: &str = "_fk";

/// 加载单表全部未删除记录
///
/// 返回原始行的 JSON 数组（不注入 `_table`：表归属由分桶载荷的
/// `table` 字段承载，写入侧已做白名单校验）。
///
/// **外键标记（F47）**：带整数外键的子表额外注入 `_fk: {外键列: 父行 uuid}`。
/// `id` 是本地自增主键，跨设备无意义——只搬整数值会让对端把子行挂到
/// **另一行**上（对端恰有该 id，连 `FOREIGN KEY constraint failed` 都不报）。
/// 父子关系因此改由 uuid 承载，对端落库时解析回本端 id。
/// 有外键声明的表**恒注入** `_fk`（外键全为 NULL 时是空对象），
/// 使「键缺失」可以确定性地判成「对端客户端过旧的旧格式载荷」而非「外键为空」。
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

    let mut items: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| serde_json::Value::Object(sqlite_row_to_json(row)))
        .collect();

    let fk_cols = crate::db::sync_registry::fk_columns_of(table);
    if !fk_cols.is_empty() {
        // 每张父表只读一次 id→uuid（同一父表可被多列引用，如 relations 的两端）
        let mut parents: HashMap<&'static str, HashMap<i64, String>> = HashMap::new();
        for (_, parent) in fk_cols {
            if !parents.contains_key(parent) {
                parents.insert(*parent, load_id_uuid_map(pool, parent).await?);
            }
        }
        for item in &mut items {
            let Some(obj) = item.as_object_mut() else {
                continue;
            };
            let mut mark = serde_json::Map::new();
            for (col, parent) in fk_cols {
                if let Some(id) = obj.get(*col).and_then(|v| v.as_i64())
                    && let Some(uuid) = parents[*parent].get(&id)
                {
                    mark.insert((*col).to_string(), serde_json::Value::String(uuid.clone()));
                }
            }
            obj.insert(FK_MARK.to_string(), serde_json::Value::Object(mark));
        }
    }

    Ok(items)
}

/// 本地分桶扫描结果（F41 增量 push 判据的输入）
#[derive(Debug, Default, Clone)]
pub struct LocalBucketScan {
    /// 每桶当前存活行数——与远端清单的 `ChunkRef.count` 比对，检出「只减不增」
    /// 的集合变化（merge 应用远端墓碑造成的本地软删：行时间戳被锚定为墓碑的
    /// `deleted_at`，可能早于水位线，纯时间戳判据看不见这一类）
    pub live_counts: HashMap<u32, u64>,
    /// 存在 `updated_at` 晚于水位线的行的桶（含 `updated_at` 为 0/NULL 的
    /// 历史行——保守计入，宁可多算一个桶，不可漏传一条记录）
    pub dirty: HashSet<u32>,
}

impl LocalBucketScan {
    /// 该桶是否「与上次推送时逐字节一致」（可跳过重算）
    ///
    /// 两条判据都通过才可跳过：
    /// - 行数相等（`remote_count` 来自远端清单条目）——行集未变；
    ///   入库必推进 `updated_at`（本地写路径）或来自远端（merge，云端已有），
    ///   出库（软删）会减行数，因此「行数相等 + 无脏行」⇒ 行集与内容都未变；
    /// - 无行晚于水位线。
    pub fn bucket_is_unchanged(&self, bucket: u32, remote_count: u64) -> bool {
        !self.dirty.contains(&bucket)
            && self.live_counts.get(&bucket).copied().unwrap_or(0) == remote_count
    }
}

/// 扫描单表存活行的分桶分布与脏桶集合（F41 增量 push 判据）
///
/// 水位线是上轮同步成功时记录的**逻辑时钟快照**
/// （`SyncState.last_synced_clock_ms`）。返回 `None` 表示不可增量
/// （水位线 ≤ 0：首次同步 / 账本缺失 / 时钟未加载），调用方按全量处理。
///
/// 只读 `uuid` 与 `updated_at` 两列（不物化整行、不 JSON 化），10k 行库的
/// 扫描成本是轻量列读取；真正的 JSON 序列化只发生在判定的脏桶上。
pub async fn scan_local_buckets(
    pool: &SqlitePool,
    table: &str,
    watermark: i64,
) -> Result<Option<LocalBucketScan>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }
    if watermark <= 0 {
        return Ok(None);
    }
    let sql = format!("SELECT uuid, updated_at FROM \"{table}\" WHERE is_deleted = 0");
    let rows: Vec<(String, Option<i64>)> =
        sqlx::query_as(&sql)
            .fetch_all(pool)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("扫描表 {table} 分桶失败: {e}"),
            })?;
    let mut scan = LocalBucketScan::default();
    for (uuid, updated_at) in rows {
        if uuid.is_empty() {
            continue;
        }
        let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid);
        *scan.live_counts.entry(bucket).or_insert(0) += 1;
        let ts = updated_at.unwrap_or(0);
        if ts <= 0 || ts > watermark {
            scan.dirty.insert(bucket);
        }
    }
    Ok(Some(scan))
}

/// 单表 `id → uuid` 映射（含软删行：软删父行的子记录仍要能标出父 uuid）
pub async fn load_id_uuid_map(
    pool: &SqlitePool,
    table: &str,
) -> Result<HashMap<i64, String>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }
    let rows: Vec<(i64, String)> = sqlx::query_as(&format!("SELECT id, uuid FROM \"{table}\""))
        .fetch_all(pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("加载表 {table} id→uuid 失败: {e}"),
        })?;
    Ok(rows.into_iter().collect())
}

/// 单表 `uuid → id` 映射（含软删行：软删父行在本端仍是该子行的归属）
pub async fn load_uuid_id_map(
    pool: &SqlitePool,
    table: &str,
) -> Result<HashMap<String, i64>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }
    let rows: Vec<(String, i64)> = sqlx::query_as(&format!("SELECT uuid, id FROM \"{table}\""))
        .fetch_all(pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("加载表 {table} uuid→id 失败: {e}"),
        })?;
    Ok(rows.into_iter().collect())
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
    let rows: Vec<(String, i64, i64, i64, i64)> = sqlx::query_as(&sql)
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

    /// F41：桶扫描按水位线取舍，且行数比对能检出「时间戳早于水位线」的软删
    #[tokio::test]
    async fn scan_local_buckets_respects_watermark_and_counts() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
             VALUES ('early','E',1,100), ('late','L',2,200)",
        )
        .execute(&pool)
        .await
        .unwrap();

        assert!(
            scan_local_buckets(&pool, "todo_projects", 0)
                .await
                .unwrap()
                .is_none(),
            "水位线 ≤ 0 不可增量（首同步 / 账本缺失 → 全量）"
        );

        let scan = scan_local_buckets(&pool, "todo_projects", 150)
            .await
            .unwrap()
            .unwrap();
        let early = crate::cloud_sync::chunk::bucket_of_uuid("early");
        let late = crate::cloud_sync::chunk::bucket_of_uuid("late");
        assert!(scan.dirty.contains(&late), "水位线之后改过的行必须脏");
        assert!(!scan.dirty.contains(&early), "水位线之前未再改动的行不脏");
        assert_eq!(scan.live_counts[&early], 1, "存活行数必须计入");
        assert!(
            scan.bucket_is_unchanged(early, 1),
            "行数一致且无脏行 → 可跳过重算"
        );
        assert!(
            !scan.bucket_is_unchanged(early, 2),
            "行数不等（本地软删/新增）必须重算——这是时间戳判据的盲区"
        );

        // updated_at = 0 的历史行保守计入脏集合（宁可多算一个桶，不可漏传）
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
             VALUES ('zero','Z',3,0)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let scan = scan_local_buckets(&pool, "todo_projects", 150)
            .await
            .unwrap()
            .unwrap();
        assert!(
            scan.dirty
                .contains(&crate::cloud_sync::chunk::bucket_of_uuid("zero"))
        );
    }
}
