//! push — 差量上传（表级分桶 + 清单 CAS）
//!
//! ## 流程
//! 1. 读远端清单 `manifest.orsync`（含并发令牌 ETag）
//! 2. 逐表：加载未删行 → 稳定哈希分桶 → 与清单桶索引比对 fingerprint →
//!    **只上传变化的桶**（未变桶零流量）
//! 3. 墓碑：按本地时区月份分桶 → 同上差量上传
//! 4. 组装新清单（`epoch + 1`，登记本机检查点）→ 条件写（`If-Match`）
//! 5. 条件失败（他端并发写入）→ 重新读取清单后**基于新清单重算**并重试，
//!    上限 [`CAS_MAX_RETRIES`] 次；仍失败则保留本地待下轮
//!
//! ## 为什么不会覆盖他端数据
//! 新清单 = **远端清单的拷贝** + 本地有数据的桶覆盖。远端有、本地无的桶
//! 条目**原样保留**（不删除）。删除语义始终由墓碑条目表达，由 pull 侧的
//! LWW / 复活裁决消费——因此多设备并发 push 不再出现"后写者把前写者
//! 新增的行整块抹掉"的窗口。
//!
//! N39（2026-10-14）在该口径上开一条**有证据的**例外：本地已无存活行、且核对
//! 证明「该桶远端内容本机全已删（逐行有本地墓碑）」的桶，条目从清单剔除、云端
//! 对象在清单落定后删除。判据与安全论证见 [`build_table_outcome`]。
//!
//! ## 空数据覆盖守卫
//! 本地全空 + 远端已有数据时阻断 push（删库重装后 sync_state.json 残留的
//! 场景），要求走恢复流程而非静默清空云端。

use std::collections::{BTreeMap, HashMap};

use sqlx::SqlitePool;

use crate::cloud_sync::chunk::{ChunkPayload, TableChunk, split_table_items};
use crate::cloud_sync::crypto_io::{
    decrypt_bucket_payload, decrypt_payload, encrypt_bucket_payload, encrypt_payload,
};
use crate::cloud_sync::db_loader::{
    LocalBucketScan, load_table_items, load_table_items_of, load_table_tombstones, now_ms,
    scan_local_buckets,
};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::{
    ChunkRef, Manifest, TableIndex, TombstoneBucketPayload, TombstoneBucketRef, TombstoneIndex,
};
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{ProgressBuilder, ProgressSender, SyncOrigin};
use crate::cloud_sync::state::{SyncState, SyncStateStore};
use crate::db::sync_registry::SYNCABLE_TABLES;
use crate::sync_adapters::traits::{SyncAdapter, UploadOutcome, UploadPrecondition};
use crate::sync_crypto::SyncCryptoService;

/// 清单 CAS 冲突后的最大重试次数
pub const CAS_MAX_RETRIES: u32 = 3;

/// 单轮最多核对的「本地已空、远端仍有条目」分桶数（N39）
///
/// 每次核对要下载并解密一个分桶，故设上界：未核对到的桶留待下轮（条目仍在，
/// 行为等价于本轮不做收口），避免一次同步把几十个陈旧桶全拉一遍。
const MAX_EMPTY_BUCKET_CHECKS: usize = 8;

/// Push 执行结果
#[derive(Debug, Clone, Default)]
pub struct PushResult {
    /// 实际推送的模块数（有桶上传即为 1，保持 UI 计数语义）
    pub pushed_modules: u32,
    /// 跳过的模块数（无任何变化）
    pub skipped_modules: u32,
    /// 失败的模块数（表级错误隔离）
    pub failed_modules: u32,
    /// 失败信息
    pub errors: Vec<String>,
    /// 实际上传的数据分桶数
    pub pushed_chunks: u32,
    /// 实际跳过（指纹未变）的数据分桶数
    pub skipped_chunks: u32,
    /// 实际上传的墓碑分桶数
    pub pushed_tombstones: u32,
    /// 本轮是否成功写入清单
    pub manifest_written: bool,
    /// 清单 CAS 冲突发生次数
    pub cas_conflicts: u32,
}

/// 执行差量 Push
///
/// `skip_tables`：本轮须跳过的表（Pull 阶段失败的表，本地仍是旧快照，
/// 重传会覆盖云端新数据）。
pub async fn push_all(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    device_id: &str,
    skip_tables: &[String],
) -> Result<PushResult, CloudSyncError> {
    push_all_impl(
        db_pool,
        crypto,
        state_store,
        adapter,
        progress_sender,
        origin,
        device_id,
        skip_tables,
        false,
        // 增量 push：单表失败只隔离该表（其余表继续），失败表由下轮重试
        false,
    )
    .await
}

/// 强制全量 Push（rekey 场景专用）
///
/// 桶指纹是**明文内容**的哈希、与密钥无关——换密钥后远端清单指纹照旧
/// 命中，增量路径会跳过全部桶且 `changed_any=false` 连清单都不重加密，
/// 云端整体停留在旧 Key 密文（他端一律 KeyMismatch）。本入口无视指纹
/// 比对：全桶重传 + 清单必写，`state_store.clear()` 只是辅助语义。
pub async fn push_all_force_full(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    device_id: &str,
    skip_tables: &[String],
) -> Result<PushResult, CloudSyncError> {
    push_all_impl(
        db_pool,
        crypto,
        state_store,
        adapter,
        progress_sender,
        origin,
        device_id,
        skip_tables,
        true,
        // F49：rekey 全量重传必须全表成功才换清单——部分失败落盘会留下
        // 「新 Key 清单 + 旧 Key 分桶」的混合态，全体设备解密失败
        true,
    )
    .await
}

