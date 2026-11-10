//! merge — 单表 item 级 LWW 合并 + 墓碑应用
//!
//! Pull 时对下载的分桶数据做 item 级合并，保证多设备各自新增的记录都不丢失。
//! 合并单元是「一张表」：表路由由 pull 侧按分桶载荷的 `table` 字段给出
//! 并已做白名单校验，本模块不再依赖 `_table` 字段或模块定义。
//!
//! ## 合并规则
//! - 远端有、本地无（按 uuid） → INSERT（保留远端原始字段）
//! - 本地有、远端无 → 保留（多设备新增不丢）
//! - 两端都有 → `updated_at` 较大者胜（LWW）；`updated_at` 相等时用 `version`
//!   次级裁决（高者胜），杜绝同毫秒平局导致的两端分歧与振荡（FR-3）
//! - 墓碑集中的 uuid → 本地软删除（带时间戳裁决删除 vs 编辑）
//! - 整数外键列 → 按载荷 `_fk` 里的父行 uuid 解析成本端 id（F47，
//!   见 [`resolve_foreign_keys`]）；解析不出来即整表上报 Err 交由下轮重试
//!
//! ## 逻辑时钟（HLC 折叠实现）
//! 每条远端记录的 `updated_at` 与每个墓碑的 `deleted_at` 都经
//! [`crate::db::clock::observe_ms`] 并入本地逻辑时钟（HLC receive 规则）：此后
//! 本地写入必然大于「已见过的最大值」，设备间时钟漂移带来的系统性 LWW 偏置
//! 在首次同步后即被消除。比较逻辑本身不变（仍是 `updated_at` + `version` 次序，
//! 只是这把键由墙上时钟换成了单调逻辑时钟）。
//!
//! ## 冲突败方副本
//! 裁决丢掉的败方字段过去直接消失（只有计数可见）。现在会把**真并发冲突**的
//! 败方整行快照留档到本地表 `sync_conflicts`（同事务，见 `api::sync_conflict_api`）。
//! 「真并发」判据：本地记录与远端记录都晚于上次同步成功时的逻辑时钟
//! （`baseline_ms`，来自 `SyncState.last_synced_clock_ms`）；他端顺延更新
//! （本地自上次同步后没动过）不算冲突，避免把每次跨端同步都灌成噪声。
//!
//! ## 事务保证
//! 单表内「批量 INSERT + 逐条 UPDATE」在单个事务内（原子）；
//! 墓碑应用是紧随其后的另一个事务。单条记录失败不阻塞整体，
//! 错误收集到 `MergeResult.errors`。
//!
//! ## 性能优化
//! - INSERT 批量化：分批 50 条构造 `INSERT INTO t (cols) VALUES (?),(?),...`，
//!   5000 条记录从 ~500ms 降至 ~20ms
//! - 墓碑逐条 UPDATE（绑定各自删除时间，批量写法会丢时间戳，见 Fix-02）

use std::collections::HashMap;

use sqlx::SqlitePool;

use crate::api::sync_conflict_api::{
    ConflictSnapshot, insert_conflict_in_tx, payload_json_of, prune_in_tx, record_title_of,
};
use crate::cloud_sync::db_loader::{
    FK_MARK, LocalRecordState, load_table_uuid_map, load_uuid_id_map, sqlite_row_to_json,
};
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
    /// 用户可见冲突数 = 真并发裁决并成功留档的条数
    ///
    /// 2026-11-10 起与 `copied` 恒等：旧实现把「他端顺延更新」与「删除 vs 编辑
    /// 复活裁决」也计入，导致 `SyncResult.conflicts` 有值而 `sync_conflicts`
    /// 表 0 行（toast 说 N 条冲突、冲突中心空列表）。现在只有双方都晚于上次
    /// 同步基线（真并发）且败方副本成功落库才计数。
    pub conflicts: u64,
    /// 留档的败方副本数（与 `conflicts` 同源，保留字段便于桥层分别展示）
    pub copied: u64,
    /// 错误信息（不阻塞整体流程）
    pub errors: Vec<String>,
}

/// 单表 item 级 LWW 合并（合并单元）
///
/// 表路由由调用方（pull）完成并已做白名单校验（远端分桶载荷的
/// `table` 字段必须落在 `SYNCABLE_TABLES` 内），因此本函数只处理一张表，
/// 不再需要 `_table` 字段与跨表分组——同时也消除了"跨表同 uuid 互相覆盖"
/// 的隐患（曾用 uuid 做全模块 map key）。
///
/// 墓碑集中的 uuid 执行软删除（FR-2.6：带时间戳裁决删除 vs 编辑）。
///
/// `baseline_ms`：上次同步成功时的本地逻辑时钟（`SyncState.last_synced_clock_ms`），
/// 用于判定「真并发冲突」并据此留档败方副本；传 0（从未同步/测试）时不留档。
pub async fn merge_table_items(
    db_pool: &SqlitePool,
    table: &str,
    remote_items: &[serde_json::Value],
    tombstones: &[TombstoneEntry],
    baseline_ms: i64,
) -> Result<MergeResult, CloudSyncError> {
    // 0. 接收远端时间戳（HLC receive 规则）：先于任何裁决，保证本轮之后的本地
    //    写入必然大于已见值（含墓碑删除时间——删除 vs 编辑裁决同样依赖它）
    for item in remote_items {
        if let Some(ts) = item.get("updated_at").and_then(|v| v.as_i64()) {
            crate::db::clock::observe_ms(ts);
        }
    }
    for t in tombstones {
        crate::db::clock::observe_ms(t.deleted_at());
    }

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

    // 1.5 整数外键按父行 uuid 解析为本端 id（F47）；父表 uuid→id 同样须在事务外读。
    //     无外键的叶子表直接借用原切片，省掉整表克隆。
    //
    //     墓碑物化（空库首次全量 pull）同样需要这份映射：墓碑载荷里的外键是**源端
    //     整数 id**，不解析就会把子行挂到本端的另一行上（静默改父）。故映射提到
    //     事务外统一加载，数据合并与墓碑应用共用。
    let fk_cols = crate::db::sync_registry::fk_columns_of(table);
    let mut parent_ids: HashMap<&'static str, HashMap<String, i64>> = HashMap::new();
    for (_, parent) in fk_cols {
        if !parent_ids.contains_key(parent) {
            parent_ids.insert(*parent, load_uuid_id_map(db_pool, parent).await?);
        }
    }
    let resolved: Vec<serde_json::Value>;
    let refs: Vec<&serde_json::Value> = if fk_cols.is_empty() {
        remote_items.iter().collect()
    } else {
        resolved = resolve_foreign_keys(table, remote_items, &parent_ids)?;
        resolved.iter().collect()
    };

    let mut result = MergeResult::default();

    // 2. 单事务：数据合并 + 墓碑应用必须原子。此前两者各持一个事务，
    //    中断会留下「数据已合并、删除未应用」的半合并状态——其他设备
    //    在窗口内会观察到已删记录仍存活。
    let mut tx = db_pool.begin().await?;

    match merge_single_table_in_tx(&mut tx, table, &refs, &local_map, &columns, baseline_ms).await {
        Ok(table_result) => {
            result.inserted += table_result.inserted;
            result.updated += table_result.updated;
            result.skipped += table_result.skipped;
            result.conflicts += table_result.conflicts;
            result.copied += table_result.copied;
            result.errors.extend(table_result.errors);
        }
        Err(e) => {
            // 合并本身失败：整体回滚（含墓碑）并**上报 Err**——此前降级为
            // Ok(errors) 会让调用方把该表记为成功、账本刷成新指纹，回滚掉的
            // 内容永不再下载（静默空洞）；上报 Err 才能进 failed_modules
            let _ = tx.rollback().await;
            return Err(e);
        }
    }

    match apply_tombstones_in_tx(&mut tx, table, tombstones, &parent_ids, &columns).await {
        Ok((count, errors)) => {
            result.deleted = count;
            result.errors.extend(errors);
        }
        Err(e) => {
            // 墓碑应用失败：只记 errors 仍 commit 恰好留下本文件开头禁止的
            // 「数据已合并、删除未应用」半合并；回滚整表上报 Err 同口径
            let _ = tx.rollback().await;
            return Err(e);
        }
    }

    tx.commit().await?;
    Ok(result)
}

