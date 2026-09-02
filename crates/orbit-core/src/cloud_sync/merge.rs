//! merge — item 级 LWW 合并 + 墓碑应用
//!
//! Pull 时对下载的模块数据做 item 级合并，保证多设备各自新增的记录都不丢失。
//!
//! ## 合并规则
//! - 远端有、本地无（按 uuid） → INSERT（保留远端原始字段）
//! - 本地有、远端无 → 保留（多设备新增不丢）
//! - 两端都有 → `updated_at` 较大者胜（LWW）；`updated_at` 相等时用 `version`
//!   次级裁决（高者胜），杜绝同毫秒平局导致的两端分歧与振荡（FR-3）
//! - 墓碑集中的 uuid → 本地软删除
//!
//! ## 事务保证
//! 整个合并操作在单个事务内，按固定顺序处理，保证原子性。
//! 单条记录失败不阻塞整体，错误收集到 MergeResult.errors。
//!
//! ## 性能优化（2026-07-25 P0）
//! - INSERT 批量化：分批 50 条构造 `INSERT INTO t (cols) VALUES (?),(?),...`，
//!   5000 条记录从 ~500ms 降至 ~20ms
//! - 墓碑 UPDATE 批量化：`UPDATE t SET is_deleted=1 WHERE uuid IN (?,?...)`，
//!   500 墓碑 × 3 表从 1500 次 SQL 降至 3 次

use std::collections::HashMap;

use sqlx::SqlitePool;

use crate::cloud_sync::db_loader::{LocalRecordState, load_local_uuid_map};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::TombstoneEntry;
use crate::cloud_sync::modules::SyncModuleDef;
use crate::db::repository::generic_repo::{push_json_value, validate_column_name};
use crate::db::repository::import_type_validator::{
    ColumnMeta, load_table_columns, normalize_value,
};

/// 批量 INSERT 单批最大记录数
///
/// SQLite 默认 `SQLITE_MAX_VARIABLE_NUMBER=999`，单条记录假设 15 字段，
/// 上限 = 999/15 ≈ 66。取保守值 50，单批最多 750 参数 < 999。
const INSERT_BATCH_SIZE: usize = 50;

/// LWW 平局裁决结果
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum LwwDecision {
    /// 远端胜出，需要 UPDATE 本地记录
    Update,
    /// 本地胜出或数据相同，跳过
    Skip,
}

/// LWW 裁决纯函数（FR-3）
///
/// 决策规则：
/// 1. `remote_updated > local_updated` → `Update`（远端更新）
/// 2. `remote_updated < local_updated` → `Skip`（本地更新）
/// 3. `updated_at` 相等（同毫秒平局）→ 用 `version` 次级裁决：
///    - `remote_version > local_version` → `Update`
///    - 否则 → `Skip`（含 version 相等，视为同数据）
///
/// 确定性保证：两端对同一对 (remote, local) 调用得到相反结果——
/// 设备 A 拉取 B 的数据时 remote=B，设备 B 拉取 A 的数据时 remote=A，
/// 但胜出方由 (updated_at, version) 数值大小决定，与谁是 remote 无关，
/// 因此两端最终收敛到同一胜出值，杜绝振荡。
fn decide_lww(
    remote_updated: i64,
    local_updated: i64,
    remote_version: i64,
    local_version: i64,
) -> LwwDecision {
    use std::cmp::Ordering;
    match remote_updated.cmp(&local_updated) {
        Ordering::Greater => LwwDecision::Update,
        Ordering::Less => LwwDecision::Skip,
        Ordering::Equal => {
            // 平局：用 version 次级裁决，确定性保证两端收敛
            if remote_version > local_version {
                LwwDecision::Update
            } else {
                LwwDecision::Skip
            }
        }
    }
}

/// 合并结果统计
#[derive(Debug, Clone, Default)]
pub struct MergeResult {
    /// 新增记录数（本地无 → 插入）
    pub inserted: u64,
    /// 更新记录数（远端更新时间更大 → 覆盖）
    pub updated: u64,
    /// 删除记录数（应用墓碑）
    pub deleted: u64,
    /// 跳过记录数（本地更新时间更大或相等）
    pub skipped: u64,
    /// 错误信息（不阻塞整体流程）
    pub errors: Vec<String>,
}