async fn push_all_impl(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    device_id: &str,
    skip_tables: &[String],
    force: bool,
    require_all_tables_ok: bool,
) -> Result<PushResult, CloudSyncError> {
    let state = match state_store.load() {
        Ok(s) => s,
        Err(e) => {
            log::warn!("[push] 本地账本不可用，退化为完整比对: {e}");
            Default::default()
        }
    };
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    let tables: Vec<&str> = SYNCABLE_TABLES
        .iter()
        .copied()
        .filter(|t| !skip_tables.iter().any(|s| s == t))
        .collect();

    if !skip_tables.is_empty() {
        log::info!(
            "[push] 跳过本轮 Pull 失败的表（防陈旧数据覆盖云端）: {:?}",
            skip_tables
        );
    }

    let builder = ProgressBuilder::new(progress_sender, origin);
    builder.starting(tables.len() as u32);

    // F41：本轮水位线上界——本轮开始时刻的逻辑时钟快照。成功保存账本时
    // 写入 `last_synced_clock_ms`：所有 `updated_at ≤ 本值` 的本地写入都在
    // 本轮推送范围内；本轮开始**之后**的新写入必然大于本值，下轮重新算脏
    // 时仍命中，因此不存在"计算脏集合后本地又改"的漏传窗口。
    let clock_mark = crate::db::clock::next_ms();

    // F41：按水位线预计算每表分桶扫描结果（CAS 重试轮次间复用）。
    // 水位线 ≤ 0（首同步 / 账本缺失 / 时钟未加载）与扫描失败都退化为全量。
    let mut bucket_scans: HashMap<&str, Option<LocalBucketScan>> = HashMap::new();
    for table in &tables {
        let scan = if force {
            None
        } else {
            // 水位线用 push 专用字段（不是 last_synced_clock_ms）：后者在 pull
            // 结束时会推进到本轮结束时刻，复用它会把「本轮开始前的本地编辑」
            // 判成非脏而漏传（fault_matrix four_ops_converge 曾据此翻红）
            match scan_local_buckets(db_pool, table, state.last_pushed_clock_ms).await {
                Ok(scan) => scan,
                Err(e) => {
                    log::warn!("[push] 表 {table} 分桶扫描失败，退化为完整比对: {e}");
                    None
                }
            }
        };
        bucket_scans.insert(table, scan);
    }

    let mut result = PushResult::default();
    let mut cas_attempt = 0u32;

    loop {
        // 1. 读远端清单（顺带拿并发令牌与原始密文，后者用于保留回滚点）
        //    F64：force（rekey）轮容忍「清单用当前 Key 解不开」→ 空清单起步
        let (remote_manifest, remote_token, remote_raw) =
            read_remote_manifest_opt(adapter, &data_key, force).await?;

        // 2. 空数据覆盖守卫（远端有数据 + 本地全空 + 曾同步过 → 阻断）
        guard_against_empty_overwrite(db_pool, &state, &remote_manifest).await?;

        // 3. 逐表差量计算 + 上传（每轮重算，保证 CAS 冲突后基于新清单收敛）
        let mut attempt = PushResult::default();
        let mut new_manifest = remote_manifest.clone();
        let mut outcomes: Vec<Result<TableOutcome, TableError>> = Vec::with_capacity(tables.len());
        for (idx, table) in tables.iter().enumerate() {
            // F36：模块名与显示名按表定位，不再硬编码单模块文案
            let module = crate::cloud_sync::modules::module_for_table(table);
            builder.pushing(
                module.name,
                module.display_name,
                idx as u32 + 1,
                tables.len() as u32,
            );
            let scan = bucket_scans.get(*table).and_then(|scan| scan.as_ref());
            outcomes.push(
                build_table_outcome(
                    db_pool,
                    adapter,
                    &data_key,
                    &remote_manifest,
                    table,
                    force,
                    scan,
                    &state.undeletable_chunks,
                )
                .await,
            );
        }

        // N39：本轮从清单剔除的空桶（清单落定后才删其云端对象）与核对备忘
        let mut attempt_removed: Vec<(String, u32)> = Vec::new();
        let mut attempt_undeletable: BTreeMap<String, BTreeMap<u32, String>> = BTreeMap::new();

        for outcome in outcomes {
            match outcome {
                Ok(o) => {
                    attempt.pushed_chunks += o.pushed_chunks;
                    attempt.skipped_chunks += o.skipped_chunks;
                    attempt.pushed_tombstones += o.pushed_tombstones;
                    if o.changed {
                        attempt.pushed_modules = 1;
                    }
                    for bucket in &o.removed_buckets {
                        attempt_removed.push((o.table.clone(), *bucket));
                    }
                    attempt_undeletable.insert(o.table.clone(), o.undeletable);
                    new_manifest.tables.insert(o.table.clone(), o.table_index);
                    new_manifest
                        .tombstones
                        .insert(o.table.clone(), o.tombstone_index);
                }
                Err(e) => {
                    attempt.failed_modules += 1;
                    log::warn!(
                        "[push] 表 {} push 失败（隔离不中断）: {}",
                        e.table,
                        e.message
                    );
                    attempt
                        .errors
                        .push(format!("表 {} push 失败: {}", e.table, e.message));
                }
            }
        }

        // 全部表失败：不上传清单（避免"说谎的清单"）
        if !tables.is_empty() && attempt.failed_modules as usize == tables.len() {
            return Err(CloudSyncError::Other {
                message: format!(
                    "全部 {} 张表 push 失败，未更新清单: {:?}",
                    tables.len(),
                    attempt.errors
                ),
            });
        }

        // F49（2026-09-30 第六轮）：rekey 必须「全表成功才换清单」。
        // 清单用**新** Data Key 加密，而失败表的分桶对象仍是**旧** Key 密文
        // （对象路径由桶号决定、非内容寻址，force 是原地覆盖）——清单一旦落盘
        // 就是「新 Key 清单指向旧 Key 分桶」的混合态，全体设备（含本机）解密
        // 失败被引到恢复页。故此检查必须在**写清单之前**：此前它放在
        // `engine::rekey_cloud_reencrypt_inner` 里，位于本函数返回之后，防线落空。
        if require_all_tables_ok && attempt.failed_modules > 0 {
            return Err(CloudSyncError::Other {
                message: format!(
                    "rekey 全量重传有 {} 个模块失败，已在写入清单前中断（云端清单与 config \
                     仍为旧 Key，已重加密的分桶待重试覆盖）: {:?}",
                    attempt.failed_modules, attempt.errors
                ),
            });
        }

        // F48（2026-09-30 第六轮）：本轮是否「干净」。任一表 push 失败都会让该表的
        // 脏桶没能上传（表级失败只进 errors、不外抛）；此时**不得**推进 push
        // 水位线——否则这些桶下轮被 `bucket_is_unchanged`（行数相等 + 无晚于
        // 水位线的行）判为「逐字节一致」而永久跳过，本地编辑静默漏传。
        // 与 F24 对 `last_synced_at` 建立的「不干净轮次不推进」纪律同源。
        let round_clean = attempt.failed_modules == 0;

        // N39：核对备忘合并（两条保存路径都要带上，否则「不可剔除」的结论每轮重算）
        let merged_undeletable =
            merge_undeletable_memo(&state, &attempt_undeletable, &attempt_removed);

        // 4. 无任何变化 → 不写清单（避免 epoch 空转与无意义流量）；
        //    force（rekey）下清单必须重加密落盘，不受此短路影响
        //    N39：剔除空桶同样是「清单有变更」，必须走写清单路径——否则对象
        //    被删而清单仍引用它，他端 pull 会 404
        let changed_any = force
            || attempt.pushed_chunks > 0
            || attempt.pushed_tombstones > 0
            || !attempt_removed.is_empty();
        if !changed_any {
            attempt.skipped_modules = 1;
            attempt.cas_conflicts = result.cas_conflicts;
            result = attempt;
            if round_clean {
                let mut next_state = state.clone();
                next_state.last_synced_at = now_ms();
                next_state.undeletable_chunks = merged_undeletable;
                // F41：无变化轮次同样确认了「本轮上界之前的写入已全部在云端」，
                // 推进 push 水位线使下轮脏集合不包含它们（不动 last_synced_clock_ms
                // ——那是 pull 侧冲突判据的基线，语义见 state.rs）
                next_state.last_pushed_clock_ms = next_state.last_pushed_clock_ms.max(clock_mark);
                next_state.update_from_manifest(&remote_manifest);
                state_store.save(&next_state)?;
            } else {
                log::warn!(
                    "[push] 本轮 {} 张表失败，不推进 push 水位线（失败表的脏桶留待下轮重算）: {:?}",
                    result.failed_modules,
                    result.errors
                );
            }
            return Ok(result);
        }

        // 5. 组装并条件写清单
        //    墓碑水位线回收：先从清单剔除「早于所有设备检查点」的墓碑分桶，
        //    对象删除放在清单上传成功之后（顺序见 gc 模块文档）。
        //    F52：只回收「上一版清单里已存在」的桶——本轮新建的墓碑豁免一轮。
        let expired_tombstones =
            crate::cloud_sync::gc::prune_expired_tombstones(&mut new_manifest, &remote_manifest);
        new_manifest.epoch = remote_manifest.epoch + 1;
        new_manifest.device_id = device_id.to_string();
        new_manifest.updated_at = now_ms();
        // F52：`last_synced_at` 仅作诊断（本次 push 时刻）；水位线依据是本机账本里
        // 记录的「最后一次成功 pull 时刻」——push_only/rekey 不 pull，故不会抬高它
        new_manifest.touch_device(device_id, now_ms(), state.last_pulled_at);

        let payload = encrypt_payload(&serde_json::to_vec(&new_manifest)?, &data_key)?;

        // 回滚点：把上一版清单密文另存一份（语义边界见 paths::MANIFEST_PREV_PATH）。
        // F64（2026-10-01 第六轮）：force（rekey）轮改存**本版**清单密文——
        // 上一版（或解不开的旧清单）是旧 Key 密文，存它 = 旧 Key 密文残留 +
        // 无效回滚点（新 Key 世界解不开，恢复它会把全体设备引回 KeyMismatch）。
        let prev: Option<&[u8]> = if force {
            Some(&payload)
        } else {
            remote_raw.as_deref()
        };
        if let Some(raw) = prev
            && let Err(e) = adapter.upload(paths::MANIFEST_PREV_PATH, raw).await
        {
            log::info!("[push] 保存回滚点清单失败（不影响本次同步）: {e}");
        }

        let precondition = match &remote_token {
            Some(token) => UploadPrecondition::Match(token.clone()),
            // 远端无清单（首次推送）→ Absent；服务端不支持时由回读校验兜底
            None => UploadPrecondition::Absent,
        };
        let outcome = adapter
            .upload_conditional(paths::MANIFEST_PATH, &payload, precondition)
            .await?;

        let mut conflict_reason: Option<String> = None;
        if outcome == UploadOutcome::PreconditionFailed {
            conflict_reason = Some("清单前置条件失败".to_string());
        } else if !verify_manifest_write(adapter, &data_key, new_manifest.epoch, device_id).await? {
            // 服务端忽略条件头时的兜底：回读发现不是自己的版本
            conflict_reason = Some("清单写后校验发现他端写入".to_string());
        }

        if let Some(reason) = conflict_reason {
            cas_attempt += 1;
            result.cas_conflicts += 1;
            log::info!("[push] {reason}（第 {cas_attempt} 次），重新读取清单后重试");
            if cas_attempt >= CAS_MAX_RETRIES {
                let msg = format!(
                    "{reason}：并发冲突重试 {cas_attempt} 次仍未成功，本轮保留本地待下轮同步"
                );
                log::warn!("[push] {msg}");
                result.pushed_chunks += attempt.pushed_chunks;
                result.pushed_tombstones += attempt.pushed_tombstones;
                // 分桶已上传但清单未落定：模块计数与分桶计数保持一致，
                // 否则 UI 会显示"推送 0 模块"却有分桶上传的矛盾结果
                result.pushed_modules = attempt.pushed_modules;
                result.errors.push(msg);
                return Ok(result);
            }
            continue;
        }

        result.pushed_chunks += attempt.pushed_chunks;
        result.skipped_chunks += attempt.skipped_chunks;
        result.pushed_tombstones += attempt.pushed_tombstones;
        result.pushed_modules = attempt.pushed_modules;
        result.manifest_written = true;
        // F48：先把失败表信息落进日志（errors 随即被 extend 移走）
        if attempt.failed_modules > 0 {
            log::warn!(
                "[push] 本轮 {} 张表失败，不推进 push 水位线（下轮重算其脏桶）: {:?}",
                attempt.failed_modules,
                attempt.errors
            );
        }
        result.errors.extend(attempt.errors);

        // 6. 清单已上新版：现在可以安全删除不再被引用的墓碑对象
        if !expired_tombstones.is_empty() {
            let gc =
                crate::cloud_sync::gc::delete_expired_buckets(adapter, &expired_tombstones).await;
            log::info!(
                "[push] 墓碑回收：剔除 {} 个分桶，实际删除 {} 个",
                expired_tombstones.len(),
                gc.deleted_buckets
            );
            result.errors.extend(gc.errors);
        }

        // 6b. N39：新清单已不再引用这些空桶 → 删除其云端对象（同一顺序约束）
        if !attempt_removed.is_empty() {
            let gc = crate::cloud_sync::gc::delete_orphan_chunks(adapter, &attempt_removed).await;
            log::info!(
                "[push] 空桶收口：剔除 {} 个已清空分桶，实际删除 {} 个云端对象",
                attempt_removed.len(),
                gc.deleted_buckets
            );
            result.errors.extend(gc.errors);
        }

        let mut next_state = state.clone();
        next_state.last_synced_at = now_ms();
        next_state.undeletable_chunks = merged_undeletable;
        // F41：push 水位线推进到本轮上界（不是"现在"——本轮开始后的新写入
        // 必须留给下轮重新判脏）。last_synced_clock_ms 不动，语义见 state.rs。
        // F48：只有**本轮表级全成功**才推进；有失败表时保留旧水位线，
        // 使失败表的脏桶下轮仍被判脏并重传（否则行数不变的编辑永久漏传）。
        if round_clean {
            next_state.last_pushed_clock_ms = next_state.last_pushed_clock_ms.max(clock_mark);
        }
        next_state.update_from_manifest(&new_manifest);
        state_store.save(&next_state)?;
        return Ok(result);
    }
}

/// 单表差量结果
struct TableOutcome {
    table: String,
    table_index: TableIndex,
    tombstone_index: TombstoneIndex,
    pushed_chunks: u32,
    skipped_chunks: u32,
    pushed_tombstones: u32,
    /// 该表是否有任何上传
    changed: bool,
    /// N39：本轮从清单剔除的「本地已清空」分桶（清单落定后删其云端对象）
    removed_buckets: Vec<u32>,
    /// N39：核对结论为**不可剔除**的桶 → 核对时的远端指纹（写进账本备忘）
    undeletable: BTreeMap<u32, String>,
}

