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
    load_table_items_where(pool, table, None).await
}

/// N52：加载单表**指定 uuid 集合**的未删除记录（行级增量装载）
///
/// 与 [`load_table_items`] 逐字段同口径（含 `_fk` 注入），区别只在取行范围：
/// push 只对「需要重算的桶」取行（判据见 `push::load_items_for_round`），
/// 干净桶的行不再物化成 JSON。`uuids` 分批（每批 500）构造 `IN` 条件——
/// SQLite 的变量上限随编译选项而异（999 / 32766），分批对两者都安全。
pub async fn load_table_items_of(
    pool: &SqlitePool,
    table: &str,
    uuids: &[String],
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    load_table_items_where(pool, table, Some(uuids)).await
}

/// 装载主体（`only_uuids` 为 `None` = 全表）
// bounded-by-lifecycle: 生产 push/pull 走 `load_table_items_of_cached` 的逐桶
// uuid 定向装载（见模块头）；此函数返回的整表行集合消费后即释放
async fn load_table_items_where(
    pool: &SqlitePool,
    table: &str,
    only_uuids: Option<&[String]>,
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }

    /// 单批 `IN` 的变量数（见 [`load_table_items_of`] 的口径说明）
    const UUID_BATCH: usize = 500;

    let rows = match only_uuids {
        None => {
            let sql = format!("SELECT * FROM \"{table}\" WHERE is_deleted = 0");
            sqlx::query(&sql)
                .fetch_all(pool)
                .await
                .map_err(|e| CloudSyncError::Database {
                    message: format!("加载表 {table} 失败: {e}"),
                })?
        }
        Some(uuids) => {
            // bounded-by-data: 按 500 一批的 uuid IN 查询，分批累加后一次性返回
            let mut out: Vec<sqlx::sqlite::SqliteRow> = Vec::with_capacity(uuids.len());
            for batch in uuids.chunks(UUID_BATCH) {
                let holders = std::iter::repeat_n("?", batch.len())
                    .collect::<Vec<_>>()
                    .join(",");
                let sql = format!(
                    "SELECT * FROM \"{table}\" WHERE is_deleted = 0 AND uuid IN ({holders})"
                );
                let mut q = sqlx::query(&sql);
                for uuid in batch {
                    q = q.bind(uuid);
                }
                out.extend(
                    q.fetch_all(pool)
                        .await
                        .map_err(|e| CloudSyncError::Database {
                            message: format!("按 uuid 加载表 {table} 失败: {e}"),
                        })?,
                );
            }
            out
        }
    };

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

/// 外键标记解析器（M4：跨桶复用，避免每个桶都重扫父表）
///
/// `_fk` 注入需要「父表 id → uuid」全量映射。此前每个装载调用都各自重读父表；
/// 改成按桶流式装载后，同一张表要装载 64 个桶，若每桶重读就成了 64 次父表扫描。
/// 本结构缓存这些映射，一次装载轮内复用。
///
/// 有界性：键集是「该表声明的父表」（`sync_registry::fk_columns_of` 的静态集合，
/// 至多数张），值是父表的 id→uuid 全量映射——与父表行数成正比，但不随桶数增长。
pub struct FkResolver {
    parents: HashMap<&'static str, HashMap<i64, String>>,
}

impl FkResolver {
    pub fn new() -> Self {
        Self {
            parents: HashMap::new(),
        }
    }

    /// 确保该表引用的所有父表映射已加载
    pub async fn ensure(&mut self, pool: &SqlitePool, table: &str) -> Result<(), CloudSyncError> {
        for (_, parent) in crate::db::sync_registry::fk_columns_of(table) {
            if self.parents.contains_key(parent) {
                continue;
            }
            self.parents
                .insert(*parent, load_id_uuid_map(pool, parent).await?);
        }
        Ok(())
    }