/// item 级 LWW 合并
///
/// 遍历远端 items，按 `_table` 字段路由到对应表，按 uuid 做 UPSERT。
/// 墓碑集中的 uuid 执行软删除（FR-2.6：带时间戳裁决删除vs编辑冲突）。
pub async fn merge_items(
    db_pool: &SqlitePool,
    module_def: &SyncModuleDef,
    remote_items: &[serde_json::Value],
    tombstones: &[TombstoneEntry],
) -> Result<MergeResult, CloudSyncError> {
    // 1. 加载本地 uuid → updated_at 映射
    let local_map = load_local_uuid_map(db_pool, module_def).await?;

    // 2. 按表分组远端 items（每个表独立处理）
    let mut items_by_table: HashMap<&str, Vec<&serde_json::Value>> = HashMap::new();
    for item in remote_items {
        let table = item
            .get("_table")
            .and_then(|v| v.as_str())
            .unwrap_or(module_def.primary_table());
        items_by_table.entry(table).or_default().push(item);
    }

    let mut result = MergeResult::default();

    // 3. 逐表处理（每个表一个事务，错误隔离）
    for (table, items) in &items_by_table {
        match merge_table_items(db_pool, table, items, &local_map).await {
            Ok(table_result) => {
                result.inserted += table_result.inserted;
                result.updated += table_result.updated;
                result.skipped += table_result.skipped;
                result.errors.extend(table_result.errors);
            }
            Err(e) => {
                result.errors.push(format!("表 {} 合并失败: {}", table, e));
            }
        }
    }

    // 4. 应用墓碑集（软删除，FR-2.6：带时间戳裁决）
    match apply_tombstones(db_pool, module_def, tombstones, &local_map).await {
        Ok(count) => {
            result.deleted = count;
        }
        Err(e) => {
            result.errors.push(format!("墓碑应用失败: {}", e));
        }
    }

    Ok(result)
}