/// 把载荷里的整数外键换成本端 id（F47）
///
/// 输入是 [`load_table_items`] 注入过 `_fk: {外键列: 父行 uuid}` 的记录；
/// 返回**去掉 `_fk`、外键列已解析**的副本，之后的 INSERT/UPDATE 路径看到的
/// 就是本端可用的值。
///
/// 任意外键解析不出来即整表 `Err`（宁可不合并、让 pull 记为失败表下轮重试），
/// 也不能写一个「本端存在但归属错误」的 id：那会静默改父，并且下一轮 push
/// 会把错归属洗成看起来合法的 uuid 标记，把污染扩散到云端与其它设备。
/// 两种失败都要报：
/// - 缺 `_fk` 键：载荷由未带 F47 修复的旧客户端写出（此时整数不可信）；
/// - 父 uuid 本端没有：父行本轮未到（pull 已按注册表父先子后定序，故多为
///   对端该表推送失败），下轮父行到达即可自愈。
///
/// [`load_table_items`]: crate::cloud_sync::db_loader::load_table_items
fn resolve_foreign_keys(
    table: &str,
    items: &[serde_json::Value],
    parent_ids: &HashMap<&'static str, HashMap<String, i64>>,
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    let fk_cols = crate::db::sync_registry::fk_columns_of(table);
    let mut out = Vec::with_capacity(items.len());

    for item in items {
        let Some(obj) = item.as_object() else {
            // 非对象记录交给下游按「记录不是 JSON 对象」报错，这里不改变语义
            out.push(item.clone());
            continue;
        };
        let Some(mark) = obj.get(FK_MARK).and_then(|v| v.as_object()) else {
            return Err(CloudSyncError::Database {
                message: format!(
                    "表 {table} 的云端记录缺少外键 uuid 标记：载荷由旧版客户端写出，\
                     请在其余设备升级应用后重试（本端未写入，避免按整数 id 误挂父级）"
                ),
            });
        };
        let mut row = obj.clone();
        for (col, parent) in fk_cols {
            // 外键为 NULL / 非整数：无父级可解析，原样保留
            if row.get(*col).and_then(|v| v.as_i64()).is_none() {
                continue;
            }
            let Some(uuid) = mark.get(*col).and_then(|v| v.as_str()) else {
                return Err(CloudSyncError::Database {
                    message: format!(
                        "表 {table} 记录 {} 的外键 {col} 无 uuid 标记（对端旧版载荷）",
                        obj.get("uuid").and_then(|v| v.as_str()).unwrap_or("?")
                    ),
                });
            };
            match parent_ids.get(parent).and_then(|m| m.get(uuid)) {
                Some(local_id) => {
                    row.insert((*col).to_string(), serde_json::Value::from(*local_id));
                }
                None => {
                    return Err(CloudSyncError::Database {
                        message: format!(
                            "表 {table} 记录 {} 的父级 {parent}/{uuid} 本端不存在\
                             （对端该表本轮未同步成功），下轮重试",
                            obj.get("uuid").and_then(|v| v.as_str()).unwrap_or("?")
                        ),
                    });
                }
            }
        }
        row.remove(FK_MARK);
        out.push(serde_json::Value::Object(row));
    }

    Ok(out)
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
    baseline_ms: i64,
) -> Result<MergeResult, CloudSyncError> {
    let mut result = MergeResult::default();

    // 1. 分类：待 INSERT 和待 UPDATE
    let mut to_insert: Vec<&serde_json::Map<String, serde_json::Value>> = Vec::new();
    let mut to_update: Vec<(&str, &serde_json::Map<String, serde_json::Value>)> = Vec::new();
    // 真并发冲突的败方副本快照（数据写入完成后同事务落库）
    let mut snapshots: Vec<ConflictSnapshot> = Vec::new();

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
                // 真并发判据：双方记录都晚于上次同步基线（基线 0 = 从未同步，不留档）
                let concurrent = baseline_ms > 0
                    && local.updated_at > baseline_ms
                    && remote_updated > baseline_ms;
                let tie = remote_updated == local.updated_at;

                match decision {
                    LwwDecision::Update => {
                        // 远端胜出（updated_at 更大，或平局时 version 更高）→ UPDATE
                        let uuid_ref = obj.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
                        // 平局裁决时输出 warn 日志，便于排查（非平局的正常 Update 不打日志）
                        if tie {
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
                        // 本地被覆盖：把本地旧版本留档（必须在 UPDATE 之前读）
                        if concurrent
                            && let Some(local_obj) =
                                load_local_payload(&mut *tx, table, &uuid).await
                        {
                            // 冲突计数只统计**真并发**裁决，与 sync_conflicts 留档一一对应。
                            // 旧实现无条件 +1，把「他端顺延更新、本端自上次同步后没动过」
                            // 的普通同步也计成冲突 → toast/历史显示 N 条冲突而冲突中心 0 条。
                            result.conflicts += 1;
                            snapshots.push(build_snapshot(
                                table,
                                &uuid,
                                if tie { "tie_version" } else { "lww" },
                                "local",
                                &local_obj,
                                obj,
                            ));
                        }
                        to_update.push((uuid_ref, obj));
                    }
                    LwwDecision::Skip => {
                        // 本地胜出或数据相同 → 跳过
                        if tie && remote_version == local.version {
                            log::debug!(
                                "[merge] LWW 完全平局：表 {} uuid={} updated_at 与 version 均相等，跳过",
                                table,
                                uuid
                            );
                        } else if concurrent
                            && let Some(local_obj) =
                                load_local_payload(&mut *tx, table, &uuid).await
                        {
                            // 本地胜出的真并发冲突：远端版本被丢弃，留档并计数
                            result.conflicts += 1;
                            snapshots.push(build_snapshot(
                                table,
                                &uuid,
                                if tie { "tie_version" } else { "lww" },
                                "remote",
                                obj,
                                &local_obj,
                            ));
                        }
                        result.skipped += 1;
                    }
                }
            }
            Some(local) => {
                // 复活裁决（FR-2.6 口径）：deleted_at=0（极旧格式）视为可复活。
                // 删除 vs 编辑的败方是「墓碑/存活记录」而非两版内容，不做副本留档，
                // 也**不计入 conflicts**——`conflicts` 与 `sync_conflicts` 表一一对应
                // （用户可见的冲突留档），把删除裁决也计进去会让「冲突 N 条」与冲突
                // 中心列表条数对不上。裁决结果仍逐条写 log 供排查。
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

    // 4. 冲突败方副本落库（同事务：与合并结果原子，避免「数据已覆盖、副本没留」）
    if !snapshots.is_empty() {
        for snapshot in &snapshots {
            match insert_conflict_in_tx(tx, snapshot).await {
                Ok(()) => result.copied += 1,
                Err(e) => result
                    .errors
                    .push(format!("表 {table}: 冲突副本留档失败: {e}")),
            }
        }
        if let Err(e) = prune_in_tx(tx).await {
            result.errors.push(format!("冲突副本裁剪失败: {e}"));
        }
    }

    Ok(result)
}

/// 读取本地整行（含软删行）快照，供冲突副本留档
///
/// 只有在判定为真并发冲突时才调用（低频），因此不把整行塞进
/// [`LocalRecordState`]——那会让每轮 pull 都把全表内容物化成 JSON。
async fn load_local_payload(
    conn: &mut sqlx::SqliteConnection,
    table: &str,
    uuid: &str,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let sql = format!("SELECT * FROM \"{table}\" WHERE uuid = ? LIMIT 1");
    match sqlx::query(&sql).bind(uuid).fetch_optional(conn).await {
        Ok(Some(row)) => Some(sqlite_row_to_json(&row)),
        Ok(None) => None,
        Err(e) => {
            log::warn!("[merge] 读取本地记录快照失败（表 {table} uuid={uuid}）: {e}");
            None
        }
    }
}

/// 组装冲突副本快照（标题优先取胜方，便于列表里认出是哪条记录）
///
/// 两侧时间戳直接从整行载荷里的 `updated_at` 取——载荷就是**留档的那一版本身**，
/// 另传参数会留下「记录的裁决时间与实际留档内容不一致」的口子。
fn build_snapshot(
    table: &str,
    uuid: &str,
    decision: &str,
    loser_side: &str,
    loser_obj: &serde_json::Map<String, serde_json::Value>,
    winner_obj: &serde_json::Map<String, serde_json::Value>,
) -> ConflictSnapshot {
    let ts_of = |obj: &serde_json::Map<String, serde_json::Value>| {
        obj.get("updated_at").and_then(|v| v.as_i64()).unwrap_or(0)
    };
    let winner_title = record_title_of(winner_obj);
    let title = if winner_title.is_empty() {
        record_title_of(loser_obj)
    } else {
        winner_title
    };
    ConflictSnapshot {
        table_name: table.to_string(),
        record_uuid: uuid.to_string(),
        record_title: title,
        decision: decision.to_string(),
        loser_side: loser_side.to_string(),
        winner_side: if loser_side == "local" {
            "remote".to_string()
        } else {
            "local".to_string()
        },
        loser_payload: payload_json_of(loser_obj),
        winner_payload: payload_json_of(winner_obj),
        loser_updated_at: ts_of(loser_obj),
        winner_updated_at: ts_of(winner_obj),
    }
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
                    //
                    // F58：规范化失败必须**上抛**（与下方 `update_record_in_tx` 同口径）。
                    // 此前这里把 `Err` 折成 `Value::Null` 直接落库：远端 `"done": "true"`
                    // （布尔被序列化成字符串）、`"deleted_at": "2026/01/01"`（本地化日期串）
                    // 这类被 `normalize_value` 拒绝的类型漂移会静默写成 NULL——不报错、
                    // 不进 `sync_conflicts`，而本地 version 已随本次合并推进，用户看到的是
                    // 「某些字段在同步后凭空被清空」且无任何可追线索。
                    let normalized = match columns.get(*col_name) {
                        Some(m) => {
                            normalize_value(val, m).map_err(|e| CloudSyncError::Database {
                                message: format!(
                                    "批量 INSERT 表 {} 列 {} 类型规范化失败: {}",
                                    table, col_name, e
                                ),
                            })?
                        }
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
    parent_ids: &HashMap<&'static str, HashMap<String, i64>>,
    columns: &HashMap<String, ColumnMeta>,
) -> Result<(u64, Vec<String>), CloudSyncError> {
    if tombstones.is_empty() {
        return Ok((0, Vec::new()));
    }

    let mut deleted_count = 0u64;
    let mut errors: Vec<String> = Vec::new();
    let now = crate::cloud_sync::db_loader::now_ms();

    for tombstone in tombstones {
        let uuid = tombstone.uuid();
        if uuid.is_empty() {
            continue;
        }
        // 病态数据（deleted_at=0）保留 now() 兜底；正常路径用原始删除时间
        let raw_deleted_at = tombstone.deleted_at();
        let ts = if raw_deleted_at == 0 {
            now
        } else {
            raw_deleted_at
        };
        // updated_at 优先取**源端整行快照**里的值：墓碑是搬运真实行状态，不能用
        // 删除时间覆盖源端的 updated_at（否则源端两值不等的行在三端字段不一致）。
        // 旧墓碑没有快照时回退删除时间（Fix-02 的「不得写成 now()」口径仍成立）。
        let new_updated = tombstone
            .payload
            .as_ref()
            .and_then(|p| p.get("updated_at"))
            .and_then(|v| v.as_i64())
            .filter(|v| *v > 0)
            .unwrap_or(ts);

        // ── 1) 已有存活行：时间戳裁决后软删 ──
        //
        // 判据直接写在 WHERE 里（而不是先用事务外加载的 local_map 过滤）：
        // 本轮数据合并可能**刚 INSERT** 了同一个 uuid 的存活行（他端的旧数据桶
        // 与本端墓碑并存），local_map 是合并前快照，看不到这批新行，旧实现会
        // 把墓碑跳过 → 已删记录在对端复活。
        //
        // `? = 0` 分支对应旧格式墓碑（deleted_at 缺失）：无条件删除，保持旧行为。
        let sql = format!(
            "UPDATE \"{table}\" SET is_deleted = 1, deleted_at = ?, updated_at = ? \
             WHERE uuid = ? AND is_deleted = 0 AND (? = 0 OR ? >= updated_at)"
        );
        let result = sqlx::query(&sql)
            .bind(ts)
            .bind(new_updated)
            .bind(uuid)
            .bind(raw_deleted_at)
            .bind(raw_deleted_at)
            .execute(&mut **tx)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("软删除表 {table} 失败: {e}"),
            })?;
        if result.rows_affected() > 0 {
            deleted_count += 1;
            continue;
        }

        // ── 2) 行仍在（已删除 / 本地编辑胜出）→ 无需动作 ──
        let exists: Option<i64> = sqlx::query_scalar(&format!(
            "SELECT 1 FROM \"{table}\" WHERE uuid = ? LIMIT 1"
        ))
        .bind(uuid)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("查询表 {table} 墓碑行失败: {e}"),
        })?;
        if exists.is_some() {
            continue;
        }

        // ── 3) 本地完全没有这一行（换机 / 空库首次全量 pull）→ 物化软删行 ──
        //
        // 这是 2026-11-10 端到端测试暴露的缺口：墓碑原先只带 uuid + deleted_at，
        // 空库没有行可「打标记」，799 条软删任务在另一端整行消失（回收站 799 vs 0）。
        match materialize_tombstone_row(
            tx,
            table,
            uuid,
            ts,
            new_updated,
            tombstone.payload.as_ref(),
            parent_ids,
            columns,
        )
        .await
        {
            Ok(true) => {
                log::info!("[merge] 物化墓碑行：表 {table} uuid={uuid} deleted_at={ts}");
                deleted_count += 1;
            }
            Ok(false) => {
                log::warn!(
                    "[merge] 墓碑无法物化（旧版墓碑无整行快照且该表有必填外键）：\
                     表 {table} uuid={uuid}。升级写出方后重新同步即可补齐"
                );
            }
            Err(e) => {
                errors.push(format!("表 {table}: 物化墓碑 uuid={uuid} 失败: {e}"));
            }
        }
    }

    Ok((deleted_count, errors))
}

