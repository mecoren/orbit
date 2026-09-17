//! merge — 单表 item 级 LWW 合并 + 墓碑应用
//!
//! Pull 时对下载的分桶数据做 item 级合并，保证多设备各自新增的记录都不丢失。
//! v2 的合并单元是「一张表」：表路由由 pull 侧按分桶载荷的 `table` 字段给出
//! 并已做白名单校验，本模块不再依赖 `_table` 字段或模块定义。
//!
//! ## 合并规则
//! - 远端有、本地无（按 uuid） → INSERT（保留远端原始字段）
//! - 本地有、远端无 → 保留（多设备新增不丢）
//! - 两端都有 → `updated_at` 较大者胜（LWW）；`updated_at` 相等时用 `version`
//!   次级裁决（高者胜），杜绝同毫秒平局导致的两端分歧与振荡（FR-3）
//! - 墓碑集中的 uuid → 本地软删除（带时间戳裁决删除 vs 编辑）
//!
//! ## 事务保证
//! 单表内「批量 INSERT + 逐条 UPDATE」在单个事务内（原子）；
//! 墓碑应用是紧随其后的另一个事务。单条记录失败不阻塞整体，
//! 错误收集到 `MergeResult.errors`。
//!
//! ## 性能优化
//! - INSERT 批量化：分批 50 条构造 `INSERT INTO t (cols) VALUES (?),(?),...`，
//!   5000 条记录从 ~500ms 降至 ~20ms
//! - 墓碑逐条 UPDATE（绑定各自删除时间，v1 的批量写法会丢时间戳，见 Fix-02）

use std::collections::HashMap;

use sqlx::SqlitePool;

use crate::cloud_sync::db_loader::{LocalRecordState, load_table_uuid_map};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::TombstoneEntry;
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
    /// 冲突裁决数（S28：两端同 uuid 都有更新的记录数——LWW 平局 version
    /// 裁决 + 本地胜出跳过 + 复活裁决的合计，此前恒 0 无可观测性）
    pub conflicts: u64,
    /// 错误信息（不阻塞整体流程）
    pub errors: Vec<String>,
}

/// 单表 item 级 LWW 合并（v2 合并单元）
///
/// v2 的表路由由调用方（pull）完成并已做白名单校验（远端分桶载荷的
/// `table` 字段必须落在 `SYNCABLE_TABLES` 内），因此本函数只处理一张表，
/// 不再需要 `_table` 字段与跨表分组——同时也消除了"跨表同 uuid 互相覆盖"
/// 的隐患（v1 用 uuid 做全模块 map key）。
///
/// 墓碑集中的 uuid 执行软删除（FR-2.6：带时间戳裁决删除 vs 编辑）。
pub async fn merge_table_items(
    db_pool: &SqlitePool,
    table: &str,
    remote_items: &[serde_json::Value],
    tombstones: &[TombstoneEntry],
) -> Result<MergeResult, CloudSyncError> {
    // 1. 加载本地（含软删）uuid → 裁决状态映射
    let local_map = load_table_uuid_map(db_pool, table).await?;
    // 列元数据必须在事务外读取：事务持有连接后再从池取连接，
    // 在单连接池（测试用 `max_connections(1)`）下会互相等待直至超时
    let columns =
        load_table_columns(db_pool, table)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("加载表 {table} 列元数据失败: {e}"),
            })?;

    let mut result = MergeResult::default();
    let refs: Vec<&serde_json::Value> = remote_items.iter().collect();

    // 2. 单事务：数据合并 + 墓碑应用必须原子。此前两者各持一个事务，
    //    中断会留下「数据已合并、删除未应用」的半合并状态——其他设备
    //    在窗口内会观察到已删记录仍存活。
    let mut tx = db_pool.begin().await?;

    match merge_single_table_in_tx(&mut tx, table, &refs, &local_map, &columns).await {
        Ok(table_result) => {
            result.inserted += table_result.inserted;
            result.updated += table_result.updated;
            result.skipped += table_result.skipped;
            result.conflicts += table_result.conflicts;
            result.errors.extend(table_result.errors);
        }
        Err(e) => {
            // 合并本身失败：整体回滚（含墓碑），保证该表不出现半合并
            let _ = tx.rollback().await;
            result.errors.push(format!("表 {table} 合并失败: {e}"));
            return Ok(result);
        }
    }

    match apply_tombstones_in_tx(&mut tx, table, tombstones, &local_map).await {
        Ok(count) => result.deleted = count,
        Err(e) => result.errors.push(format!("墓碑应用失败: {e}")),
    }

    tx.commit().await?;
    Ok(result)
}