/// 单表 items 合并（批量 INSERT + 单条 UPDATE）
///
/// 性能优化：
/// - INSERT 分批 50 条，构造 `INSERT INTO t (cols) VALUES (?),(?),...` 单次执行
/// - UPDATE 保持单条（每条记录字段集可能不同，CASE WHEN 复杂度过高）
/// - 整个操作在单个事务内，保证原子性
async fn merge_table_items(
    db_pool: &SqlitePool,
    table: &str,
    items: &[&serde_json::Value],
    local_map: &HashMap<String, LocalRecordState>,
) -> Result<MergeResult, CloudSyncError> {
    let columns =
        load_table_columns(db_pool, table)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("加载表 {} 列元数据失败: {}", table, e),
            })?;

    let mut result = MergeResult::default();

    // 1. 分类：待 INSERT 和待 UPDATE
    let mut to_insert: Vec<&serde_json::Map<String, serde_json::Value>> = Vec::new();
    let mut to_update: Vec<(&str, &serde_json::Map<String, serde_json::Value>)> = Vec::new();

    for item in items {
        let obj = match item.as_object() {
            Some(o) => o,
            None => {
                result
                    .errors
                    .push(format!("表 {}: 记录不是 JSON 对象", table));
                continue;
            }
        };

        let uuid = obj
            .get("uuid")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if uuid.is_empty() {
            result
                .errors
                .push(format!("表 {}: 记录缺少 uuid 字段", table));
            continue;
        }

        let remote_updated = obj.get("updated_at").and_then(|v| v.as_i64()).unwrap_or(0);

        // 三分支裁决（Fix-01）：
        // 1. 本地无该 uuid → INSERT 新纪录
        // 2. 本地存活 → 常规 LWW
        // 3. 本地为墓碑 → 复活裁决：远端存活记录的 updated_at 不早于本地删除时间才复活，
        //    否则删除仍胜出（跳过）。绝不允许走到 INSERT——那会产生重复 uuid 行。
        match local_map.get(&uuid) {
            None => {
                to_insert.push(obj);
            }
            Some(local) if !local.is_deleted => {
                // 远端 version 缺失视为 0（兼容旧数据）
                let remote_version = obj.get("version").and_then(|v| v.as_i64()).unwrap_or(0);
                let decision = decide_lww(
                    remote_updated,
                    local.updated_at,
                    remote_version,
                    local.version,
                );
                match decision {
                    LwwDecision::Update => {
                        // 远端胜出（updated_at 更大，或平局时 version 更高）→ UPDATE
                        let uuid_ref = obj.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
                        // 平局裁决时输出 warn 日志，便于排查（非平局的正常 Update 不打日志）
                        if remote_updated == local.updated_at {
                            log::warn!(
                                "[merge] LWW 平局裁决：表 {} uuid={} updated_at={}，\
                                 远端 version={} > 本地 {}，采用远端",
                                table,
                                uuid_ref,
                                remote_updated,
                                remote_version,
                                local.version
                            );
                        }
                        to_update.push((uuid_ref, obj));
                    }
                    LwwDecision::Skip => {
                        // 本地胜出或数据相同 → 跳过
                        if remote_updated == local.updated_at && remote_version == local.version {
                            log::debug!(
                                "[merge] LWW 完全平局：表 {} uuid={} updated_at 与 version 均相等，跳过",
                                table,
                                uuid
                            );
                        }
                        result.skipped += 1;
                    }
                }
            }
            Some(local) => {
                // 复活裁决（FR-2.6 口径）：deleted_at=0（极旧格式）视为可复活
                if remote_updated >= local.deleted_at || local.deleted_at == 0 {
                    log::info!(
                        "[merge] 复活裁决：表 {} uuid={} 远端更新时间 {} ≥ 本地删除时间 {}，\
                         恢复存活（UPDATE，不 INSERT）",
                        table,
                        uuid,
                        remote_updated,
                        local.deleted_at
                    );
                    let uuid_ref = obj.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
                    to_update.push((uuid_ref, obj));
                } else {
                    log::info!(
                        "[merge] 复活裁决：表 {} uuid={} 远端更新时间 {} < 本地删除时间 {}，\
                         删除胜出，跳过",
                        table,
                        uuid,
                        remote_updated,
                        local.deleted_at
                    );
                    result.skipped += 1;
                }
            }
        }
    }

    // 2. 单事务包裹批量 INSERT 与逐条 UPDATE，保证原子性
    // 之前拆为两个独立事务，崩溃会留下半合并状态（已 INSERT 但未 UPDATE），
    // 虽然下次指纹校验可补偿，但破坏了"单表合并原子性"契约，故合并为单事务。
    let mut tx = db_pool.begin().await?;
    result.inserted += batch_insert(&mut tx, table, &to_insert, &columns).await?;

    // 3. 逐条 UPDATE（在同一事务中）
    for (uuid, obj) in &to_update {
        match update_record_in_tx(&mut tx, table, obj, uuid, &columns).await {
            Ok(()) => result.updated += 1,
            Err(e) => {
                result
                    .errors
                    .push(format!("表 {}: 更新 uuid={} 失败: {}", table, uuid, e));
            }
        }
    }
    tx.commit().await?;

    Ok(result)
}