/// N52：本轮需要装载的行（行级增量装载）与自检期望
///
/// 判据「哪些桶需要重算」与 F41 的 `bucket_is_unchanged` 完全同源，只是把它
/// 从「逐桶比对后再决定跳不跳」前移成「先用它决定取哪些行」：
/// `需要重算 = 脏桶 ∪ 与远端行数不一致的桶`（远端没有该条的桶按 0 行算，
/// 于是「本机有、远端没有」的桶必然入选）。
///
/// 返回 `(items, expected)`：
/// - `expected = Some(map)`：只装载了这些桶，`map` 是各桶应有的存活行数，
///   调用方用 [`bucket_counts_match`] 自检后才会走到上传；
/// - `None`：全量装载（首次同步 / 扫描不可用 / force 轮 / 存在「无脏行但行数已变」
///   的桶——那种桶手里没有 uuid 清单，定向取行取不到，只能整表来一次）。
///
/// 为什么「无脏行但行数已变」不硬猜：行数变了却没有时间戳推进，只可能来自
/// 回收站 purge 的物理删除或他端清理，此时**桶内哪些行还在本机**未知，
/// 按清单乐观剔除会把他端行踢出载荷。
async fn load_items_for_round(
    db_pool: &SqlitePool,
    table: &str,
    force: bool,
    scan: Option<&LocalBucketScan>,
    remote_index: Option<&TableIndex>,
) -> Result<(Vec<serde_json::Value>, Option<HashMap<u32, u64>>), CloudSyncError> {
    let Some(scan) = scan.filter(|_| !force) else {
        return Ok((load_table_items(db_pool, table).await?, None));
    };

    let mut needed: Vec<u32> = Vec::new();
    let mut expected: HashMap<u32, u64> = HashMap::new();
    for (bucket, live) in &scan.live_counts {
        let remote_count = remote_index
            .and_then(|i| i.chunks.get(bucket))
            .map(|r| r.count)
            .unwrap_or(0);
        if !scan.dirty.contains(bucket) && *live == remote_count {
            continue; // F41 快路径：逐字节一致，连行都不取
        }
        if scan.dirty_uuids.contains_key(bucket) {
            expected.insert(*bucket, *live);
            needed.push(*bucket);
        } else {
            log::info!(
                "[push] 表 {table} 桶 {bucket} 行数已变但无脏行（物理删除/他端清理），本轮退回全量装载"
            );
            return Ok((load_table_items(db_pool, table).await?, None));
        }
    }

    // 桶数固定 64 个，`live_counts` 已按桶聚合，`needed` 里不会重复
    let uuids: Vec<String> = needed
        .iter()
        .filter_map(|b| scan.dirty_uuids.get(b))
        .flatten()
        .cloned()
        .collect();
    let items = load_table_items_of(db_pool, table, &uuids).await?;
    Ok((items, Some(expected)))
}

/// N52 自检：增量装载产出的分桶行数必须与扫描时的存活行数**逐桶**相符
///
/// 两个方向都要判：少了（载荷变子集 → 他端行被覆盖丢失）与多了/多出意外桶
/// （载荷混入不属于本轮的行）。任一不符即由调用方退回全量装载。
fn bucket_counts_match(chunks: &[TableChunk], expected: &HashMap<u32, u64>) -> bool {
    let mut seen: HashMap<u32, u64> = HashMap::new();
    for chunk in chunks {
        *seen.entry(chunk.bucket).or_insert(0) += chunk.items.len() as u64;
    }
    seen.len() == expected.len()
        && expected
            .iter()
            .all(|(bucket, count)| seen.get(bucket) == Some(count))
}

/// 单表差量计算与上传（错误隔离单元）
///
/// 索引合并口径（模块文档「为什么不会覆盖他端数据」的实现落点）：
/// 新表索引 = **远端索引为底** + 本地桶逐条覆盖，远端有、本地无的桶
/// （他端已推、本机尚未拉到的桶）原样保留——此前整体替换会把它们
/// 变成清单不再引用的孤儿，他端数据对所有设备消失。删除语义由墓碑
/// 表达，保留陈旧桶条目不会复活已删行（pull 侧 LWW/墓碑裁决兜底）。
///
/// N39（2026-10-14）在此之上加一条**有证据的**例外：本地已无存活行、
/// 且核对证明「该桶远端内容本机全已删」的桶，条目从清单剔除（云端对象
/// 在清单落定后删除）。核对实现见 [`bucket_fully_deleted_locally`]，
/// 备忘见 [`SyncState::undeletable_chunks`]。
async fn build_table_outcome(
    db_pool: &SqlitePool,
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    remote: &Manifest,
    table: &str,
    force: bool,
    scan: Option<&LocalBucketScan>,
    undeletable_known: &BTreeMap<String, BTreeMap<u32, String>>,
) -> Result<TableOutcome, TableError> {
    // F64（2026-10-01 第六轮）：force（rekey）轮索引**不以远端清单为底**。
    // 「远端有、本机无」的桶条目对应的云端对象仍是旧 Key 密文（本机没拉到过、
    // rekey 不会重加密它们），原样保留进新 Key 清单 = 「新 Key 清单指向旧 Key
    // 密文」的混合态，他端 pull 到该桶必然 KeyMismatch。rekey 的声明语义是
    // 「以本机为准覆盖云端」：索引只收本轮重加密的本机桶，被剔除的旧对象成为
    // 无清单引用的孤儿（不再被任何设备读取）。普通轮维持「远端为底 + 本地
    // 覆盖」的合并口径（本函数头注）——那是防他端数据被孤儿化的根基，不可波及。
    let mut table_index = if force {
        Default::default()
    } else {
        remote.table(table).cloned().unwrap_or_default()
    };
    let mut pushed_chunks = 0u32;
    let mut skipped_chunks = 0u32;
    // AAD 绑定写入门禁（ADR 0010 第一拍）：远端清单里全部已登记设备都具备 0x02
    // 读取能力时才绑路径。当前发布版本低于 AAD_MIN_APP_VERSION，此值恒 false，
    // 写出的仍是存量 0x01；第二拍无需改这里，靠版本号自然打开。
    let bind_aad = remote.all_devices_support_aad();

    // N52（2026-10-14）：**行级增量装载**——只把「需要重算的桶」的行物化成 JSON。
    // 干净桶（行数与远端一致且无脏行）连行都不取：此前每轮 push 都要把整表行
    // 全部加载并与远端逐桶比对，万级库仅为此产生数 MB 的 JSON 与行对象。
    let (items, expected) = load_items_for_round(db_pool, table, force, scan, remote.table(table))
        .await
        .map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;

    let mut chunks = split_table_items(table, items);
    // 增量装载没取行的桶 = 判为「与远端逐字节一致」的桶，计入跳过数：该计数
    // 仍是「与远端一致而未重算的分桶数」原义，只是判据前移到了装载之前。
    if let Some(expected) = &expected {
        skipped_chunks = scan
            .map(|s| s.live_counts.len().saturating_sub(expected.len()) as u32)
            .unwrap_or(0);
    }
    // 自检：增量装载的行数必须与扫描时的存活行数逐桶相符。分桶载荷是**桶级快照**，
    // 少一行就等于把云端该桶覆盖成子集（他端行丢失），宁可贵一次全量装载。
    if let Some(expected) = &expected
        && !bucket_counts_match(&chunks, expected)
    {
        log::warn!(
            "[push] 表 {table} 增量装载自检不符（期望 {} 桶），退回全量装载",
            expected.len()
        );
        let all = load_table_items(db_pool, table)
            .await
            .map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
        chunks = split_table_items(table, all);
        // 全量装载后跳过数由循环内的 F41 判据重新计数，别与上面的估算叠加
        skipped_chunks = 0;
    }

    for chunk in chunks {
        let remote_ref = remote
            .table(table)
            .and_then(|t| t.chunks.get(&chunk.bucket));

        // F41：行数一致 + 无晚于水位线的行 → 内容与上轮推送时逐字节一致，
        // 直接沿用远端清单条目（既不算指纹也不序列化载荷）。远端缺该桶
        // （他端清理/首推）或任一判据不满足时必须走完整比对。
        let unchanged = !force
            && remote_ref.is_some_and(|r| {
                scan.is_some_and(|s| s.bucket_is_unchanged(chunk.bucket, r.count))
            });
        if unchanged {
            skipped_chunks += 1;
            continue;
        }

        let fp = chunk.fingerprint().map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;

        // 指纹相等即零上传：远端条目保持原样（count/size 同源，无需重算载荷）
        if !force && remote_ref.is_some_and(|r| r.fp == fp) {
            skipped_chunks += 1;
            continue;
        }

        let payload = chunk.to_payload_bytes().map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;
        let bucket_path = paths::table_bucket_path(table, chunk.bucket);
        let encrypted = encrypt_bucket_payload(&payload, data_key, &bucket_path, bind_aad)
            .map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
        adapter
            .upload(&bucket_path, &encrypted)
            .await
            .map_err(|e| TableError {
                table: table.to_string(),
                message: format!("上传分桶 {}: {e}", chunk.bucket),
            })?;
        pushed_chunks += 1;

        table_index.chunks.insert(
            chunk.bucket,
            ChunkRef {
                fp,
                count: chunk.items.len() as u64,
                size: payload.len() as u64,
            },
        );
    }

    // ── N39：本地已清空的桶，条目不能永久留在清单里 ─────────────────────
    //
    // 背景：非 force 轮索引以**远端为底**（头注），本地把某桶的行全删光后条目
    // 仍被保留 → 他端（尤其新设备首同步）每轮都要下载这批陈旧行再靠墓碑把它们
    // 删掉，云端对象也永久留着。
    //
    // 判据必须是「桶内每一行本机都已知删除」，**不能**用行数比对：远端 chunk 只记
    // `count/fp` 不知道 uuid，「本机该桶存活 0 行」既可能是本机删光，也可能是
    // 「他端刚推、本机还没拉到」。故这里下载该桶逐行核对（见
    // [`bucket_fully_deleted_locally`]）：仅当桶内每个 uuid 在本机都有 `is_deleted = 1`
    // 的行才剔除条目——此时不可能丢任何存活行：桶内行全在墓碑索引里（删除语义照旧
    // 传播），而**不在**该 chunk 里的存活行（他端尚未推上来）云端本来就没有，他端
    // 下次 push 会把条目重新建起来。
    //
    // 核对不通过 → 条目原样保留，并把当时的远端指纹写进账本备忘，指纹未变则
    // 不重复下载（`SyncState::undeletable_chunks`）。
    let mut removed_buckets: Vec<u32> = Vec::new();
    let mut undeletable: BTreeMap<u32, String> = BTreeMap::new();
    if !force && let Some(scan) = scan {
        let candidates: Vec<(u32, String)> = table_index
            .chunks
            .iter()
            .filter(|(bucket, _)| scan.live_counts.get(bucket).copied().unwrap_or(0) == 0)
            .map(|(bucket, r)| (*bucket, r.fp.clone()))
            .collect();
        for (bucket, fp) in candidates.into_iter().take(MAX_EMPTY_BUCKET_CHECKS) {
            let memoized = undeletable_known
                .get(table)
                .and_then(|m| m.get(&bucket))
                .is_some_and(|known| known == &fp);
            if memoized {
                undeletable.insert(bucket, fp);
                continue;
            }
            match bucket_fully_deleted_locally(db_pool, adapter, data_key, table, bucket).await {
                Ok(true) => {
                    log::info!(
                        "[push] 空桶收口：{table} 桶 {bucket} 内行本机全已删（墓碑在），\
                         从清单剔除，清单落定后删云端对象"
                    );
                    removed_buckets.push(bucket);
                }
                Ok(false) => {
                    undeletable.insert(bucket, fp);
                }
                // 核对失败（网络/解密/解析）不是「不可剔除」的结论，不记备忘，
                // 下轮重试；条目保持原样，行为等价于本特性未启用
                Err(e) => {
                    log::warn!("[push] 空桶核对失败（保留条目，下轮重试）: {table}/{bucket}: {e}");
                }
            }
        }
        for bucket in &removed_buckets {
            table_index.chunks.remove(bucket);
        }
    }

    // 墓碑分桶差量（索引同数据桶口径：远端为底 + 本地覆盖；force 轮见上）
    let mut tombstone_index = if force {
        Default::default()
    } else {
        remote.tombstone_index(table).cloned().unwrap_or_default()
    };
    let mut pushed_tombstones = 0u32;
    let buckets = load_table_tombstones(db_pool, table)
        .await
        .map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;

    for (bucket, tombstones) in buckets {
        let payload = TombstoneBucketPayload {
            table: table.to_string(),
            bucket: bucket.clone(),
            tombstones: tombstones.clone(),
        };
        // 指纹口径与数据分桶一致：对墓碑数组做 canonical 哈希
        let fp = crate::cloud_sync::compute_fingerprint(
            &tombstones
                .iter()
                .map(|t| serde_json::json!({"uuid": t.uuid, "deleted_at": t.deleted_at}))
                .collect::<Vec<_>>(),
        )
        .map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;

        let remote_fp = remote
            .tombstone_index(table)
            .and_then(|i| i.buckets.get(&bucket))
            .map(|b| b.fp.as_str());

        if force || remote_fp != Some(fp.as_str()) {
            let bytes = serde_json::to_vec(&payload).map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
            let bucket_path = paths::tombstone_bucket_path(table, &bucket);
            let encrypted = encrypt_bucket_payload(&bytes, data_key, &bucket_path, bind_aad)
                .map_err(|e| TableError {
                    table: table.to_string(),
                    message: e.to_string(),
                })?;
            adapter
                .upload(&bucket_path, &encrypted)
                .await
                .map_err(|e| TableError {
                    table: table.to_string(),
                    message: format!("上传墓碑分桶 {bucket}: {e}"),
                })?;
            pushed_tombstones += 1;
        }

        tombstone_index.buckets.insert(
            bucket,
            TombstoneBucketRef {
                fp,
                count: tombstones.len() as u64,
                max_deleted_at: tombstones.iter().map(|t| t.deleted_at).max().unwrap_or(0),
            },
        );
    }

    Ok(TableOutcome {
        table: table.to_string(),
        table_index,
        tombstone_index,
        pushed_chunks,
        skipped_chunks,
        pushed_tombstones,
        // N39：剔除空桶同样改变了清单内容，必须视为「有变更」——否则
        // `changed_any` 短路不写清单，而对象却已被删除，云端会留下
        // 「清单引用 + 对象不存在」的坏引用（他端 404）
        changed: pushed_chunks > 0 || pushed_tombstones > 0 || !removed_buckets.is_empty(),
        removed_buckets,
        undeletable,
    })
}