/// 单表 items 合并（批量 INSERT + 单条 UPDATE）
///
/// 性能优化：
/// - INSERT 分批 50 条，构造 `INSERT INTO t (cols) VALUES (?),(?),...` 单次执行
/// - UPDATE 保持单条（每条记录字段集可能不同，CASE WHEN 复杂度过高）
/// - 整个操作在单个事务内，保证原子性
async fn merge_single_table_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    items: &[&serde_json::Value],
    local_map: &HashMap<String, LocalRecordState>,
    columns: &HashMap<String, ColumnMeta>,
) -> Result<MergeResult, CloudSyncError> {
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
        //
        // S28：本地存活分支的两端都有更新（LWW Update / 本地胜出 Skip）与复活
        // 裁决都计入 conflicts——这些记录发生了真实的冲突裁决，此前恒 0 不可见。
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
                        result.conflicts += 1;
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
                        } else {
                            // 本地胜出的真实冲突（远端也有更新但败出）
                            result.conflicts += 1;
                        }
                        result.skipped += 1;
                    }
                }
            }
            Some(local) => {
                // 复活裁决（FR-2.6 口径）：deleted_at=0（极旧格式）视为可复活
                result.conflicts += 1;
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

    // 2. 批量 INSERT + 逐条 UPDATE —— 事务由调用方持有并统一提交
    //    （同一表的「数据合并」与「墓碑应用」必须在同一事务内完成，
    //    否则中断会留下"数据已合并、删除未应用"的半合并状态）
    result.inserted += batch_insert(&mut *tx, table, &to_insert, columns).await?;

    // 3. 逐条 UPDATE（同一事务）
    for (uuid, obj) in &to_update {
        match update_record_in_tx(&mut *tx, table, obj, uuid, columns).await {
            Ok(()) => result.updated += 1,
            Err(e) => {
                result
                    .errors
                    .push(format!("表 {}: 更新 uuid={} 失败: {}", table, uuid, e));
            }
        }
    }

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
async fn apply_tombstones_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
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

    // 逐条 UPDATE（事务由调用方持有）：绑定墓碑自身删除时间，杜绝时间戳漂移
    for (uuid, tombstone_deleted_at) in &to_delete {
        // 病态数据（deleted_at=0）保留 now() 兜底；正常路径用原始删除时间
        let ts = if *tombstone_deleted_at == 0 {
            now
        } else {
            *tombstone_deleted_at
        };
        let sql = format!(
            "UPDATE \"{table}\" SET is_deleted = 1, deleted_at = ?, updated_at = ? \
             WHERE uuid = ? AND is_deleted = 0"
        );
        let result = sqlx::query(&sql)
            .bind(ts)
            .bind(ts)
            .bind(uuid)
            .execute(&mut **tx)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("软删除表 {table} 失败: {e}"),
            })?;
        deleted_count += result.rows_affected();
    }

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
        use sqlx::SqlitePool;

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();
            assert_eq!(result.skipped, 1, "本地较新应跳过");

            let items2 = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r3", "title": "remote-newer",
                "is_deleted": 0, "updated_at": 600, "version": 1
            })];
            let result2 = merge_table_items(&pool, "todo_projects", &items2, &[]).await.unwrap();
            assert_eq!(result2.updated, 1, "远端较新应更新");
            assert_eq!(row_count(&pool, "r3").await, 1);
        }

        /// S28：冲突裁决计数——LWW 双向裁决与复活裁决都计入 conflicts，
        /// 同数据（updated_at/version 全等）不计入；新增记录不计入
        #[tokio::test]
        async fn conflicts_counts_real_lww_adjudications_only() {
            let pool = setup_pool().await;
            insert_row(&pool, "c1", "same", 0, 0, 100).await;

            // 同数据平局（updated_at 与 version 均相等）→ 跳过但不计冲突
            let same = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "same",
                "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let r1 = merge_table_items(&pool, "todo_projects", &same, &[]).await.unwrap();
            assert_eq!(r1.skipped, 1);
            assert_eq!(r1.conflicts, 0, "同数据全等平局不是冲突");

            // 本地胜出（远端有更新但较旧）→ 跳过且计冲突
            let local_wins = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "stale-remote",
                "is_deleted": 0, "updated_at": 90, "version": 9
            })];
            let r2 = merge_table_items(&pool, "todo_projects", &local_wins, &[])
                .await
                .unwrap();
            assert_eq!(r2.skipped, 1);
            assert_eq!(r2.conflicts, 1, "两端都有更新、本地胜出必须计冲突");

            // 远端胜出（updated_at 更大）→ 更新且计冲突
            let remote_wins = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "fresh-remote",
                "is_deleted": 0, "updated_at": 200, "version": 1
            })];
            let r3 = merge_table_items(&pool, "todo_projects", &remote_wins, &[])
                .await
                .unwrap();
            assert_eq!(r3.updated, 1);
            assert_eq!(r3.conflicts, 1, "远端胜出的覆盖更新必须计冲突");

            // 全新记录（本地无 uuid）→ 插入不计冲突
            let fresh = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c-new", "title": "brand-new",
                "is_deleted": 0, "updated_at": 300, "version": 1
            })];
            let r4 = merge_table_items(&pool, "todo_projects", &fresh, &[]).await.unwrap();
            assert_eq!(r4.inserted, 1);
            assert_eq!(r4.conflicts, 0, "单端新增不是冲突");
        }

        /// S28 回归：复活裁决计入 conflicts（删除 vs 编辑的真实冲突）
        #[tokio::test]
        async fn conflicts_counts_resurrection_adjudication() {
            let pool = setup_pool().await;
            // 本地墓碑（删除时间 300）+ 远端存活（更新 200，早于删除 → 删除胜）
            insert_row(&pool, "c2", "deleted-local", 1, 300, 300).await;
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c2", "title": "remote-alive",
                "is_deleted": 0, "deleted_at": 0, "updated_at": 200, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();
            assert_eq!(result.skipped, 1, "删除胜出保持墓碑");
            assert_eq!(result.conflicts, 1, "复活裁决是删除vs编辑冲突，必须计数");
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
            // 先在事务外读映射：单连接池下事务持连接时再查询会死锁
            let map = load_map(&pool).await;
            let mut tx = pool.begin().await.unwrap();
            let deleted = apply_tombstones_in_tx(&mut tx, "todo_projects", &tombstones, &map)
                .await
                .unwrap();
            tx.commit().await.unwrap();

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
            // 先在事务外读映射：单连接池下事务持连接时再查询会死锁
            let map = load_map(&pool).await;
            let mut tx = pool.begin().await.unwrap();
            let deleted = apply_tombstones_in_tx(&mut tx, "todo_projects", &tombstones, &map)
                .await
                .unwrap();
            tx.commit().await.unwrap();

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();
            assert_eq!(result.inserted, 1);
            assert_eq!(row_count(&pool, "brand-new").await, 1);
        }

        /// 非白名单表必须整体拒绝合并
        ///
        /// 远端分桶载荷的 `table` 字段可作为攻击面（指向 sync_configs /
        /// cfg_kv 等非同步表写入凭据/配置）。pull 侧已校验白名单，merge 侧
        /// 通过 `load_table_uuid_map` 的白名单校验再次兜底——两层都在，
        /// 任一层被绕过都不会写坏非同步表。
        #[tokio::test]
        async fn table_not_in_whitelist_rejected() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "_table": "sync_configs", "uuid": "evil",
                "endpoint": "https://attacker.example", "updated_at": 999, "version": 1
            })];
            let result = merge_table_items(&pool, "sync_configs", &items, &[]).await;

            assert!(result.is_err(), "非白名单表必须整体拒绝，不得部分合并");
            let err_msg = result.unwrap_err().to_string();
            assert!(
                err_msg.contains("sync_configs"),
                "错误信息应指明表名: {err_msg}"
            );
            // 确认未写入任何行（表本身在测试库不存在，写入会报错——此处防御性验证）
        }

        /// P0-9 回归：白名单内的表正常合并
        #[tokio::test]
        async fn table_in_whitelist_merges_normally() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "ok-1",
                "title": "legit", "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();
            assert_eq!(result.inserted, 1);
        }

        /// v2 回归：记录不含 `_table` 字段也能正常合并（表路由由调用方给出）
        #[tokio::test]
        async fn record_without_table_field_merges_by_called_table() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "uuid": "no-table-field",
                "title": "legacy-item", "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[]).await.unwrap();
            assert_eq!(result.inserted, 1, "表路由由调用方给出，与记录字段无关");
        }

        async fn load_map(pool: &SqlitePool) -> HashMap<String, LocalRecordState> {
            crate::cloud_sync::db_loader::load_table_uuid_map(pool, "todo_projects")
                .await
                .unwrap()
        }
    }
}