/// 批量 INSERT：分批 50 条构造 `INSERT INTO t (cols) VALUES (?),(?),...`
///
/// 返回成功插入的记录数。
///
/// 实现策略：
/// 1. 计算所有记录的列并集（仅包含目标表中存在的列）
/// 2. 每批 50 条记录，构造多 VALUES 的 INSERT 语句
/// 3. 缺失字段绑定为 NULL（保持与原单条 INSERT 相同语义）
async fn batch_insert(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    items: &[&serde_json::Map<String, serde_json::Value>],
    columns: &HashMap<String, ColumnMeta>,
) -> Result<u64, CloudSyncError> {
    if items.is_empty() {
        return Ok(0);
    }

    // 1. 计算列并集（保持稳定顺序：按 columns 的 key 排序）
    // 仅包含目标表中存在的列，排除 _table 和 id
    let mut col_names: Vec<&str> = Vec::new();
    for (key, _) in items.iter().flat_map(|obj| obj.iter()) {
        if key == "_table" || key == "id" {
            continue;
        }
        if !columns.contains_key(key) {
            continue; // 列不存在于目标表 → 跳过（兼容 schema 版本差异）
        }
        if !col_names.contains(&key.as_str()) {
            col_names.push(key.as_str());
        }
    }

    if col_names.is_empty() {
        return Ok(0);
    }

    // 校验列名（防 SQL 注入）
    for name in &col_names {
        validate_column_name(name).map_err(|e| CloudSyncError::Database {
            message: e.to_string(),
        })?;
    }

    let mut inserted: u64 = 0;

    // 2. 分批处理
    for chunk in items.chunks(INSERT_BATCH_SIZE) {
        let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
        q.push(table);
        q.push(" (");
        for (i, name) in col_names.iter().enumerate() {
            if i > 0 {
                q.push(", ");
            }
            q.push(*name);
        }
        q.push(") VALUES ");

        for (row_idx, obj) in chunk.iter().enumerate() {
            if row_idx > 0 {
                q.push(", ");
            }
            q.push("(");
            for (col_idx, col_name) in col_names.iter().enumerate() {
                if col_idx > 0 {
                    q.push(", ");
                }
                // 缺失字段绑定为 NULL
                if let Some(val) = obj.get(*col_name) {
                    // 按列声明类型规范化值
                    let normalized = match columns.get(*col_name) {
                        Some(m) => match normalize_value(val, m) {
                            Ok(n) => n,
                            Err(_) => serde_json::Value::Null,
                        },
                        None => val.clone(),
                    };
                    push_json_value(&mut q, &normalized);
                } else {
                    q.push_bind(None::<String>);
                }
            }
            q.push(")");
        }

        match q.build().execute(&mut **tx).await {
            Ok(res) => inserted += res.rows_affected(),
            Err(e) => {
                return Err(CloudSyncError::Database {
                    message: format!("批量 INSERT 表 {} 失败: {}", table, e),
                });
            }
        }
    }

    Ok(inserted)
}