    /// 给一批记录注入 `_fk`（口径见 [`load_table_items`] 的文档）
    fn apply(&self, table: &str, items: &mut [serde_json::Value]) {
        let fk_cols = crate::db::sync_registry::fk_columns_of(table);
        if fk_cols.is_empty() {
            return;
        }
        for item in items.iter_mut() {
            let Some(obj) = item.as_object_mut() else {
                continue;
            };
            let mut mark = serde_json::Map::new();
            for (col, parent) in fk_cols {
                if let Some(id) = obj.get(*col).and_then(|v| v.as_i64())
                    && let Some(uuid) = self.parents.get(parent).and_then(|m| m.get(&id))
                {
                    mark.insert(
                        (*col).to_string(),
                        serde_json::Value::String(uuid.clone()),
                    );
                }
            }
            obj.insert(FK_MARK.to_string(), serde_json::Value::Object(mark));
        }
    }
}

impl Default for FkResolver {
    fn default() -> Self {
        Self::new()
    }
}

/// 单表「桶 → 存活行 uuid 清单」（M4 流式装载的索引层）
///
/// 只读 `uuid` 一列，不物化整行、不 JSON 化——10k 行的索引成本约等于
/// `scan_local_buckets` 的量级（几百 KB），换来的是**逐桶物化**：任一时刻
/// 内存里只有一个桶的行，而不是整表。
///
/// 桶归属由 `bucket_of_uuid`（sha256 前 8 hex % 64）决定，SQL 表达不了，
/// 故索引在 Rust 侧建。
// bounded-by-data: 每表存活行 uuid 列表（同步分桶索引，量级 = 行数 × ~40B；
// 桶数固定 64，行数据本身不在这里物化）
pub async fn load_table_uuids_by_bucket(
    pool: &SqlitePool,
    table: &str,
) -> Result<BTreeMap<u32, Vec<String>>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }
    let sql = format!("SELECT uuid FROM \"{table}\" WHERE is_deleted = 0");
    let uuids: Vec<String> = sqlx::query_scalar(&sql)
        .fetch_all(pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("加载表 {table} 的 uuid 索引失败: {e}"),
        })?;

    let mut out: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    for uuid in uuids {
        out.entry(crate::cloud_sync::chunk::bucket_of_uuid(&uuid))
            .or_default()
            .push(uuid);
    }
    Ok(out)
}

/// 装载单表**指定 uuid 集合**并复用已缓存的父表映射（M4 逐桶装载）
///
/// 与 [`load_table_items_of`] 行为一致，区别只是 `_fk` 用的父表映射由调用方
/// 持有的 [`FkResolver`] 提供（跨桶复用）。
pub async fn load_table_items_of_cached(
    pool: &SqlitePool,
    table: &str,
    uuids: &[String],
    fk: &FkResolver,
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    if !is_syncable(table) {
        return Err(CloudSyncError::Database {
            message: format!("表 {table} 不在同步白名单内"),
        });
    }
    if uuids.is_empty() {
        return Ok(Vec::new());
    }

    /// 单批 `IN` 的变量数（与 [`load_table_items_of`] 同口径）
    const UUID_BATCH: usize = 500;

    // bounded-by-data: 只装调用方给的桶内 uuid（每批 500），任一时刻仅一个桶的行
    let mut rows: Vec<sqlx::sqlite::SqliteRow> = Vec::with_capacity(uuids.len());
    for batch in uuids.chunks(UUID_BATCH) {
        let holders = std::iter::repeat_n("?", batch.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql =
            format!("SELECT * FROM \"{table}\" WHERE is_deleted = 0 AND uuid IN ({holders})");
        let mut q = sqlx::query(&sql);
        for uuid in batch {
            q = q.bind(uuid);
        }
        rows.extend(
            q.fetch_all(pool)
                .await
                .map_err(|e| CloudSyncError::Database {
                    message: format!("按 uuid 加载表 {table} 失败: {e}"),
                })?,
        );
    }

    let mut items: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| serde_json::Value::Object(sqlite_row_to_json(row)))
        .collect();
    fk.apply(table, &mut items);
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
    /// 脏桶的**全部存活行 uuid**（仅脏桶，见 [`scan_local_buckets`]）
    ///
    /// N52：push 重算一个桶需要该桶全部存活行（分桶载荷是桶级快照），
    /// 这份清单让装载按 uuid 定向取行，避免每轮把整表行都物化成 JSON。
    /// 键集与 [`Self::dirty`] 一致（只多不少：dirty 的每个桶都有清单）。
    pub dirty_uuids: HashMap<u32, Vec<String>>,
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
    // bounded-by-data: 每表 uuid + updated_at 索引（干净桶的 uuid 在归集后立即释放，
    // 只留脏桶清单；见函数内注释与 N52 口径）
    let sql = format!("SELECT uuid, updated_at FROM \"{table}\" WHERE is_deleted = 0");
    let rows: Vec<(String, Option<i64>)> =
        sqlx::query_as(&sql)
            .fetch_all(pool)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("扫描表 {table} 分桶失败: {e}"),
            })?;
    let mut scan = LocalBucketScan::default();
    // 瞬态：全部 uuid 按桶归集；循环结束后**只保留脏桶**的那几份（N52 行级
    // 增量装载用——重算一个桶需要该桶全部存活行，得靠这份清单按 uuid 定向取行）。
    // 干净桶的 uuid 立即释放：否则整库 uuid 会常驻整轮 push，吃掉优化省下的内存。
    let mut all_uuids: HashMap<u32, Vec<String>> = HashMap::new();
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
        all_uuids.entry(bucket).or_default().push(uuid);
    }
    scan.dirty_uuids = all_uuids
        .into_iter()
        .filter(|(bucket, _)| scan.dirty.contains(bucket))
        .collect();
    Ok(Some(scan))
}