/// 空库物化一条软删行（墓碑迁移路径）
///
/// 两个来源：
/// - **带整行快照**（2026-11-10 起的新墓碑）：整行落地，外键按 `_fk` 父行 uuid
///   解析成本端 id——子表（子任务/评论/提醒/关系/附件）也能正确物化。
/// - **无快照**（历史墓碑/旧客户端）：仅当该表所有 NOT NULL 列都有 DEFAULT 时，
///   用 `uuid + 删除时间` 建一条最小占位行（项目/任务/标签/筛选器/模板属于此类）。
///   子表需要 task_id 等现象外键，没有快照就无从还原，返回 `Ok(false)` 交给
///   调用方记 warn。
///
/// 返回 `Ok(true)` 表示确实插入了行。
#[allow(clippy::too_many_arguments)] // 物化一条墓碑所需的最小上下文
async fn materialize_tombstone_row(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    uuid: &str,
    ts: i64,
    updated_at: i64,
    payload: Option<&serde_json::Value>,
    parent_ids: &HashMap<&'static str, HashMap<String, i64>>,
    columns: &HashMap<String, ColumnMeta>,
) -> Result<bool, String> {
    let mut row: serde_json::Map<String, serde_json::Value> = match payload {
        Some(serde_json::Value::Object(obj)) => obj.clone(),
        _ => {
            // 无整行快照：只有「必填列全带默认值」的表能建最小占位行
            let has_required_without_default = columns
                .values()
                .any(|m| m.not_null && m.dflt_value.is_none());
            if has_required_without_default {
                return Ok(false);
            }
            let mut m = serde_json::Map::new();
            m.insert("uuid".to_string(), serde_json::Value::from(uuid));
            m.insert("created_at".to_string(), serde_json::Value::from(ts));
            m
        }
    };

    // 强制删除态：payload 里可能带着 is_deleted=0；updated_at 用源端原值
    // （搬运真实行状态，不能用删除时间覆盖，否则源端两值不等的行三端不一致）
    row.insert("uuid".to_string(), serde_json::Value::from(uuid));
    row.insert("is_deleted".to_string(), serde_json::Value::from(1));
    row.insert("deleted_at".to_string(), serde_json::Value::from(ts));
    row.insert("updated_at".to_string(), serde_json::Value::from(updated_at));
    row.remove("id");
    if row.get("created_at").and_then(|v| v.as_i64()).is_none() {
        row.insert("created_at".to_string(), serde_json::Value::from(ts));
    }
    if row.get("version").and_then(|v| v.as_i64()).is_none() {
        row.insert("version".to_string(), serde_json::Value::from(1));
    }

    // 外键解析：载荷里的整数外键是源端 id，必须换成父行 uuid 对应的本端 id
    let resolved_row = if row.contains_key(FK_MARK) {
        let mut resolved = resolve_foreign_keys(table, &[serde_json::Value::Object(row)], parent_ids)
            .map_err(|e| e.to_string())?;
        match resolved.pop() {
            Some(serde_json::Value::Object(o)) => o,
            _ => return Ok(false),
        }
    } else {
        row
    };

    // 复用批量 INSERT 的列校验 / 类型规范化 / id 跳过逻辑
    let inserted = batch_insert(tx, table, &[&resolved_row], columns)
        .await
        .map_err(|e| e.to_string())?;
    Ok(inserted > 0)
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
        assert_eq!(r.conflicts, 0);
        assert_eq!(r.copied, 0);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn insert_batch_size_is_conservative() {
        // 验证批量大小保守值：50 条 × 15 字段 = 750 参数 < 999（SQLite 默认上限）
        const { assert!(INSERT_BATCH_SIZE * 15 < 999) };
    }

    // ========================================================================
    // F47：整数外键跨设备搬运
    //
    // 线上事故形态不是 `FOREIGN KEY constraint failed`，而是**静默改父**：远端
    // task_id=1 在本端恰好是另一行，约束检查直接通过。故这组用例断言的是
    // 「本端按父行 uuid 解析出的 id」，并额外断言它不等于远端那个整数。
    // 连接池显式开 FK，口径对齐 `db::pool::init_pool_unencrypted`。
    // ========================================================================

    mod fk_cross_device {
        use super::*;
        use crate::cloud_sync::db_loader::load_table_items;

        async fn pool() -> SqlitePool {
            let p = sqlx::sqlite::SqlitePoolOptions::new()
                .max_connections(1)
                .acquire_timeout(std::time::Duration::from_secs(30))
                .connect("sqlite::memory:")
                .await
                .unwrap();
            sqlx::migrate!("./src/db/migrations").run(&p).await.unwrap();
            sqlx::query("PRAGMA foreign_keys=ON")
                .execute(&p)
                .await
                .unwrap();
            p
        }

        /// A 端：项目 + 任务 + 子任务 + 评论（外键一律用子查询取真实本端 id）
        async fn seed_device_a(a: &SqlitePool) {
            for sql in [
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at, version) \
                 VALUES ('p-a', 'A的项目', 1000, 1000, 1)",
                "INSERT INTO todo_tasks (uuid, title, project_id, created_at, updated_at, version) \
                 VALUES ('t-a', 'A的任务', (SELECT id FROM todo_projects WHERE uuid='p-a'), 1001, 1001, 1)",
                "INSERT INTO todo_subtasks (uuid, task_id, title, created_at, updated_at, version) \
                 VALUES ('s-a', (SELECT id FROM todo_tasks WHERE uuid='t-a'), 'A的子任务', 1002, 1002, 1)",
                "INSERT INTO todo_comments (uuid, task_id, content, created_at, updated_at, version) \
                 VALUES ('c-a', (SELECT id FROM todo_tasks WHERE uuid='t-a'), 'A的评论', 1003, 1003, 1)",
            ] {
                sqlx::query(sql).execute(a).await.unwrap();
            }
        }

        /// B 端：自建任务占住低位 id，使「远端整数」与「本端正确 id」必然不同
        async fn seed_device_b(b: &SqlitePool) {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at, version) \
                 VALUES ('p-b', 'B的项目', 900, 900, 1)",
            )
            .execute(b)
            .await
            .unwrap();
            for uuid in ["t-b1", "t-b2"] {
                sqlx::query(
                    "INSERT INTO todo_tasks (uuid, title, created_at, updated_at, version) \
                     VALUES (?1, 'B本地任务', 901, 901, 1)",
                )
                .bind(uuid)
                .execute(b)
                .await
                .unwrap();
            }
        }

        async fn id_of(db: &SqlitePool, table: &str, uuid: &str) -> i64 {
            sqlx::query_scalar::<_, i64>(&format!("SELECT id FROM {table} WHERE uuid=?1"))
                .bind(uuid)
                .fetch_one(db)
                .await
                .unwrap()
        }

        async fn fk_of(db: &SqlitePool, table: &str, uuid: &str, col: &str) -> Option<i64> {
            sqlx::query_scalar::<_, Option<i64>>(&format!(
                "SELECT {col} FROM {table} WHERE uuid=?1"
            ))
            .bind(uuid)
            .fetch_optional(db)
            .await
            .unwrap()
            .flatten()
        }

        /// 表遍历顺序：注册表声明序（父先子后），与 pull 的定序口径一致
        async fn pull_all(a: &SqlitePool, b: &SqlitePool) -> Result<(), CloudSyncError> {
            for table in crate::db::sync_registry::SYNCABLE_TABLES {
                let items = load_table_items(a, table).await?;
                if items.is_empty() {
                    continue;
                }
                merge_table_items(b, table, &items, &[], 0).await?;
            }
            Ok(())
        }

        #[tokio::test]
        async fn loader_marks_parents_by_uuid() {
            let a = pool().await;
            seed_device_a(&a).await;

            let tasks = load_table_items(&a, "todo_tasks").await.unwrap();
            let task = tasks
                .iter()
                .find(|t| t["uuid"] == serde_json::json!("t-a"))
                .expect("A 端任务");
            assert_eq!(
                task["_fk"]["project_id"],
                serde_json::json!("p-a"),
                "外键列必须附父行 uuid，而不是只有本地自增 id"
            );

            // 外键为 NULL 的行：_fk 键必须存在且为空对象（区别于旧格式载荷的「键缺失」）
            sqlx::query(
                "INSERT INTO todo_tasks (uuid, title, created_at, updated_at, version) \
                 VALUES ('t-x', '无项目', 1, 1, 1)",
            )
            .execute(&a)
            .await
            .unwrap();
            let after = load_table_items(&a, "todo_tasks").await.unwrap();
            let x = after
                .iter()
                .find(|t| t["uuid"] == serde_json::json!("t-x"))
                .unwrap();
            assert_eq!(
                x.get(crate::cloud_sync::db_loader::FK_MARK),
                Some(&serde_json::json!({}))
            );
            assert!(x["project_id"].is_null());
        }

        #[tokio::test]
        async fn children_land_on_local_parent_ids_not_remote_ints() {
            let (a, b) = (pool().await, pool().await);
            seed_device_a(&a).await;
            seed_device_b(&b).await;
            pull_all(&a, &b).await.expect("跨端合并应成功");

            let local_task = id_of(&b, "todo_tasks", "t-a").await;
            let local_project = id_of(&b, "todo_projects", "p-a").await;
            // A 端整数：task.id 与 project.id（若被原样搬运就会挂到 B 的别的行上）
            let remote_task = id_of(&a, "todo_tasks", "t-a").await;
            let remote_project = id_of(&a, "todo_projects", "p-a").await;

            assert_eq!(
                fk_of(&b, "todo_tasks", "t-a", "project_id").await,
                Some(local_project)
            );
            assert_eq!(
                fk_of(&b, "todo_subtasks", "s-a", "task_id").await,
                Some(local_task)
            );
            assert_eq!(
                fk_of(&b, "todo_comments", "c-a", "task_id").await,
                Some(local_task)
            );

            // 夹具自检：两端 id 必须不同，否则「等于本端 id」与「等于远端整数」无法区分
            assert_ne!(local_task, remote_task, "夹具须保证两端任务 id 不同");
            assert_ne!(local_project, remote_project, "夹具须保证两端项目 id 不同");
            // B 自建任务不得被劫持为 A 子行的父级
            assert_ne!(
                local_task,
                id_of(&b, "todo_tasks", "t-b1").await,
                "B 本地任务 t-b1 不应成为 A 子任务的父级"
            );
        }

        #[tokio::test]
        async fn legacy_payload_without_fk_mark_is_rejected() {
            let (a, b) = (pool().await, pool().await);
            seed_device_a(&a).await;
            seed_device_b(&b).await;

            let mut items = load_table_items(&a, "todo_subtasks").await.unwrap();
            for it in &mut items {
                if let Some(obj) = it.as_object_mut() {
                    obj.remove(crate::cloud_sync::db_loader::FK_MARK);
                }
            }
            let err = merge_table_items(&b, "todo_subtasks", &items, &[], 0)
                .await
                .expect_err("旧格式载荷（无外键标记）必须报错，不能按整数落库");
            let msg = err.to_string();
            assert!(msg.contains("旧版"), "错误信息要指升级方向: {msg}");
            assert!(
                fk_of(&b, "todo_subtasks", "s-a", "task_id").await.is_none(),
                "报错路径不得留下半行数据"
            );
        }

        #[tokio::test]
        async fn unresolvable_parent_reports_error_instead_of_wrong_id() {
            let (a, b) = (pool().await, pool().await);
            seed_device_a(&a).await;
            seed_device_b(&b).await;

            // 只合子表、父表本轮没到（对端 todo_tasks 推送失败的真实形态）
            let items = load_table_items(&a, "todo_subtasks").await.unwrap();
            let err = merge_table_items(&b, "todo_subtasks", &items, &[], 0)
                .await
                .expect_err("父级缺失不能静默写整数 id");
            assert!(
                err.to_string().contains("父级 todo_tasks/t-a"),
                "错误信息要点名缺失的父表与父 uuid: {err}"
            );
            assert!(
                fk_of(&b, "todo_subtasks", "s-a", "task_id").await.is_none(),
                "解析失败即整表不写，B 端不得多出半行子任务"
            );
        }
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
            // 用真实迁移建库：冲突败方副本需要 sync_conflicts 表，
            // 且手搓的极简 todo_projects 与线上列集不一致会掩盖列裁剪问题
            sqlx::migrate!("./src/db/migrations")
                .run(&pool)
                .await
                .unwrap();
            // 迁移种子会插入「收件箱」行；本模块断言的是 uuid 精确查询，
            // 但 resurrections 等用例按 uuid 定位，不受种子影响
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
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert_eq!(result.skipped, 1, "本地较新应跳过");

            let items2 = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "r3", "title": "remote-newer",
                "is_deleted": 0, "updated_at": 600, "version": 1
            })];
            let result2 = merge_table_items(&pool, "todo_projects", &items2, &[], 0)
                .await
                .unwrap();
            assert_eq!(result2.updated, 1, "远端较新应更新");
            assert_eq!(row_count(&pool, "r3").await, 1);
        }

        /// 冲突计数只统计**真并发**裁决，且与 `sync_conflicts` 留档一一对应
        ///
        /// 旧口径把「他端顺延更新」（本端自上次同步后没动过）也计成冲突，
        /// 端到端测试实测 `SyncResult.conflicts=1` 而三端 `sync_conflicts` 0 行。
        #[tokio::test]
        async fn conflicts_counts_real_lww_adjudications_only() {
            let pool = setup_pool().await;
            insert_row(&pool, "c1", "same", 0, 0, 100).await;

            // 同数据平局（updated_at 与 version 均相等）→ 跳过但不计冲突
            let same = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "same",
                "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let r1 = merge_table_items(&pool, "todo_projects", &same, &[], 50)
                .await
                .unwrap();
            assert_eq!(r1.skipped, 1);
            assert_eq!(r1.conflicts, 0, "同数据全等平局不是冲突");

            // 本地胜出（两端都晚于基线 50）→ 跳过、计冲突、留档远端败方
            let local_wins = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "stale-remote",
                "is_deleted": 0, "updated_at": 90, "version": 9
            })];
            let r2 = merge_table_items(&pool, "todo_projects", &local_wins, &[], 50)
                .await
                .unwrap();
            assert_eq!(r2.skipped, 1);
            assert_eq!(r2.conflicts, 1, "真并发本地胜出必须计冲突");
            assert_eq!(r2.copied, 1, "计数必须与留档同源");

            // 远端胜出（两端都晚于基线）→ 更新、计冲突、留档本地败方
            let remote_wins = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c1", "title": "fresh-remote",
                "is_deleted": 0, "updated_at": 200, "version": 1
            })];
            let r3 = merge_table_items(&pool, "todo_projects", &remote_wins, &[], 50)
                .await
                .unwrap();
            assert_eq!(r3.updated, 1);
            assert_eq!(r3.conflicts, 1, "真并发远端胜出必须计冲突");
            assert_eq!(r3.copied, 1);

            // 全新记录（本地无 uuid）→ 插入不计冲突
            let fresh = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c-new", "title": "brand-new",
                "is_deleted": 0, "updated_at": 300, "version": 1
            })];
            let r4 = merge_table_items(&pool, "todo_projects", &fresh, &[], 50)
                .await
                .unwrap();
            assert_eq!(r4.inserted, 1);
            assert_eq!(r4.conflicts, 0, "单端新增不是冲突");
        }

        /// 顺延传播（本端自上次同步后未改动）不得计冲突
        #[tokio::test]
        async fn sequential_remote_update_is_not_a_conflict() {
            let pool = setup_pool().await;
            insert_row(&pool, "c-seq", "旧值", 0, 0, 40).await;
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c-seq", "title": "他端更新",
                "is_deleted": 0, "updated_at": 200, "version": 2
            })];
            let r = merge_table_items(&pool, "todo_projects", &items, &[], 50)
                .await
                .unwrap();
            assert_eq!(r.updated, 1, "数据照常更新");
            assert_eq!(r.conflicts, 0, "他端顺延更新不是用户冲突");
            assert_eq!(r.copied, 0);
        }

        /// 复活裁决不写留档，也不计入 conflicts（否则「冲突 N 条」与冲突中心对不上）
        #[tokio::test]
        async fn resurrection_is_logged_but_not_counted_as_conflict() {
            let pool = setup_pool().await;
            // 本地墓碑（删除时间 300）+ 远端存活（更新 200，早于删除 → 删除胜）
            insert_row(&pool, "c2", "deleted-local", 1, 300, 300).await;
            let items = vec![serde_json::json!({
                "_table": "todo_projects", "uuid": "c2", "title": "remote-alive",
                "is_deleted": 0, "deleted_at": 0, "updated_at": 200, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert_eq!(result.skipped, 1, "删除胜出保持墓碑");
            assert_eq!(result.conflicts, 0, "复活裁决不产生用户可见冲突留档");
            assert_eq!(result.copied, 0);
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
            let deleted =
                apply_tombstones(&pool, "todo_projects", &tombstones, &HashMap::new()).await;

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
            let deleted =
                apply_tombstones(&pool, "todo_projects", &tombstones, &HashMap::new()).await;

            assert_eq!(deleted, 0, "编辑(500) > 删除(100) 应跳过");
            let row = get_row(&pool, "r5").await.unwrap();
            assert_eq!(row.is_deleted, 0);
        }

        /// **P0 回归（2026-11-10 端到端测试）**：空库首次全量 pull 必须物化软删行
        ///
        /// 旧行为：墓碑只带 uuid + deleted_at，空库没有本地行可标记 →
        /// `todo_tasks` 40,000 vs 39,201、回收站 799 vs 0（换机后删除记录凭空消失）。
        /// 新行为：墓碑带整行快照，本地缺失即 INSERT 一条 `is_deleted=1` 行。
        #[tokio::test]
        async fn tombstone_materializes_missing_row_from_payload() {
            let pool = setup_pool().await;
            let payload = serde_json::json!({
                "uuid": "gone-1", "title": "已删项目", "hex_color": "#EF4444",
                "sort_order": 3, "is_archived": 0, "is_deleted": 1,
                "deleted_at": 170, "created_at": 10, "updated_at": 170, "version": 4
            });
            let tombstones = vec![TombstoneEntry::with_payload(
                "gone-1".to_string(),
                170,
                payload,
            )];
            let deleted =
                apply_tombstones(&pool, "todo_projects", &tombstones, &HashMap::new()).await;

            assert_eq!(deleted, 1, "空库必须物化墓碑行");
            let row = get_row(&pool, "gone-1").await.unwrap();
            assert_eq!(row.is_deleted, 1, "物化行必须是软删态");
            assert_eq!(row.deleted_at, 170);
            assert_eq!(row.updated_at, 170);
            let (title,): (String,) =
                sqlx::query_as("SELECT title FROM todo_projects WHERE uuid='gone-1'")
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            assert_eq!(title, "已删项目", "整行快照的字段要原样落地");
        }

        /// 旧墓碑没有整行快照：父表（必填列全带默认值）用最小占位行兜底
        #[tokio::test]
        async fn tombstone_without_payload_falls_back_to_minimal_row() {
            let pool = setup_pool().await;
            let tombstones = vec![TombstoneEntry::new("legacy-1".to_string(), 90)];
            let deleted =
                apply_tombstones(&pool, "todo_projects", &tombstones, &HashMap::new()).await;

            assert_eq!(deleted, 1, "父表必须用最小占位行兜底");
            let row = get_row(&pool, "legacy-1").await.unwrap();
            assert_eq!(row.is_deleted, 1);
            assert_eq!(row.deleted_at, 90);
        }

        /// 旧墓碑 + 子表（task_id 等必填外键无默认值）：无从还原，跳过而不报错
        #[tokio::test]
        async fn legacy_tombstone_on_child_table_is_skipped() {
            let pool = setup_pool().await;
            let tombstones = vec![TombstoneEntry::new("legacy-comment".to_string(), 90)];
            let deleted =
                apply_tombstones(&pool, "todo_comments", &tombstones, &HashMap::new()).await;
            assert_eq!(deleted, 0, "缺少父级信息时不得凭空造子行");
            let (c,): (i64,) =
                sqlx::query_as("SELECT COUNT(*) FROM todo_comments WHERE uuid='legacy-comment'")
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            assert_eq!(c, 0);
        }

        /// 数据桶里的存活行与本端墓碑同轮到达：墓碑必须胜出（不得复活）
        ///
        /// 旧实现在事务外加载 local_map 判定，看不到本轮刚 INSERT 的行，墓碑被跳过；
        /// 现在的裁决写在 UPDATE 的 WHERE 里，对本轮新插入行同样生效。
        #[tokio::test]
        async fn tombstone_applies_to_row_inserted_in_same_round() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "uuid": "race-1", "title": "他端旧数据", "is_deleted": 0,
                "deleted_at": 0, "updated_at": 50, "version": 1
            })];
            let tombstones = vec![TombstoneEntry::new("race-1".to_string(), 60)];
            merge_table_items(&pool, "todo_projects", &items, &tombstones, 0)
                .await
                .unwrap();

            let row = get_row(&pool, "race-1").await.unwrap();
            assert_eq!(row.is_deleted, 1, "删除时间 60 > 数据更新时间 50，墓碑必须胜出");
            assert_eq!(row.deleted_at, 60);
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
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
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
            let result = merge_table_items(&pool, "sync_configs", &items, &[], 0).await;

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
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert_eq!(result.inserted, 1);
        }

        /// 回归：记录不含 `_table` 字段也能正常合并（表路由由调用方给出）
        #[tokio::test]
        async fn record_without_table_field_merges_by_called_table() {
            let pool = setup_pool().await;
            let items = vec![serde_json::json!({
                "uuid": "no-table-field",
                "title": "legacy-item", "is_deleted": 0, "updated_at": 100, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert_eq!(result.inserted, 1, "表路由由调用方给出，与记录字段无关");
        }

        /// F58 回归：列值类型规范化失败必须**上抛**，不得把该列静默写成 NULL
        ///
        /// 旧行为（`batch_insert` 把 `normalize_value` 的 `Err` 折成 `Value::Null`）：
        /// 对**可空**列这一步会真的落库且不报错。场景是「对端把墓碑时间序列化成本地化
        /// 日期串」——`deleted_at` 被写成 NULL，删除时间戳静默消失，而 version 已随
        /// 本轮合并推进，事后无任何痕迹可追（既不报错也不进 `sync_conflicts`）。
        /// NOT NULL 列（如 `is_archived`）旧行为会在 execute 阶段撞约束报错，
        /// 算不上静默，故用例针对可空列。
        #[tokio::test]
        async fn unparsable_column_value_aborts_instead_of_writing_null() {
            let pool = setup_pool().await;
            // 非 ISO（`2026/01/01`）且非整数 → normalize_value 无法转成 INTEGER
            let items = vec![serde_json::json!({
                "uuid": "bad-type-1", "title": "类型漂移",
                "is_deleted": 1, "deleted_at": "2026/01/01",
                "updated_at": 100, "version": 1
            })];

            let err = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .expect_err("规范化失败必须报错，不得静默写 NULL");
            let msg = err.to_string();
            assert!(
                msg.contains("类型规范化失败") && msg.contains("deleted_at"),
                "错误信息应点明列名与成因: {msg}"
            );

            // 整表回滚：旧行为会在库里留下一行 deleted_at=NULL
            assert_eq!(
                row_count(&pool, "bad-type-1").await,
                0,
                "失败的表必须整表回滚"
            );
        }

        /// 测试辅助：按生产口径（事务 + 列元数据 + 外键映射）应用一批墓碑
        async fn apply_tombstones(
            pool: &SqlitePool,
            table: &str,
            tombstones: &[TombstoneEntry],
            parent_ids: &HashMap<&'static str, HashMap<String, i64>>,
        ) -> u64 {
            let columns = load_table_columns(pool, table).await.unwrap();
            let mut tx = pool.begin().await.unwrap();
            let (deleted, errors) =
                apply_tombstones_in_tx(&mut tx, table, tombstones, parent_ids, &columns)
                    .await
                    .unwrap();
            tx.commit().await.unwrap();
            assert!(errors.is_empty(), "墓碑物化不应产生错误: {errors:?}");
            deleted
        }

        // ====================================================================
        // 冲突败方副本（03 文档 §八 遗留项兑现）
        //
        // 留档判据是「真并发」：本地与远端都晚于上次同步基线；
        // 基线 0（从未同步）/ 单侧改动 都不留档。
        // ====================================================================

        /// 读取最近一条冲突副本（loser_side, winner_side, record_title, loser_payload, decision）
        async fn latest_conflict(
            pool: &SqlitePool,
        ) -> Option<(String, String, String, String, String)> {
            sqlx::query_as(
                "SELECT loser_side, winner_side, record_title, loser_payload, decision
                 FROM sync_conflicts ORDER BY id DESC LIMIT 1",
            )
            .fetch_optional(pool)
            .await
            .unwrap()
        }

        async fn conflict_count(pool: &SqlitePool) -> i64 {
            let (c,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM sync_conflicts")
                .fetch_one(pool)
                .await
                .unwrap();
            c
        }

        /// 基线 0（从未同步）不留档：两端各自独立的数据集合不是冲突
        #[tokio::test]
        async fn no_conflict_copy_without_sync_baseline() {
            let pool = setup_pool().await;
            insert_row(&pool, "b1", "local", 0, 0, 200).await;
            let items = vec![serde_json::json!({
                "uuid": "b1", "title": "remote", "is_deleted": 0, "deleted_at": 0,
                "updated_at": 300, "version": 2
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert_eq!(result.updated, 1);
            assert_eq!(
                result.conflicts, 0,
                "无同步基线（从未同步）不是用户冲突，计数与留档同为 0"
            );
            assert_eq!(result.copied, 0, "无同步基线不得留档");
            assert_eq!(conflict_count(&pool).await, 0);
        }

        /// 真并发 + 远端胜出 → 留档「本地被覆盖的那一版」
        #[tokio::test]
        async fn concurrent_remote_win_copies_local_loser() {
            let pool = setup_pool().await;
            insert_row(&pool, "c10", "本地旧标题", 0, 0, 200).await;
            let items = vec![serde_json::json!({
                "uuid": "c10", "title": "远端新标题", "is_deleted": 0, "deleted_at": 0,
                "updated_at": 300, "version": 5
            })];
            // 基线 100：本地(200) 与远端(300) 都在其之后 → 真并发
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 100)
                .await
                .unwrap();
            assert_eq!(result.updated, 1);
            assert_eq!(result.copied, 1);

            let (loser, winner, title, payload, decision) = latest_conflict(&pool).await.unwrap();
            assert_eq!(loser, "local", "本地被覆盖的是败方");
            assert_eq!(winner, "remote");
            assert_eq!(title, "远端新标题", "标题取胜方，便于认出是哪条记录");
            assert_eq!(decision, "lww");
            assert!(
                payload.contains("本地旧标题"),
                "败方载荷必须是本地旧值: {payload}"
            );
        }

        /// 真并发 + 本地胜出 → 留档「远端被丢弃的那一版」
        #[tokio::test]
        async fn concurrent_local_win_copies_remote_loser() {
            let pool = setup_pool().await;
            insert_row(&pool, "c11", "本地新标题", 0, 0, 300).await;
            let items = vec![serde_json::json!({
                "uuid": "c11", "title": "远端旧标题", "is_deleted": 0, "deleted_at": 0,
                "updated_at": 200, "version": 1
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 100)
                .await
                .unwrap();
            assert_eq!(result.skipped, 1);
            assert_eq!(result.copied, 1);

            let (loser, winner, title, payload, _) = latest_conflict(&pool).await.unwrap();
            assert_eq!(loser, "remote", "远端被丢弃的是败方");
            assert_eq!(winner, "local");
            assert_eq!(title, "本地新标题");
            assert!(
                payload.contains("远端旧标题"),
                "败方载荷必须是远端旧值: {payload}"
            );
        }

        /// 非并发（本地自上次同步后没动过）→ 他端顺延更新不留档
        #[tokio::test]
        async fn sequential_remote_update_records_no_copy() {
            let pool = setup_pool().await;
            insert_row(&pool, "c12", "旧", 0, 0, 50).await;
            let items = vec![serde_json::json!({
                "uuid": "c12", "title": "他端更新", "is_deleted": 0, "deleted_at": 0,
                "updated_at": 300, "version": 2
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 100)
                .await
                .unwrap();
            assert_eq!(result.updated, 1, "数据照常更新");
            assert_eq!(
                result.copied, 0,
                "本地记录早于基线说明本轮只是顺延传播，不是冲突"
            );
        }

        /// 平局（同毫秒）按 version 裁决时，decision 记为 tie_version 且同样留档
        #[tokio::test]
        async fn tie_break_conflict_is_copied_with_tie_decision() {
            let pool = setup_pool().await;
            // 本地 version=1，远端 version=2 → 远端胜
            insert_row(&pool, "c13", "本地", 0, 0, 500).await;
            let items = vec![serde_json::json!({
                "uuid": "c13", "title": "远端", "is_deleted": 0, "deleted_at": 0,
                "updated_at": 500, "version": 2
            })];
            let result = merge_table_items(&pool, "todo_projects", &items, &[], 100)
                .await
                .unwrap();
            assert_eq!(result.copied, 1);
            let (_, _, _, _, decision) = latest_conflict(&pool).await.unwrap();
            assert_eq!(decision, "tie_version");
        }

        /// HLC receive：合并后本地逻辑时钟必须追平显著超前的远端时间戳，
        /// 否则慢表后续写入会继续败给同一个已见值（漂移偏置无法消除）
        #[tokio::test]
        async fn merge_observes_remote_clock() {
            let pool = setup_pool().await;
            insert_row(&pool, "c14", "本地", 0, 0, 100).await;
            // 远端时间戳领先本地逻辑时钟 1 秒（模拟对端时钟稍快）
            let ahead = crate::db::clock::peek() + 1_000;
            let items = vec![serde_json::json!({
                "uuid": "c14", "title": "远端", "is_deleted": 0, "deleted_at": 0,
                "updated_at": ahead, "version": 2
            })];
            merge_table_items(&pool, "todo_projects", &items, &[], 0)
                .await
                .unwrap();
            assert!(
                crate::db::clock::peek() >= ahead,
                "合并必须把远端时间戳并入本地逻辑时钟"
            );
            assert!(
                crate::db::clock::next_ms() > ahead,
                "此后本地写入必须严格大于已见的远端值"
            );
        }
    }
}