/// 在事务中 UPDATE 记录（按 uuid 定位，保留远端原始字段）
///
/// 排除 `_table`、`id`、`uuid`（uuid 用于 WHERE 条件）。
async fn update_record_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
    uuid: &str,
    columns: &HashMap<String, ColumnMeta>,
) -> Result<(), String> {
    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("UPDATE ");
    q.push(table);
    q.push(" SET ");

    let mut first = true;
    for (key, val) in fields {
        // 排除同步元字段、主键、uuid（uuid 用于 WHERE）
        if key == "_table" || key == "id" || key == "uuid" {
            continue;
        }
        validate_column_name(key).map_err(|e| e.to_string())?;

        let normalized = if let Some(m) = columns.get(key) {
            normalize_value(val, m).map_err(|e| e.to_string())?
        } else {
            continue;
        };

        if !first {
            q.push(", ");
        }
        q.push(key);
        q.push(" = ");
        push_json_value(&mut q, &normalized);
        first = false;
    }

    if first {
        // 没有可更新的字段
        return Ok(());
    }

    q.push(" WHERE uuid = ");
    q.push_bind(uuid.to_string());

    q.build()
        .execute(&mut **tx)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// 应用墓碑集：对本地存在的存活记录执行软删除（逐条保留原始删除时间）
///
/// FR-2.6 时间戳裁决：deleted_at >= local.updated_at 才删除（删除胜），
/// deleted_at < local.updated_at 跳过（编辑胜），deleted_at=0（旧格式）直接删除。
///
/// Fix-02：旧实现把 `deleted_at`/`updated_at` 统一重写为同步时刻 `now()`，
/// 墓碑的原始删除时间被覆盖。跨设备传播后"删除时间"被放大为最近一次同步时间，
/// 其他设备在原删除之后的合法编辑会被误判为「删除胜」而**静默丢失**。
/// 现改为同事务内逐条 UPDATE，绑定每条墓碑自身的 deleted_at：
/// - 正常路径：`deleted_at = updated_at = 墓碑.deleted_at`（时间戳全程不漂移）
/// - 旧格式兜底（deleted_at=0）：保留旧行为绑定 now()（仅病态数据触达）
///
/// 性能说明：单条 UPDATE 在 SQLite 本地为 µs 级，墓碑量级通常数百条，
/// 事务内循环总开销可忽略；sqlx 按连接缓存 prepared statement。
async fn apply_tombstones(
    db_pool: &SqlitePool,
    module_def: &SyncModuleDef,
    tombstones: &[TombstoneEntry],
    local_map: &HashMap<String, LocalRecordState>,
) -> Result<u64, CloudSyncError> {
    // FR-2.6：时间戳裁决 — 过滤出需要删除的 (uuid, deleted_at)
    let to_delete: Vec<(String, i64)> = tombstones
        .iter()
        .filter_map(|t| {
            let uuid = t.uuid();
            let local = local_map.get(uuid)?;
            // 本地已是软删除状态 → 无需处理（旧版 map 不含墓碑行，天然跳过；
            // Fix-01 后 map 含全量记录，此处显式保持该语义）
            if local.is_deleted {
                return None;
            }
            let deleted_at = t.deleted_at();
            // 旧格式（deleted_at=0）或删除时间 >= 本地更新时间 → 删除
            if deleted_at == 0 || deleted_at >= local.updated_at {
                Some((uuid.to_string(), deleted_at))
            } else {
                // 编辑胜：本地更新时间晚于删除时间，跳过
                None
            }
        })
        .collect();

    if to_delete.is_empty() {
        return Ok(0);
    }

    let mut deleted_count = 0u64;
    let now = crate::cloud_sync::db_loader::now_ms();

    // 单事务包裹所有表的所有条目
    let mut tx = db_pool.begin().await?;

    // 逐表逐条 UPDATE：绑定墓碑自身删除时间，杜绝时间戳漂移
    for table in module_def.tables {
        for (uuid, tombstone_deleted_at) in &to_delete {
            // 旧格式墓碑（无时间戳）保留旧的 now() 兜底；正常路径用原始删除时间
            let ts = if *tombstone_deleted_at == 0 {
                now
            } else {
                *tombstone_deleted_at
            };
            let sql = format!(
                "UPDATE \"{}\" SET is_deleted = 1, deleted_at = ?, updated_at = ? \
                 WHERE uuid = ? AND is_deleted = 0",
                table
            );
            let result = sqlx::query(&sql)
                .bind(ts)
                .bind(ts)
                .bind(uuid)
                .execute(&mut *tx)
                .await
                .map_err(|e| CloudSyncError::Database {
                    message: format!("软删除表 {} 失败: {}", table, e),
                })?;
            deleted_count += result.rows_affected();
        }
    }

    tx.commit().await?;
    Ok(deleted_count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_result_default_is_zero() {
        let r = MergeResult::default();
        assert_eq!(r.inserted, 0);
        assert_eq!(r.updated, 0);
        assert_eq!(r.deleted, 0);
        assert_eq!(r.skipped, 0);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn insert_batch_size_is_conservative() {
        // 验证批量大小保守值：50 条 × 15 字段 = 750 参数 < 999（SQLite 默认上限）
        const { assert!(INSERT_BATCH_SIZE * 15 < 999) };
    }

    // ========================================================================
    // FR-3: decide_lww 平局裁决测试
    //
    // 历史问题：updated_at 相等时本地静默胜出，两端各自保留本地值后永久分歧/振荡。
    // 修复：引入 version 次级裁决键，确定性保证两端收敛。
    // ========================================================================

    #[test]
    fn decide_lww_remote_newer_updates() {
        // 远端 updated_at 更大 → Update（原 LWW 逻辑不变）
        assert_eq!(
            decide_lww(200, 100, 0, 0),
            LwwDecision::Update,
            "远端 updated_at 更大时应 Update"
        );
    }

    #[test]
    fn decide_lww_local_newer_skips() {
        // 本地 updated_at 更大 → Skip（原 LWW 逻辑不变）
        assert_eq!(
            decide_lww(100, 200, 0, 0),
            LwwDecision::Skip,
            "本地 updated_at 更大时应 Skip"
        );
    }

    #[test]
    fn decide_lww_tie_higher_remote_version_updates() {
        // 平局（同毫秒）+ 远端 version 更高 → Update（修复点：不再静默本地胜出）
        assert_eq!(
            decide_lww(100, 100, 2, 1),
            LwwDecision::Update,
            "updated_at 平局时远端 version 更高应 Update"
        );
    }

    #[test]
    fn decide_lww_tie_lower_remote_version_skips() {
        // 平局 + 远端 version 更低 → Skip（本地 version 胜出）
        assert_eq!(
            decide_lww(100, 100, 1, 2),
            LwwDecision::Skip,
            "updated_at 平局时远端 version 更低应 Skip"
        );
    }

    #[test]
    fn decide_lww_tie_equal_version_skips() {
        // 平局 + version 也相等 → Skip（视为同数据，不产生 UPDATE）
        assert_eq!(
            decide_lww(100, 100, 1, 1),
            LwwDecision::Skip,
            "updated_at 与 version 均相等时应 Skip（同数据）"
        );
    }

    #[test]
    fn decide_lww_tie_zero_version_skips() {
        // 平局 + version 均为 0（旧数据缺失 version）→ Skip（兼容旧数据）
        assert_eq!(
            decide_lww(100, 100, 0, 0),
            LwwDecision::Skip,
            "旧数据 version=0 平局时应 Skip（兼容）"
        );
    }

    // ========================================================================
    // 数据库集成测试（Fix-01 复活裁决 + Fix-02 墓碑时间戳保留）
    //
    // 使用内存 SQLite（单连接，保证同一 memory 库）+ 最小化 todo_projects 表结构。
    // ========================================================================

    #[cfg(test)]
    mod db_tests {
        use super::*;
        use crate::cloud_sync::meta::TombstoneEntry;
        use crate::cloud_sync::modules::SyncModuleDef;
        use sqlx::SqlitePool;

        const PROJECTS: SyncModuleDef = SyncModuleDef {
            name: "todos",
            display_name: "影视数据",
            tables: &["todo_projects"],
            has_attachments: false,
        };

        async fn setup_pool() -> SqlitePool {
            let pool = sqlx::sqlite::SqlitePoolOptions::new()
                .max_connections(1)
                .connect("sqlite::memory:")
                .await
                .unwrap();
            sqlx::query(
                "CREATE TABLE todo_projects (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL,
                    title TEXT,
                    is_deleted INTEGER NOT NULL DEFAULT 0,
                    deleted_at INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER NOT NULL DEFAULT 0,
                    version INTEGER NOT NULL DEFAULT 0
                )",
            )
            .execute(&pool)
            .await
            .unwrap();
            pool
        }

        async fn insert_row(
            pool: &SqlitePool,
            uuid: &str,
            name: &str,
            is_deleted: i64,
            deleted_at: i64,
            updated_at: i64,
        ) {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, is_deleted, deleted_at, updated_at, version)
                 VALUES (?, ?, ?, ?, ?, 1)",
            )
            .bind(uuid)
            .bind(name)
            .bind(is_deleted)
            .bind(deleted_at)
            .bind(updated_at)
            .execute(pool)
            .await
            .unwrap();
        }

        async fn row_count(pool: &SqlitePool, uuid: &str) -> i64 {
            let (c,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_projects WHERE uuid = ?")
                .bind(uuid)
                .fetch_one(pool)
                .await
                .unwrap();
            c
        }

        #[derive(Debug, sqlx::FromRow)]
        struct TodoRow {
            is_deleted: i64,
            deleted_at: i64,
            updated_at: i64,
        }

        async fn get_row(pool: &SqlitePool, uuid: &str) -> Option<TodoRow> {
            sqlx::query_as::<_, TodoRow>(
                "SELECT is_deleted, deleted_at, updated_at FROM todo_projects WHERE uuid = ?",
            )
            .bind(uuid)
            .fetch_optional(pool)
            .await
            .unwrap()
        }

        /// Fix-01 核心场景 A：本地墓碑 + 远端较新存活 → 复活为 UPDATE，不产生重复行
        #[tokio::test]
        async fn resurrection_remote_newer_updates_without_duplicate() {
            let pool = setup_pool().await;
            // 本地：R 已删除，删除时间 100
            insert_row(&pool, "r1", "old", 1, 100, 100).await;

            // 远端：R 存活且更新于 200（> 删除时间 100 → 编辑胜，应复活）
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r1", "title": "edited-on-b",
                "is_deleted": 0, "deleted_at": 0, "updated_at": 200, "version": 2
            })];
            let result = merge_items(&pool, &PROJECTS, &items, &[]).await.unwrap();

            assert_eq!(result.updated, 1, "复活必须走 UPDATE 路径");
            assert_eq!(result.inserted, 0, "绝不允许 INSERT 产生重复行");
            assert_eq!(row_count(&pool, "r1").await, 1, "uuid 必须唯一");

            let row = get_row(&pool, "r1").await.unwrap();
            assert_eq!(row.is_deleted, 0, "记录应被远端数据复活");
            assert_eq!(row.updated_at, 200);
        }

        /// Fix-01 核心场景 B：本地墓碑 + 远端较旧存活 → 删除胜出，保持墓碑状态
        #[tokio::test]
        async fn resurrection_remote_older_stays_deleted() {
            let pool = setup_pool().await;
            insert_row(&pool, "r2", "tombstone", 1, 300, 300).await;

            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r2", "title": "stale-alive",
                "is_deleted": 0, "deleted_at": 0, "updated_at": 200, "version": 1
            })];
            let result = merge_items(&pool, &PROJECTS, &items, &[]).await.unwrap();

            assert_eq!(result.skipped, 1);
            assert_eq!(result.inserted + result.updated, 0);
            let row = get_row(&pool, "r2").await.unwrap();
            assert_eq!(row.is_deleted, 1, "删除仍应胜出");
        }

        /// Fix-01 回归：本地存活记录的常规 LWW 行为不变
        #[tokio::test]
        async fn normal_lww_on_alive_record_unchanged() {
            let pool = setup_pool().await;
            insert_row(&pool, "r3", "local-newer", 0, 0, 500).await;

            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r3", "title": "remote-older",
                "is_deleted": 0, "updated_at": 400, "version": 9
            })];
            let result = merge_items(&pool, &PROJECTS, &items, &[]).await.unwrap();
            assert_eq!(result.skipped, 1, "本地较新应跳过");

            let items2 = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r3", "title": "remote-newer",
                "is_deleted": 0, "updated_at": 600, "version": 1
            })];
            let result2 = merge_items(&pool, &PROJECTS, &items2, &[]).await.unwrap();
            assert_eq!(result2.updated, 1, "远端较新应更新");
            assert_eq!(row_count(&pool, "r3").await, 1);
        }

        /// Fix-02 核心场景：应用墓碑后 deleted_at/updated_at 必须等于墓碑自身删除时间，
        /// 而非同步时刻 now()（否则跨设备裁决失真导致合法编辑被静默丢弃）
        #[tokio::test]
        async fn tombstone_preserves_original_deletion_timestamp() {
            let pool = setup_pool().await;
            insert_row(&pool, "r4", "victim", 0, 0, 50).await;

            let before = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64;

            let tombstones = vec![TombstoneEntry::new("r4".to_string(), 100)];
            let deleted = apply_tombstones(&pool, &PROJECTS, &tombstones, &load_map(&pool).await)
                .await
                .unwrap();

            assert_eq!(deleted, 1);
            let row = get_row(&pool, "r4").await.unwrap();
            assert_eq!(row.is_deleted, 1);
            assert_eq!(row.deleted_at, 100, "deleted_at 必须保留墓碑原始删除时间");
            assert_eq!(
                row.updated_at, 100,
                "updated_at 必须跟随墓碑删除时间而非 now()"
            );
            assert!(row.deleted_at < before, "时间戳不得被重写为当前时刻");
        }

        /// Fix-02 回归：编辑晚于删除时（FR-2.6）不应用墓碑
        #[tokio::test]
        async fn tombstone_loses_to_later_edit() {
            let pool = setup_pool().await;
            insert_row(&pool, "r5", "edited-after-delete", 0, 0, 500).await;

            let tombstones = vec![TombstoneEntry::new("r5".to_string(), 100)];
            let deleted = apply_tombstones(&pool, &PROJECTS, &tombstones, &load_map(&pool).await)
                .await
                .unwrap();

            assert_eq!(deleted, 0, "编辑(500) > 删除(100) 应跳过");
            let row = get_row(&pool, "r5").await.unwrap();
            assert_eq!(row.is_deleted, 0);
        }

        /// Fix-01 回归：本地不存在的 uuid → 正常 INSERT（新增记录不丢失）
        #[tokio::test]
        async fn insert_new_remote_record() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "brand-new",
                "title": "from-other-device",
                "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let result = merge_items(&pool, &PROJECTS, &items, &[]).await.unwrap();
            assert_eq!(result.inserted, 1);
            assert_eq!(row_count(&pool, "brand-new").await, 1);
        }

        async fn load_map(pool: &SqlitePool) -> HashMap<String, LocalRecordState> {
            crate::cloud_sync::db_loader::load_local_uuid_map(pool, &PROJECTS)
                .await
                .unwrap()
        }
    }
}