/// 单表 `id → uuid` 映射（含软删行：软删父行的子记录仍要能标出父 uuid）
// bounded-by-lifecycle: 本轮同步的 FK 解析映射，push/pull 结束即释放
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
// bounded-by-lifecycle: 本轮同步的 FK 解析映射，push/pull 结束即释放
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
// bounded-by-lifecycle: 合并裁决用的 uuid 状态映射，本轮 merge 结束即释放
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
// bounded-by-lifecycle: 每轮 push 的墓碑清单，上传完成后释放（墓碑数受回收 TTL 约束）
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

    /// N52：`dirty_uuids` 必须给脏桶**全部存活行**的 uuid（不是只有脏行）
    ///
    /// 判据来自 push 的装载语义：重算一个桶需要该桶全部存活行（分桶载荷是
    /// 桶级快照），只带脏行会让装载少行 → 载荷变子集（他端行丢失）。
    /// 干净桶则一个 uuid 都不留（否则整库 uuid 常驻，吃掉优化省下的内存）。
    #[tokio::test]
    async fn dirty_uuids_retains_whole_dirty_bucket_only() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        // 两个 uuid 须落同一桶才构成「桶内既有脏行又有干净行」的场景，
        // 故按桶号反查一对 uuid（空 uuid 归 0 号桶，此处另挑真实 uuid）
        let (a, b) = pick_uuid_pair_in_same_bucket();
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
             VALUES (?1,'干净',1,100), (?2,'脏',2,300)",
        )
        .bind(&a)
        .bind(&b)
        .execute(&pool)
        .await
        .unwrap();
        // 再放一个干净桶（两个 uuid 都不在 a/b 那个桶里）
        let clean = pick_uuid_in_other_bucket(&a);
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
             VALUES (?1,'旁桶',3,100)",
        )
        .bind(&clean)
        .execute(&pool)
        .await
        .unwrap();

        let scan = scan_local_buckets(&pool, "todo_projects", 200)
            .await
            .unwrap()
            .unwrap();
        let dirty_bucket = crate::cloud_sync::chunk::bucket_of_uuid(&b);
        let clean_bucket = crate::cloud_sync::chunk::bucket_of_uuid(&clean);
        assert!(scan.dirty.contains(&dirty_bucket));
        assert!(!scan.dirty.contains(&clean_bucket));

        let mut kept = scan.dirty_uuids[&dirty_bucket].clone();
        kept.sort();
        let mut want = vec![a.clone(), b.clone()];
        want.sort();
        assert_eq!(
            kept, want,
            "脏桶要带全部存活行 uuid（含时间戳早于水位线的那行）"
        );
        assert!(
            !scan.dirty_uuids.contains_key(&clean_bucket),
            "干净桶不留 uuid 清单"
        );
    }

    /// 找一对落在同一桶的 uuid（小整数穷举，稳定可复现）
    fn pick_uuid_pair_in_same_bucket() -> (String, String) {
        let mut first: std::collections::HashMap<u32, String> = Default::default();
        for i in 0..10_000 {
            let uuid = format!("uuid-{i}");
            let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid);
            if let Some(other) = first.get(&bucket) {
                return (other.clone(), uuid);
            }
            first.insert(bucket, uuid);
        }
        unreachable!("64 个桶必然在 65 次内相撞")
    }

    /// 找一个与 `uuid` 不同桶的 uuid
    fn pick_uuid_in_other_bucket(uuid: &str) -> String {
        let want = crate::cloud_sync::chunk::bucket_of_uuid(uuid);
        (0..10_000)
            .map(|i| format!("other-{i}"))
            .find(|candidate| crate::cloud_sync::chunk::bucket_of_uuid(candidate) != want)
            .expect("64 桶必有异桶 uuid")
    }

    /// N52：按 uuid 集合装载——只取列出的存活行，软删行排除，`_fk` 照常注入
    #[tokio::test]
    async fn load_table_items_of_takes_exactly_listed_live_rows() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES ('t1','T',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let task_id: (i64,) = sqlx::query_as("SELECT id FROM todo_tasks WHERE uuid='t1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        // 子表两条：一条要取、一条软删（软删行不得出现在载荷里）
        sqlx::query(
            "INSERT INTO todo_subtasks (uuid, task_id, title, position, is_deleted, created_at, updated_at) \
             VALUES ('s1',?1,'要取',0,0,1,1), ('s2',?1,'已删',1,1,1,1)",
        )
        .bind(task_id.0)
        .execute(&pool)
        .await
        .unwrap();

        let items = load_table_items_of(&pool, "todo_subtasks", &["s1".into(), "s2".into()])
            .await
            .unwrap();
        assert_eq!(items.len(), 1, "软删行不参与载荷");
        assert_eq!(items[0]["uuid"], "s1");
        assert!(
            items[0].get(FK_MARK).is_some(),
            "带外键声明的表必须照常注入 _fk（增量装载不得跳过该步骤）"
        );

        let empty = load_table_items_of(&pool, "todo_subtasks", &[])
            .await
            .unwrap();
        assert!(empty.is_empty(), "空集合不应产生任何行");
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

    // ---------- M4：逐桶装载（索引层 + 缓存父表映射） ----------

    async fn setup_m4_db() -> SqlitePool {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// uuid 索引必须覆盖全部存活行，且按 `bucket_of_uuid` 正确分桶
    #[tokio::test]
    async fn uuid_index_groups_live_rows_by_bucket() {
        let pool = setup_m4_db().await;
        // 迁移自带种子行，先记基准（断言只针对本用例插入的部分）
        let seed: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM todo_projects WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        for (uuid, deleted) in [("a", 0), ("b", 0), ("c", 1)] {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, is_deleted, created_at, updated_at) \
                 VALUES (?, ?, ?, 1, 1)",
            )
            .bind(uuid)
            .bind(format!("项目{uuid}"))
            .bind(deleted)
            .execute(&pool)
            .await
            .unwrap();
        }

        let index = load_table_uuids_by_bucket(&pool, "todo_projects")
            .await
            .unwrap();
        let all: Vec<&str> = index.values().flatten().map(|s| s.as_str()).collect();
        assert_eq!(
            all.len() as i64,
            seed + 2,
            "软删行不进索引（与装载口径一致）：种子 {seed} + 本用例 2 条存活"
        );
        assert!(!all.contains(&"c"), "墓碑行不得出现在索引里");

        // 每个 uuid 都必须落在 bucket_of_uuid 算出的桶里
        for (bucket, uuids) in &index {
            for uuid in uuids {
                assert_eq!(
                    *bucket,
                    crate::cloud_sync::chunk::bucket_of_uuid(uuid),
                    "桶归属必须与 bucket_of_uuid 同源"
                );
            }
        }
    }

    /// 逐桶装载（带缓存父表映射）的结果必须与整表装载逐行一致
    ///
    /// 这是 M4 唯一不可妥协的性质：拆成 64 桶装载后，每桶内容与合并后的
    /// 整表载荷必须完全等价（含 `_fk` 注入），否则同步会把云端覆盖成子集。
    #[tokio::test]
    async fn per_bucket_load_equals_full_table_load() {
        let pool = setup_m4_db().await;
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES ('t1','T',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let task_id: (i64,) = sqlx::query_as("SELECT id FROM todo_tasks WHERE uuid='t1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        for (uuid, pos) in [("s1", 0), ("s2", 1), ("s3", 2)] {
            sqlx::query(
                "INSERT INTO todo_subtasks (uuid, task_id, title, position, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, 1, 1)",
            )
            .bind(uuid)
            .bind(task_id.0)
            .bind(format!("子{uuid}"))
            .bind(pos)
            .execute(&pool)
            .await
            .unwrap();
        }

        // 整表口径（改造前路径，保留为对照）
        let mut full = load_table_items(&pool, "todo_subtasks").await.unwrap();
        full.sort_by(|a, b| a["uuid"].as_str().cmp(&b["uuid"].as_str()));

        // 逐桶口径（M4 生产路径）
        let index = load_table_uuids_by_bucket(&pool, "todo_subtasks")
            .await
            .unwrap();
        let mut fk = FkResolver::new();
        fk.ensure(&pool, "todo_subtasks").await.unwrap();
        let mut per_bucket = Vec::new();
        for uuids in index.values() {
            per_bucket.extend(
                load_table_items_of_cached(&pool, "todo_subtasks", uuids, &fk)
                    .await
                    .unwrap(),
            );
        }
        per_bucket.sort_by(|a, b| a["uuid"].as_str().cmp(&b["uuid"].as_str()));

        assert_eq!(
            per_bucket, full,
            "逐桶装载与整表装载必须逐行等价（含 _fk 注入）"
        );
        // _fk 必须真的注入了（否则上面的等价可能因两边都缺而假通过）
        assert!(
            per_bucket[0].get(FK_MARK).is_some(),
            "带外键的表必须注入 _fk"
        );
    }

    /// 索引规模只与行数成正比、不随桶数增长（M4 的内存主张）
    #[tokio::test]
    async fn bucket_index_is_proportional_to_rows_not_buckets() {
        let pool = setup_m4_db().await;
        let seed: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM todo_projects WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        // 200 行散落各桶：索引条目数必须恰好等于存活行数
        for i in 0..200 {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
                 VALUES (?, ?, 1, 1)",
            )
            .bind(format!("p{i}"))
            .bind(format!("项目{i}"))
            .execute(&pool)
            .await
            .unwrap();
        }
        let index = load_table_uuids_by_bucket(&pool, "todo_projects")
            .await
            .unwrap();
        let total: usize = index.values().map(|v| v.len()).sum();
        assert_eq!(
            total as i64,
            seed + 200,
            "索引条目数 == 存活行数（不多也不少）"
        );
        assert!(
            index.len() <= crate::cloud_sync::chunk::TABLE_BUCKET_COUNT as usize,
            "桶数上限由 TABLE_BUCKET_COUNT 封顶"
        );
    }

    /// 空 uuid 清单：不查库、直接返回空（逐桶循环里空桶会走到这里）
    #[tokio::test]
    async fn cached_load_of_empty_uuid_set_returns_empty() {
        let pool = setup_m4_db().await;
        let fk = FkResolver::new();
        let items = load_table_items_of_cached(&pool, "todo_subtasks", &[], &fk)
            .await
            .unwrap();
        assert!(items.is_empty());
    }

    /// 非白名单表必须拒绝（与整表路径同口径）
    #[tokio::test]
    async fn uuid_index_rejects_non_syncable_table() {
        let pool = setup_m4_db().await;
        assert!(
            load_table_uuids_by_bucket(&pool, "cfg_options").await.is_err(),
            "非同步白名单表不得建立装载索引"
        );
    }
}