/// N39：合并核对备忘——本轮核对过的表用新结论整体覆盖（空 map 也要覆盖，
/// 否则上一轮记下的陈旧「不可剔除」会一直生效），被剔除的桶顺手清掉旧结论。
///
/// 未参与本轮的失败表不出现在 `checked` 里，其旧备忘原样保留（其条目这轮也没动）。
fn merge_undeletable_memo(
    state: &SyncState,
    checked: &BTreeMap<String, BTreeMap<u32, String>>,
    removed: &[(String, u32)],
) -> BTreeMap<String, BTreeMap<u32, String>> {
    let mut merged = state.undeletable_chunks.clone();
    for (table, map) in checked {
        merged.insert(table.clone(), map.clone());
    }
    for (table, bucket) in removed {
        if let Some(map) = merged.get_mut(table) {
            map.remove(bucket);
        }
    }
    merged
}

/// N39：核对「远端该分桶内的行，本机是否全部已知删除」
///
/// 返回 `true` 才允许把该桶条目从清单剔除。判据逐行核对**不猜行数**：
///
/// 1. 下载并解密远端该桶（`decrypt_bucket_payload` 兼容 0x01/0x02 两种密文）；
/// 2. 桶内每个 uuid 在本机表中都必须存在且 `is_deleted = 1`；
/// 3. 任一 uuid 在本机**不存在**（他端刚推、本机未拉到；或回收站 purge 物理删过）
///    或仍然存活 → 返回 `false`（条目保留）。
///
/// 为什么行数比对不安全：远端 chunk 只记 `count/fp`，不知道 uuid 集合；
/// 「本机该桶存活 0 行 + 本机墓碑数 ≥ 远端 count」仍可能是「本机删的是自己那批行、
/// 远端留的是他端刚推的另一批行」，剔除即把他端存活行变成孤儿。
async fn bucket_fully_deleted_locally(
    db_pool: &SqlitePool,
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    table: &str,
    bucket: u32,
) -> Result<bool, CloudSyncError> {
    let path = paths::table_bucket_path(table, bucket);
    let raw = match adapter.download(&path).await {
        Ok(bytes) => bytes,
        // 对象已不在（他端清理/人为删过）：不剔除——条目要么被常规差量路径重传，
        // 要么由他端下次 push 修正，本特性不介入
        Err(e) if e.is_not_found() => return Ok(false),
        Err(e) => {
            return Err(CloudSyncError::Other {
                message: format!("下载待核对分桶 {path} 失败: {e}"),
            });
        }
    };
    let plain = decrypt_bucket_payload(&raw, data_key, &path)?;
    let payload: ChunkPayload = serde_json::from_slice(&plain)?;
    // 载荷自描述校验：路径与内容不一致说明对象被搬到别的桶位（AAD 未绑定时
    // 明文校验是唯一防线），此时不得据它剔除任何条目
    if payload.table != table || payload.bucket != bucket {
        return Ok(false);
    }
    if payload.items.is_empty() {
        return Ok(false);
    }
    for item in &payload.items {
        let uuid = item.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
        if uuid.is_empty() {
            return Ok(false);
        }
        let row: Option<(i64,)> = sqlx::query_as(&format!(
            "SELECT is_deleted FROM \"{table}\" WHERE uuid = ?"
        ))
        .bind(uuid)
        .fetch_optional(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("核对分桶 {path} 的行 {uuid} 失败: {e}"),
        })?;
        match row {
            Some((deleted,)) if deleted == 1 => {}
            _ => return Ok(false),
        }
    }
    Ok(true)
}

/// 表级错误（错误隔离单元）
#[derive(Debug)]
struct TableError {
    table: String,
    message: String,
}

impl std::fmt::Display for TableError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

/// 读取远端清单（不存在返回空清单 + 无令牌 + 无原始密文）
///
/// 第三个返回值是清单的**原始密文**，供调用方另存为上一版回滚点。
async fn read_remote_manifest(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
) -> Result<(Manifest, Option<String>, Option<Vec<u8>>), CloudSyncError> {
    read_remote_manifest_opt(adapter, data_key, false).await
}

/// [`read_remote_manifest`] 的带容错变体（仅 force/rekey 轮使用）
///
/// F64（2026-10-01 第六轮）：rekey 的三个场景（v2 改密 / v1→v2 迁移 /
/// KeyMismatch 恢复「以本机为准」）的共同前提是**远端密文不认当前 Key**，
/// 但本函数此前对清单解密失败一律上抛 `KeyMismatch`——云端非空时 rekey 在
/// 第一步就失败，「以本机为准覆盖云端」实际不可达（2026-10-01 探针用例实证，
/// 曾以临时用例验证旧行为直接报 KeyMismatch）。force 轮解不开按空清单起步：
/// 旧清单引用与旧 Key 分桶将被新 Key 清单整体替换，**并发令牌保留**供条件写
/// 覆盖既有对象。非 force 轮口径不变（KeyMismatch 仍引导恢复页）。
async fn read_remote_manifest_opt(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    allow_key_mismatch: bool,
) -> Result<(Manifest, Option<String>, Option<Vec<u8>>), CloudSyncError> {
    let (bytes, token) = match adapter.download_with_token(paths::MANIFEST_PATH).await? {
        None => return Ok((Manifest::empty(""), None, None)),
        Some((bytes, token)) => (bytes, token),
    };
    match decrypt_payload(&bytes, data_key) {
        Ok(plain) => {
            let manifest: Manifest = serde_json::from_slice(&plain)?;
            manifest.check_layout_version()?;
            Ok((manifest, token, Some(bytes)))
        }
        Err(e) if allow_key_mismatch && e.is_key_mismatch_error() => {
            log::warn!(
                "[push][force] 远端清单无法用当前 Key 解密——按「以本机为准」\
                 以空清单覆盖（旧 Key 清单引用与分桶将被整体替换）: {e}"
            );
            Ok((Manifest::empty(""), token, None))
        }
        Err(e) => Err(e),
    }
}

/// 写后回读校验：确认清单确实是我们写入的那一版
async fn verify_manifest_write(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    expected_epoch: u64,
    device_id: &str,
) -> Result<bool, CloudSyncError> {
    let (manifest, _, _) = read_remote_manifest(adapter, data_key).await?;
    Ok(manifest.epoch == expected_epoch && manifest.device_id == device_id)
}

/// 空数据覆盖守卫：本地全空 + 远端有数据 + 本机曾同步过 → 阻断
///
/// ## 与「合法清空全部数据」的区分（F53，2026-09-30 第六轮）
///
/// 「本地全空」有两种成因，处置必须相反：
///
/// - **删库重装**：本地物理清空、账本残留 → 必须阻断（否则空数据覆盖云端）。
/// - **用户合法清空**：逐条软删产生墓碑（回收站仍有内容 / TTL 未到）→
///   **必须放行**，否则删除永远传不上云（远端活行原样保留，下一轮 pull
///   又把它们拉回来，表现为「删了还会自己回来」）。
///
/// 两者唯一可判差异是**本地是否留有墓碑**：合法删除必然产生 `is_deleted = 1`
/// 的行，删库重装则一行不留。故在「本地全空」成立后追加墓碑判据。
async fn guard_against_empty_overwrite(
    db_pool: &SqlitePool,
    state: &crate::cloud_sync::state::SyncState,
    remote: &Manifest,
) -> Result<(), CloudSyncError> {
    let remote_has_data = remote.tables.values().any(|t| !t.is_empty());
    if !remote_has_data {
        return Ok(());
    }
    let ever_synced = state.last_synced_at > 0 || state.manifest_epoch > 0;
    if !ever_synced {
        return Ok(());
    }
    if !local_all_tables_empty(db_pool).await? {
        return Ok(());
    }
    // F53：无存活行但留有墓碑 = 合法清空（删除必须能上云），放行。
    if local_has_tombstones(db_pool).await? {
        log::info!(
            "[push] 空数据覆盖守卫放行：本地无存活行但存在软删墓碑（用户合法清空全部数据），\
             本轮需把墓碑同步到云端"
        );
        return Ok(());
    }
    let msg = "空数据覆盖守卫触发：本地数据库既无存活行也无任何软删墓碑，但远端已有同步数据、\
               且本机曾成功同步过——疑似删库重装后残留 sync_state.json，已阻断 Push 以防空数据\
               覆盖云端。请在设置中使用「从云端恢复」或清除同步状态后重试"
        .to_string();
    log::warn!("[push] 空数据覆盖守卫触发：{msg}");
    Err(CloudSyncError::State { message: msg })
}

/// 全部可同步表是否都为空（逐表 COUNT，语义等价于 is_deleted = 0 计数）
async fn local_all_tables_empty(db_pool: &SqlitePool) -> Result<bool, CloudSyncError> {
    for table in SYNCABLE_TABLES {
        let count: (i64,) = sqlx::query_as(&format!(
            "SELECT COUNT(*) FROM {table} WHERE is_deleted = 0"
        ))
        .fetch_one(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("统计表 {table} 行数失败: {e}"),
        })?;
        if count.0 > 0 {
            return Ok(false);
        }
    }
    Ok(true)
}

/// 是否存在软删墓碑（任一可同步表 `is_deleted = 1` 计数 > 0）
///
/// F53（2026-09-30 第六轮）：空数据覆盖守卫的**合法清空**判别依据。
/// `local_all_tables_empty` 只看 `is_deleted = 0`，把「用户合法清空」
/// 与「删库重装」判成同一态；墓碑是两者唯一的可判差异。
async fn local_has_tombstones(db_pool: &SqlitePool) -> Result<bool, CloudSyncError> {
    for table in SYNCABLE_TABLES {
        let count: (i64,) = sqlx::query_as(&format!(
            "SELECT COUNT(*) FROM {table} WHERE is_deleted = 1"
        ))
        .fetch_one(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("统计表 {table} 墓碑数失败: {e}"),
        })?;
        if count.0 > 0 {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync::progress::NoopProgressSender;
    use crate::sync::error::SyncError;
    use crate::sync_adapters::traits::{UploadOutcome, UploadPrecondition};
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// 内存适配器：支持条件写与令牌（模拟 S3/WebDAV 能力）
    struct MemAdapter {
        files: Mutex<HashMap<String, Vec<u8>>>,
        version: Mutex<u64>,
        uploads: Mutex<Vec<String>>,
        /// 已收到的 DELETE 路径（N39 空桶收口断言用）
        deletes: Mutex<Vec<String>>,
        /// 已收到的 GET 路径（N39 核对次数断言用）
        downloads: Mutex<Vec<String>>,
        /// 置 true 时条件写恒报冲突（模拟他端持续并发写入，耗尽 CAS 重试）
        conflict_all: Mutex<bool>,
        /// 置为某子串时，路径包含它的普通 `upload` 恒失败（注入单表上传故障）
        fail_upload_contains: Mutex<Option<String>>,
    }

    impl MemAdapter {
        fn new() -> Self {
            Self {
                files: Mutex::new(HashMap::new()),
                version: Mutex::new(0),
                uploads: Mutex::new(Vec::new()),
                deletes: Mutex::new(Vec::new()),
                downloads: Mutex::new(Vec::new()),
                conflict_all: Mutex::new(false),
                fail_upload_contains: Mutex::new(None),
            }
        }

        fn deletes(&self) -> Vec<String> {
            self.deletes.lock().unwrap().clone()
        }

        fn downloads(&self) -> Vec<String> {
            self.downloads.lock().unwrap().clone()
        }

        fn put(&self, path: &str, data: Vec<u8>) {
            self.files.lock().unwrap().insert(path.to_string(), data);
        }

        fn get(&self, path: &str) -> Option<Vec<u8>> {
            self.files.lock().unwrap().get(path).cloned()
        }
    }

    #[async_trait]
    impl SyncAdapter for MemAdapter {
        async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
            self.downloads.lock().unwrap().push(path.to_string());
            self.files
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .ok_or_else(|| SyncError::NotFound {
                    message: path.to_string(),
                })
        }
        async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
            // 故障注入：模拟某张表的分桶上传持续失败（限流/瞬断），
            // 用于钉住「失败轮次不得推进 push 水位线」与「rekey 不得半落清单」
            if let Some(needle) = self.fail_upload_contains.lock().unwrap().clone()
                && path.contains(&needle)
            {
                return Err(SyncError::Network {
                    message: format!("注入上传失败: {path}"),
                    retryable: true,
                });
            }
            self.uploads.lock().unwrap().push(path.to_string());
            self.put(path, data.to_vec());
            Ok(())
        }
        async fn delete(&self, path: &str) -> Result<(), SyncError> {
            // 真实语义：记录 DELETE 并移除对象；对象不存在时回 NotFound
            // （生产适配器同口径，`gc` 侧把 NotFound 视为删除成功）
            self.deletes.lock().unwrap().push(path.to_string());
            match self.files.lock().unwrap().remove(path) {
                Some(_) => Ok(()),
                None => Err(SyncError::NotFound {
                    message: path.to_string(),
                }),
            }
        }
        async fn upload_asset(&self, _: &str, _: Vec<u8>) -> Result<(), SyncError> {
            Ok(())
        }
        async fn download_asset(&self, _: &str) -> Result<Vec<u8>, SyncError> {
            Err(SyncError::NotFound {
                message: "无".to_string(),
            })
        }
        async fn asset_exists(&self, _: &str) -> Result<bool, SyncError> {
            Ok(false)
        }
        async fn list_assets(&self, _assets_dir: &str) -> Result<Vec<String>, SyncError> {
            Ok(Vec::new())
        }
        async fn download_with_token(
            &self,
            path: &str,
        ) -> Result<Option<(Vec<u8>, Option<String>)>, SyncError> {
            match self.files.lock().unwrap().get(path).cloned() {
                Some(bytes) => {
                    let token = self.version.lock().unwrap().to_string();
                    Ok(Some((bytes, Some(token))))
                }
                None => Ok(None),
            }
        }
        async fn upload_conditional(
            &self,
            path: &str,
            data: &[u8],
            precondition: UploadPrecondition,
        ) -> Result<UploadOutcome, SyncError> {
            if *self.conflict_all.lock().unwrap() {
                return Ok(UploadOutcome::PreconditionFailed);
            }
            // 首次写入用 Absent；匹配用 Match(当前版本)
            match &precondition {
                UploadPrecondition::Absent => {
                    if self.files.lock().unwrap().contains_key(path) {
                        return Ok(UploadOutcome::PreconditionFailed);
                    }
                }
                UploadPrecondition::Match(token) => {
                    let current = self.version.lock().unwrap().to_string();
                    if current != *token {
                        return Ok(UploadOutcome::PreconditionFailed);
                    }
                }
                UploadPrecondition::None => {}
            }
            self.uploads.lock().unwrap().push(path.to_string());
            self.put(path, data.to_vec());
            *self.version.lock().unwrap() += 1;
            Ok(UploadOutcome::Ok)
        }
    }

    async fn env() -> (
        SqlitePool,
        SyncCryptoService,
        SyncStateStore,
        tempfile::TempDir,
    ) {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        let tmp = tempfile::TempDir::new().unwrap();
        let crypto = SyncCryptoService::new(tmp.path());
        crypto.init_with_data_key("pw", &[7u8; 32]).unwrap();
        let store = SyncStateStore::new(tmp.path());
        (pool, crypto, store, tmp)
    }

    #[tokio::test]
    async fn first_push_uploads_chunks_and_writes_manifest() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let adapter = MemAdapter::new();
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert!(result.manifest_written);
        assert!(result.pushed_chunks >= 1);
        let uploads = adapter.uploads.lock().unwrap().clone();
        assert!(uploads.iter().any(|p| p == paths::MANIFEST_PATH));
        assert!(
            uploads
                .iter()
                .any(|p| p.starts_with("tables/todo_projects/")),
            "必须上传数据分桶: {uploads:?}"
        );
    }

    #[tokio::test]
    async fn second_push_without_changes_uploads_nothing() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        let before = adapter.uploads.lock().unwrap().len();
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert_eq!(result.pushed_chunks, 0, "无变化不得上传分桶");
        assert!(!result.manifest_written, "无变化不得改写清单");
        assert_eq!(
            adapter.uploads.lock().unwrap().len(),
            before,
            "无变化不得产生任何上传"
        );
    }

    #[tokio::test]
    async fn single_row_edit_uploads_only_one_chunk() {
        let (pool, crypto, store, _tmp) = env().await;
        let mut sql =
            String::from("INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ");
        for i in 0..200 {
            if i > 0 {
                sql.push(',');
            }
            sql.push_str(&format!("('uuid-{i}','P{i}',1,1)"));
        }
        sqlx::query(&sql).execute(&pool).await.unwrap();

        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        adapter.uploads.lock().unwrap().clear();
        // F41：改动必须推进逻辑时钟（水位线判据的前提；生产写路径由
        // `clock::next_ms()` 保证，测试里也照此写）
        sqlx::query("UPDATE todo_projects SET title='X', updated_at=? WHERE uuid='uuid-5'")
            .bind(crate::db::clock::next_ms())
            .execute(&pool)
            .await
            .unwrap();
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert_eq!(result.pushed_chunks, 1, "单行编辑只能重传一个分桶");
        let uploads = adapter.uploads.lock().unwrap().clone();
        let chunk_uploads = uploads.iter().filter(|p| p.starts_with("tables/")).count();
        assert_eq!(chunk_uploads, 1);
    }

    /// N52：装载范围可观测——只取「需要重算的桶」的行，干净桶一行不取
    ///
    /// 造两对同桶 uuid（P 桶 a/b、Q 桶 c/d），只改 a：期望只装载 P 桶两行
    /// （分桶载荷是桶级快照，桶内时间戳未变的 b 也得带上），Q 桶一行不取。
    /// 再覆盖保守分支：Q 桶物理删一行（行数变了、时间戳没推进）→ 全量装载。
    #[tokio::test]
    async fn load_items_for_round_takes_only_needed_buckets() {
        let (pool, crypto, store, _tmp) = env().await;
        // 清掉迁移种子行：种子行的 updated_at = 0 会永久判脏，干扰本轮断言
        sqlx::query("DELETE FROM todo_projects")
            .execute(&pool)
            .await
            .unwrap();
        let (a, b, c, d) = pick_uuids_in_two_buckets();
        let mut sql =
            String::from("INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ");
        for (i, uuid) in [&a, &b, &c, &d].iter().enumerate() {
            if i > 0 {
                sql.push(',');
            }
            sql.push_str(&format!("('{uuid}','P{i}',1,1)"));
        }
        sqlx::query(&sql).execute(&pool).await.unwrap();

        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        let (remote, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        let index = remote.table("todo_projects").cloned().unwrap();

        sqlx::query("UPDATE todo_projects SET title='X', updated_at=? WHERE uuid=?")
            .bind(crate::db::clock::next_ms())
            .bind(&a)
            .execute(&pool)
            .await
            .unwrap();
        let watermark = store.load().unwrap().last_pushed_clock_ms;
        let scan = scan_local_buckets(&pool, "todo_projects", watermark)
            .await
            .unwrap()
            .unwrap();
        let p_bucket = crate::cloud_sync::chunk::bucket_of_uuid(&a);

        let (items, expected) =
            load_items_for_round(&pool, "todo_projects", false, Some(&scan), Some(&index))
                .await
                .unwrap();

        let mut loaded: Vec<&str> = items.iter().filter_map(|i| i["uuid"].as_str()).collect();
        loaded.sort();
        let mut want = [a.as_str(), b.as_str()];
        want.sort();
        assert_eq!(
            loaded, want,
            "只装载脏桶两行（含桶内时间戳未变的那行），干净桶一行不取"
        );
        let expected = expected.expect("增量装载必须带自检期望");
        assert_eq!(
            expected,
            HashMap::from([(p_bucket, 2u64)]),
            "期望集只含需要重算的桶，且行数取扫描值"
        );

        // 保守分支：Q 桶物理删一行 → 行数少了但没有任何脏行（uuid 清单未知）→ 全量装载
        sqlx::query("DELETE FROM todo_projects WHERE uuid=?")
            .bind(&c)
            .execute(&pool)
            .await
            .unwrap();
        let scan2 = scan_local_buckets(&pool, "todo_projects", watermark)
            .await
            .unwrap()
            .unwrap();
        let (items2, expected2) =
            load_items_for_round(&pool, "todo_projects", false, Some(&scan2), Some(&index))
                .await
                .unwrap();
        assert!(
            expected2.is_none(),
            "「行数已变但无脏行」的桶必须退回全量装载（手里没有该桶 uuid 清单）"
        );
        assert_eq!(items2.len(), 3, "全量装载取回其余三行");

        // force（rekey）轮一律全量：索引重建时任何桶都可能需要重算
        let (_items3, expected3) =
            load_items_for_round(&pool, "todo_projects", true, Some(&scan2), Some(&index))
                .await
                .unwrap();
        assert!(expected3.is_none(), "force 轮必须全量装载");
    }

    /// 造两对同桶 uuid：(a,b) 一桶，(c,d) 另一桶（每桶只取一对，桶号可复现）
    fn pick_uuids_in_two_buckets() -> (String, String, String, String) {
        let mut first: HashMap<u32, String> = HashMap::new();
        let mut done: std::collections::HashSet<u32> = Default::default();
        let mut pairs: Vec<(String, String)> = Vec::new();
        for i in 0..2000 {
            let uuid = format!("uuid-{i}");
            let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid);
            if done.contains(&bucket) {
                continue;
            }
            match first.get(&bucket) {
                Some(prev) => {
                    pairs.push((prev.clone(), uuid));
                    done.insert(bucket);
                }
                None => {
                    first.insert(bucket, uuid);
                }
            }
            if pairs.len() == 2 {
                break;
            }
        }
        assert_eq!(pairs.len(), 2, "64 桶里必然凑出两对");
        let (a, b) = pairs[0].clone();
        let (c, d) = pairs[1].clone();
        assert_ne!(
            crate::cloud_sync::chunk::bucket_of_uuid(&a),
            crate::cloud_sync::chunk::bucket_of_uuid(&c),
            "两对必须落在不同桶"
        );
        (a, b, c, d)
    }

    /// N52 自检纯函数：少了/多了/冒出来的桶都要判不符
    #[test]
    fn bucket_counts_match_covers_shortfall_and_extra() {
        let chunk = |bucket: u32, n: usize| TableChunk {
            table: "todo_projects".into(),
            bucket,
            items: vec![serde_json::json!({}); n],
        };
        let expected: HashMap<u32, u64> = [(1, 2), (7, 1)].into_iter().collect();

        assert!(bucket_counts_match(&[chunk(1, 2), chunk(7, 1)], &expected));
        assert!(
            !bucket_counts_match(&[chunk(1, 1), chunk(7, 1)], &expected),
            "少一行 = 载荷变子集，必须判不符"
        );
        assert!(
            !bucket_counts_match(&[chunk(1, 3), chunk(7, 1)], &expected),
            "多一行同样是异常（说明装载混入了别的行）"
        );
        assert!(
            !bucket_counts_match(&[chunk(1, 2)], &expected),
            "期望的桶整桶缺席必须判不符"
        );
        assert!(
            !bucket_counts_match(&[chunk(1, 2), chunk(7, 1), chunk(9, 1)], &expected),
            "冒出期望之外的桶必须判不符"
        );
        assert!(
            bucket_counts_match(&[], &HashMap::new()),
            "空集对空集是相符"
        );
    }

    /// N52：行级增量装载产出的分桶载荷必须与全量装载**逐字节一致**
    ///
    /// 这是本优化唯一不可妥协的性质：分桶载荷是桶级快照，少一行就等于把云端
    /// 该桶覆盖成子集（他端行丢失）。用例特意让「脏行的桶」里还有一行是干净的
    /// （时间戳早于水位线），断言增量装载仍把该桶两行都装进来、载荷与全量装载
    /// 的结果逐字节相同。
    #[tokio::test]
    async fn incremental_load_payload_matches_full_load() {
        let (pool, crypto, store, _tmp) = env().await;
        // 清掉迁移种子行（其 updated_at = 0 会永久判脏，干扰断言）
        sqlx::query("DELETE FROM todo_projects")
            .execute(&pool)
            .await
            .unwrap();
        // 两对同桶 uuid：(a,b) 是同桶被编辑的那对，(c,d) 是另一桶（本轮不应被上传）
        let (a, b, c, d) = pick_uuids_in_two_buckets();
        let mut sql =
            String::from("INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ");
        for (i, uuid) in [&a, &b, &c, &d].iter().enumerate() {
            if i > 0 {
                sql.push(',');
            }
            sql.push_str(&format!("('{uuid}','P{i}',1,1)"));
        }
        sqlx::query(&sql).execute(&pool).await.unwrap();
        let dirty_bucket = crate::cloud_sync::chunk::bucket_of_uuid(&a);

        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        adapter.uploads.lock().unwrap().clear();

        // 只改同桶里的那行（同桶另一行保持「时间戳早于水位线」的干净态）
        sqlx::query("UPDATE todo_projects SET title='X', updated_at=? WHERE uuid=?")
            .bind(crate::db::clock::next_ms())
            .bind(&a)
            .execute(&pool)
            .await
            .unwrap();
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert_eq!(result.pushed_chunks, 1, "只该重传脏行所在的那个桶");
        let path = paths::table_bucket_path("todo_projects", dirty_bucket);
        let raw = adapter.get(&path).expect("云端应有该桶对象");
        let plain = decrypt_bucket_payload(&raw, &[7u8; 32], &path).unwrap();
        let actual: ChunkPayload = serde_json::from_slice(&plain).unwrap();
        assert_eq!(
            actual.items.len(),
            2,
            "脏桶内的时间戳未变的行也必须随桶一起装载（载荷是桶级快照）"
        );

        // 期望载荷：全量装载 → 分桶 → 取同名桶
        let all = load_table_items(&pool, "todo_projects").await.unwrap();
        let expected_chunk = split_table_items("todo_projects", all)
            .into_iter()
            .find(|c| c.bucket == dirty_bucket)
            .expect("全量装载必然含该桶");
        let expected_plain = expected_chunk.to_payload_bytes().unwrap();
        assert_eq!(
            plain, expected_plain,
            "增量装载的载荷必须与全量装载逐字节一致"
        );
    }

    /// F41：非脏桶零重算的可见证据（水位线判据的直接后果）
    ///
    /// 直接改内容但不推进 `updated_at`（不合规写）时，该桶被判定为「与上轮
    /// 逐字节一致」而跳过重算——**这是契约声明而非缺陷**：所有业务写路径
    /// （API / merge / 软删）都必须经 `clock::next_ms()` 推进时间戳。此用例
    /// 把契约钉住：若将来新增绕过逻辑时钟的写路径，这里会红，正确处置是修
    /// 写路径，而不是回退 F41 判据（回退即每轮全表重算，A10 归因基线失效）。
    #[tokio::test]
    async fn non_dirty_bucket_is_skipped_without_recompute() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 内容变了但时间戳没动（不合规写）：水位线判据看不见
        sqlx::query("UPDATE todo_projects SET title='CHANGED' WHERE uuid='u1'")
            .execute(&pool)
            .await
            .unwrap();
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert_eq!(
            result.pushed_chunks, 0,
            "非脏桶不得重算（合规写路径必推进 updated_at，见用例注释）"
        );
        assert!(!result.manifest_written);
    }

    /// 取两个同桶 uuid（桶号是 sha256 取模，循环搜索必然命中）
    fn same_bucket_pair() -> (String, String) {
        let mut seen: HashMap<u32, String> = HashMap::new();
        for i in 0..200 {
            let uuid = format!("row-{i}");
            let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid);
            if let Some(prev) = seen.get(&bucket) {
                return (prev.clone(), uuid);
            }
            seen.insert(bucket, uuid);
        }
        panic!("200 个 uuid 对 64 桶必然碰撞");
    }

    /// 软删某表一行的测试助手（墓碑时间戳用当前逻辑时钟）
    async fn soft_delete(pool: &SqlitePool, table: &str, uuid: &str) {
        let now = crate::db::clock::next_ms();
        sqlx::query(&format!(
            "UPDATE {table} SET is_deleted = 1, deleted_at = ?, updated_at = ? WHERE uuid = ?"
        ))
        .bind(now)
        .bind(now)
        .bind(uuid)
        .execute(pool)
        .await
        .unwrap();
    }

    /// N39：本地把某桶的行全删光后，清单条目与云端对象都不得继续留着
    ///
    /// 分两段钉住判据边界：**同桶仍有活行**时条目与对象必须原样保留（他端数据
    /// 不能被孤儿化），**同桶行全删**（且本机留有墓碑）时条目剔除、并在清单落定后
    /// 删对象——他端（尤其新设备首同步）不必再下载这批陈旧行再靠墓碑删掉。
    #[tokio::test]
    async fn empty_bucket_is_dropped_and_object_deleted_after_all_rows_deleted() {
        let (pool, crypto, store, _tmp) = env().await;
        let (uuid_a, uuid_b) = same_bucket_pair();
        assert_ne!(uuid_a, uuid_b);
        let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid_a);
        assert_eq!(bucket, crate::cloud_sync::chunk::bucket_of_uuid(&uuid_b));
        let path = paths::table_bucket_path("todo_projects", bucket);

        for uuid in [&uuid_a, &uuid_b] {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES (?,'P',1,1)",
            )
            .bind(uuid)
            .execute(&pool)
            .await
            .unwrap();
        }
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        assert!(adapter.get(&path).is_some(), "前置条件：桶对象已在云端");

        // 段一：只删同桶的一行 → 桶内仍有活行，条目与对象都必须保留
        soft_delete(&pool, "todo_projects", &uuid_a).await;
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        assert_eq!(result.pushed_chunks, 1, "桶内活行 2→1 仍须重算重传");
        assert!(
            !adapter.deletes().contains(&path),
            "桶内还有活行时不得剔除条目/删对象（防他端数据被孤儿化）: {:?}",
            adapter.deletes()
        );
        let (manifest, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        assert!(
            manifest
                .table("todo_projects")
                .unwrap()
                .chunks
                .contains_key(&bucket),
            "桶内仍有活行 → 条目保留"
        );

        // 段二：删掉桶内最后一行（墓碑留在本机）→ 条目剔除 + 对象删除
        soft_delete(&pool, "todo_projects", &uuid_b).await;
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        assert_eq!(result.pushed_chunks, 0, "桶内已无活行 → 本轮只有清单收口");
        assert!(
            result.manifest_written,
            "剔除条目必须写清单——否则对象被删而清单仍引用它，他端 pull 404"
        );
        assert!(
            adapter.deletes().contains(&path),
            "空桶对象必须删除: {:?}",
            adapter.deletes()
        );
        assert!(adapter.get(&path).is_none(), "对象应已从云端移除");
        let (manifest, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        assert!(
            !manifest
                .table("todo_projects")
                .unwrap()
                .chunks
                .contains_key(&bucket),
            "空桶条目必须从清单剔除"
        );
    }

    /// N39 反向：远端桶里有**本机不知道的行**时必须保留条目
    ///
    /// 「本机该桶存活 0 行」不等于「桶内行全已删」——他端刚推、本机还没拉到的行
    /// 也长这样，剔除条目会让它变成孤儿（对所有设备消失）。这里手工往远端桶内容里
    /// 塞一条本机没有的行，核对必须拒绝剔除，并把结论记进账本备忘（指纹未变则
    /// 下轮不再重复下载核对——成本上界靠这条）。
    #[tokio::test]
    async fn bucket_with_row_unknown_locally_is_kept_and_memoized() {
        let (pool, crypto, store, _tmp) = env().await;
        let (uuid_a, uuid_b) = same_bucket_pair();
        let bucket = crate::cloud_sync::chunk::bucket_of_uuid(&uuid_a);
        let path = paths::table_bucket_path("todo_projects", bucket);
        let data_key = [7u8; 32];

        for uuid in [&uuid_a, &uuid_b] {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES (?,'P',1,1)",
            )
            .bind(uuid)
            .execute(&pool)
            .await
            .unwrap();
        }
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 模拟「他端已推、本机尚未拉到」：远端桶里多一条本机没有的行
        let raw = adapter.get(&path).expect("首轮已上传该桶");
        let plain = decrypt_bucket_payload(&raw, &data_key, &path).unwrap();
        let mut payload: ChunkPayload = serde_json::from_slice(&plain).unwrap();
        payload.items.push(serde_json::json!({
            "uuid": "foreign-row-1",
            "title": "他端新行",
            "is_deleted": 0,
        }));
        adapter.put(
            &path,
            encrypt_bucket_payload(
                &serde_json::to_vec(&payload).unwrap(),
                &data_key,
                &path,
                false,
            )
            .unwrap(),
        );

        // 本机把两行都删了（墓碑都在），但远端桶里还挂着他端那行
        soft_delete(&pool, "todo_projects", &uuid_a).await;
        soft_delete(&pool, "todo_projects", &uuid_b).await;
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert!(
            !adapter.deletes().contains(&path),
            "桶内含本机未知行 → 不得剔除（否则他端存活行变孤儿）: {:?}",
            adapter.deletes()
        );
        let (manifest, _, _) = read_remote_manifest(&adapter, &data_key).await.unwrap();
        assert!(
            manifest
                .table("todo_projects")
                .unwrap()
                .chunks
                .contains_key(&bucket),
            "条目必须保留"
        );

        // 备忘生效：指纹未变的下一轮不再重复下载核对
        let checks_before = adapter.downloads().iter().filter(|p| *p == &path).count();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        let checks_after = adapter.downloads().iter().filter(|p| *p == &path).count();
        assert_eq!(
            checks_after, checks_before,
            "同一远端指纹下不得重复下载核对（成本上界）"
        );
    }

    /// F41：软删行的时间戳可能早于水位线（merge 墓碑锚定远端删除时间），
    /// 「行数比对」判据必须兜住「桶内活行减少」——纯时间戳判据是盲的
    #[tokio::test]
    async fn tombstone_applied_row_triggers_bucket_recompute() {
        let (pool, crypto, store, _tmp) = env().await;
        let (uuid_a, uuid_b) = same_bucket_pair();
        assert_ne!(uuid_a, uuid_b);

        for uuid in [&uuid_a, &uuid_b] {
            sqlx::query(
                "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES (?,'P',1,1)",
            )
            .bind(uuid)
            .execute(&pool)
            .await
            .unwrap();
        }
        let adapter = MemAdapter::new();
        let first = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        // 迁移可能带种子行（如默认模板），首轮桶数不强求 1；关键是第二轮
        assert!(first.pushed_chunks >= 1, "首轮至少推送一个分桶");

        // 模拟 merge 应用远端墓碑：is_deleted=1 且时间戳锚定为墓碑原始值
        // （`updated_at = deleted_at = 1`，远早于本轮水位线 → 时间戳判据失效）
        sqlx::query(
            "UPDATE todo_projects SET is_deleted=1, deleted_at=1, updated_at=1 WHERE uuid=?",
        )
        .bind(&uuid_a)
        .execute(&pool)
        .await
        .unwrap();

        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert_eq!(
            result.pushed_chunks, 1,
            "桶内活行减少（2→1）必须触发重算并重传——时间戳判据的盲区靠行数比对检出"
        );
    }

    #[tokio::test]
    async fn empty_local_with_remote_data_is_blocked() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 模拟删库重装：本地清空但账本残留
        sqlx::query("DELETE FROM todo_projects")
            .execute(&pool)
            .await
            .unwrap();
        let err = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("空数据覆盖守卫"));
    }

    /// F53（2026-09-30 第六轮）：用户「清空全部数据」造成的本地全空是**合法
    /// 删除**，守卫必须放行——否则删除永远传不上云，下一轮 pull 又把远端活行
    /// 拉回来，用户看到的是「删了还会自己回来」。
    ///
    /// 与既有 `empty_local_with_remote_data_is_blocked`（物理 `DELETE`，无墓碑）
    /// 构成一对：物理清空仍必须阻断，软删清空必须放行。
    #[tokio::test]
    async fn fully_soft_deleted_local_passes_empty_guard_and_pushes_tombstones() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 用户「清空全部数据」：逐条软删（墓碑留在本地）
        // 迁移可能带种子行，故按表全量软删，确保 `local_all_tables_empty` 为真
        let now = crate::db::clock::next_ms();
        for table in SYNCABLE_TABLES {
            sqlx::query(&format!(
                "UPDATE {table} SET is_deleted = 1, deleted_at = ?, updated_at = ? \
                 WHERE is_deleted = 0"
            ))
            .bind(now)
            .bind(now)
            .execute(&pool)
            .await
            .unwrap();
        }
        assert!(
            local_all_tables_empty(&pool).await.unwrap(),
            "前置条件：本地确已无存活行"
        );
        assert!(
            local_has_tombstones(&pool).await.unwrap(),
            "前置条件：本地确留有墓碑"
        );

        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .expect("合法清空全部数据不得被空数据覆盖守卫阻断");
        assert!(
            result.pushed_tombstones >= 1,
            "墓碑必须真正上云（否则远端活行仍在，下一轮 pull 会把它们拉回来）"
        );
    }

    #[tokio::test]
    async fn cas_conflict_does_not_lose_other_device_buckets() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('mine','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 他端并发写入：模拟远端清单已被别的设备改写（epoch+1, 保留我方桶）
        let (mut remote, token, _raw) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        remote.epoch += 1;
        remote.device_id = "dev-2".to_string();
        let payload = encrypt_payload(&serde_json::to_vec(&remote).unwrap(), &[7u8; 32]).unwrap();
        adapter.put(paths::MANIFEST_PATH, payload);
        // 让下一次条件写在令牌上失败一次
        *adapter.version.lock().unwrap() += 1;
        assert!(token.is_some());

        // 再改本地一行触发 push（推进逻辑时钟，见 F41 水位线判据）
        sqlx::query("UPDATE todo_projects SET title='P2', updated_at=? WHERE uuid='mine'")
            .bind(crate::db::clock::next_ms())
            .execute(&pool)
            .await
            .unwrap();

        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 最终必须写入成功并保留他端写入的信息（devices 合并）
        assert!(result.manifest_written || !result.errors.is_empty());
        let (final_manifest, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        assert!(
            final_manifest.epoch > remote.epoch - 1,
            "清单 epoch 必须推进"
        );
        assert!(
            final_manifest.tables.contains_key("todo_projects"),
            "他端表格索引不得丢失"
        );
    }

    #[tokio::test]
    async fn cas_exhaustion_keeps_module_count_consistent_with_chunks() {
        // CAS 重试耗尽时分桶已上传、清单未落定：模块计数必须与分桶计数一致，
        // 否则 UI 显示"推送 0 模块"却实际上传了分桶（矛盾结果）
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let adapter = MemAdapter::new();
        *adapter.conflict_all.lock().unwrap() = true;
        let result = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert!(!result.errors.is_empty(), "重试耗尽必须留下错误信息");
        assert!(result.pushed_chunks > 0, "分桶实际已上传: {:?}", result);
        assert_eq!(
            result.pushed_modules, 1,
            "有分桶上传时模块计数不得为 0: {:?}",
            result
        );
    }

    #[tokio::test]
    async fn push_preserves_remote_only_bucket_entries() {
        // 落后设备 push 不得把他端已推、本机未拉的桶条目从清单索引抹掉：
        // 远端独有桶（本机哈希域 0..64 之外的桶 99）必须在下一版清单中原样保留
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('mine','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 模拟他端写入：远端清单里插一个本机绝不会产出的桶条目
        let (mut remote, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        remote
            .tables
            .get_mut("todo_projects")
            .unwrap()
            .chunks
            .insert(
                99,
                ChunkRef {
                    fp: "ghost".to_string(),
                    count: 1,
                    size: 10,
                },
            );
        remote.epoch += 1;
        remote.device_id = "dev-2".to_string();
        let payload = encrypt_payload(&serde_json::to_vec(&remote).unwrap(), &[7u8; 32]).unwrap();
        adapter.put(paths::MANIFEST_PATH, payload);
        *adapter.version.lock().unwrap() += 1;

        sqlx::query("UPDATE todo_projects SET title='P2', updated_at=2 WHERE uuid='mine'")
            .execute(&pool)
            .await
            .unwrap();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        let (final_manifest, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        assert!(
            final_manifest
                .tables
                .get("todo_projects")
                .is_some_and(|t| t.chunks.contains_key(&99)),
            "他端独有桶条目不得被本机 push 整体替换丢失: {:?}",
            final_manifest.tables.get("todo_projects")
        );
    }

    #[tokio::test]
    async fn force_push_reuploads_unchanged_chunks_and_manifest() {
        // rekey 场景：内容未变但密钥已换——增量路径会全部跳过，
        // force 入口必须无视指纹重传桶并重写清单
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        adapter.uploads.lock().unwrap().clear();
        let result = push_all_force_full(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        assert!(
            result.pushed_chunks >= 1,
            "force 下指纹未变的桶也必须重传: {:?}",
            result
        );
        assert!(result.manifest_written, "force 下清单必须重写");
        let uploads = adapter.uploads.lock().unwrap().clone();
        assert!(
            uploads.iter().any(|p| p.starts_with("tables/")),
            "分桶必须实际上传: {uploads:?}"
        );
    }

    /// F48（2026-09-30 第六轮）：失败轮次不得推进 push 水位线，且恢复后必须重传
    ///
    /// 场景：改一行（**行数不变**）→ 该桶上传失败（限流/瞬断）→ 若水位线照旧推进，
    /// 下轮 `bucket_is_unchanged`（行数相等 + 无晚于水位线的行）会判该桶
    /// 「逐字节一致」而跳过，**编辑永久漏传云端**。此处钉住两条：失败轮次水位线
    /// 不动；恢复后下轮必须重传该桶。
    #[tokio::test]
    async fn failed_table_does_not_advance_push_watermark_and_retries_next_round() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        let watermark_after_clean = store.load().unwrap().last_pushed_clock_ms;
        assert!(watermark_after_clean > 0, "干净首轮必须推进水位线");

        // 行数不变的内容编辑：水位线判据（时间戳）看不见，行数比对也看不见
        sqlx::query("UPDATE todo_projects SET title='P-EDITED', updated_at=? WHERE uuid='u1'")
            .bind(crate::db::clock::next_ms())
            .execute(&pool)
            .await
            .unwrap();

        // 注入该表分桶上传失败；其余 10 张表无数据 → changed_any 为 false
        *adapter.fail_upload_contains.lock().unwrap() = Some("tables/todo_projects/".to_string());
        let failed = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        assert!(failed.failed_modules >= 1, "必须登记失败表: {failed:?}");
        assert!(!failed.errors.is_empty());
        assert!(!failed.manifest_written);
        assert_eq!(
            store.load().unwrap().last_pushed_clock_ms,
            watermark_after_clean,
            "失败轮次不得推进 push 水位线（否则该桶下轮被判「未变」永久漏传）"
        );

        // 恢复网络：该桶必须被重新判脏并重传
        *adapter.fail_upload_contains.lock().unwrap() = None;
        adapter.uploads.lock().unwrap().clear();
        let recovered = push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        assert!(
            recovered.pushed_chunks >= 1 && recovered.manifest_written,
            "恢复后必须重传失败表的脏桶并落清单: {recovered:?}"
        );
    }

    /// F49（2026-09-30 第六轮）：rekey 全量重传任一表失败必须在**写清单之前**中断
    ///
    /// 否则云端会出现「新 Key 清单 + 旧 Key 分桶」的混合态（分桶路径由桶号决定、
    /// 非内容寻址，force 是原地覆盖），全体设备含本机一律 `KeyMismatch`。
    #[tokio::test]
    async fn force_push_aborts_before_manifest_when_a_table_fails() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();
        let (before, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();

        *adapter.fail_upload_contains.lock().unwrap() = Some("tables/todo_projects/".to_string());
        adapter.uploads.lock().unwrap().clear();
        let err = push_all_force_full(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .expect_err("rekey 部分失败必须报错");
        assert!(
            err.to_string().contains("写入清单前中断"),
            "错误信息须说明清单未被改写: {err}"
        );
        let uploads = adapter.uploads.lock().unwrap().clone();
        assert!(
            !uploads.iter().any(|p| p == paths::MANIFEST_PATH),
            "失败轮次不得写清单: {uploads:?}"
        );

        let (after, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        assert_eq!(
            after.epoch, before.epoch,
            "清单 epoch 不得推进（否则成新 Key 清单指向旧 Key 分桶）"
        );
    }

    // ========================================================================
    // F64（2026-10-01 第六轮）：rekey 的「以本机为准」必须可达，且不留旧 Key 残留
    // ========================================================================

    /// F64：远端清单解不开时 force（rekey）必须走通，且 manifest.prev 不得残留旧 Key 密文
    ///
    /// 旧行为（2026-10-01 探针用例实证）：rekey 的三个场景（v2 改密 / v1→v2 迁移 /
    /// KeyMismatch 恢复）在云端非空时第一步读清单就报 `KeyMismatch`——
    /// 「以本机为准覆盖云端」实际不可达；即便走通，`manifest.prev` 存的也是
    /// 上一版旧 Key 密文（N50）。
    #[tokio::test]
    async fn force_push_tolerates_undecryptable_manifest_and_reencrypts_prev() {
        // 旧世界：dev-1 用旧 Key 推送（清单 + 分桶全是旧 Key 密文）
        let (pool_old, crypto_old, store_old, _t1) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool_old)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool_old,
            &crypto_old,
            &store_old,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 新世界：本机已换新 Key（v2 改密 / 恢复「以本机为准」完成切换），
        // 账本清空（rekey 前置），本地有以本机为准的数据
        let pool_new = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool_new)
            .await
            .unwrap();
        let tmp_new = tempfile::TempDir::new().unwrap();
        let crypto_new = SyncCryptoService::new(tmp_new.path());
        crypto_new.init_with_data_key("pw", &[9u8; 32]).unwrap();
        let store_new = SyncStateStore::new(tmp_new.path());
        store_new.clear().unwrap();
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u2','Q',1,1)",
        )
        .execute(&pool_new)
        .await
        .unwrap();

        let result = push_all_force_full(
            &pool_new,
            &crypto_new,
            &store_new,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-2",
            &[],
        )
        .await
        .expect("远端清单解不开时 rekey 必须以「以本机为准」走通（F64），不得报 KeyMismatch");
        assert!(result.manifest_written, "force 轮清单必须重写");
        assert!(result.pushed_chunks >= 1, "本机数据必须重加密上传");

        // 新清单必须可用新 Key 解密，且包含本机数据桶
        let (manifest, _, _) = read_remote_manifest(&adapter, &[9u8; 32]).await.unwrap();
        assert!(
            !manifest
                .tables
                .get("todo_projects")
                .is_none_or(|t| t.chunks.is_empty()),
            "新清单必须收录本机重加密的桶"
        );

        // 回滚点必须也是新 Key 密文——旧 Key 密文残留即 F64 病灶（N50）
        let prev_raw = adapter
            .get(paths::MANIFEST_PREV_PATH)
            .expect("force 轮必须写 manifest.prev 回滚点");
        let prev_plain = decrypt_payload(&prev_raw, &[9u8; 32])
            .expect("manifest.prev 必须是本版新 Key 密文，不得残留旧 Key 密文");
        serde_json::from_slice::<Manifest>(&prev_plain).expect("manifest.prev 必须是合法清单");
    }

    /// F64：force（rekey）轮不得把「远端有、本机无」的桶条目保留进新清单
    ///
    /// 旧行为：索引以远端清单为底 → 本机没拉到过的桶条目原样保留——它指向
    /// rekey 不会重加密的旧 Key 密文，新 Key 清单引用它 = 他端 pull 必
    /// KeyMismatch 的混合态。
    #[tokio::test]
    async fn force_push_drops_remote_only_bucket_entries() {
        let (pool, crypto, store, _tmp) = env().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ('u1','P',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let adapter = MemAdapter::new();
        push_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        // 注入「他端推过、本机没拉过」的桶条目：清单里凭空多一个 42 号桶，
        // 对象本体是任意旧密文占位（本机确实没有它的明文）
        let (mut remote, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        remote
            .tables
            .get_mut("todo_projects")
            .unwrap()
            .chunks
            .insert(
                42,
                ChunkRef {
                    fp: "fabricated-remote-only".to_string(),
                    count: 1,
                    size: 10,
                },
            );
        adapter.put(
            paths::MANIFEST_PATH,
            encrypt_payload(&serde_json::to_vec(&remote).unwrap(), &[7u8; 32]).unwrap(),
        );
        adapter.put(
            &paths::table_bucket_path("todo_projects", 42),
            vec![0u8; 16],
        );

        push_all_force_full(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "dev-1",
            &[],
        )
        .await
        .unwrap();

        let (final_manifest, _, _) = read_remote_manifest(&adapter, &[7u8; 32]).await.unwrap();
        let index = &final_manifest.tables["todo_projects"];
        assert!(
            !index.chunks.contains_key(&42),
            "force 轮不得保留远端独有的桶条目（它指向 rekey 不重加密的旧密文，\
             保留即新 Key 清单指向旧 Key 密文的混合态）: {:?}",
            index.chunks.keys().collect::<Vec<_>>()
        );
        assert!(
            !index.chunks.is_empty(),
            "本机自己的桶必须仍在索引里（不得误伤）"
        );
    }
}
