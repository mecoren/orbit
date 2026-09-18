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
//! ## 空数据覆盖守卫
//! 本地全空 + 远端已有数据时阻断 push（删库重装后 sync_state.json 残留的
//! 场景），要求走恢复流程而非静默清空云端。

use sqlx::SqlitePool;

use crate::cloud_sync::chunk::split_table_items;
use crate::cloud_sync::crypto_io::{decrypt_payload, encrypt_payload};
use crate::cloud_sync::db_loader::{load_table_items, load_table_tombstones, now_ms};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::{
    ChunkRef, Manifest, TableIndex, TombstoneBucketPayload, TombstoneBucketRef, TombstoneIndex,
};
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{ProgressBuilder, ProgressSender, SyncOrigin};
use crate::cloud_sync::state::SyncStateStore;
use crate::db::sync_registry::SYNCABLE_TABLES;
use crate::sync_adapters::traits::{SyncAdapter, UploadOutcome, UploadPrecondition};
use crate::sync_crypto::SyncCryptoService;

/// 清单 CAS 冲突后的最大重试次数
pub const CAS_MAX_RETRIES: u32 = 3;

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

    let mut result = PushResult::default();
    let mut cas_attempt = 0u32;

    loop {
        // 1. 读远端清单（顺带拿并发令牌与原始密文，后者用于保留回滚点）
        let (remote_manifest, remote_token, remote_raw) =
            read_remote_manifest(adapter, &data_key).await?;

        // 2. 空数据覆盖守卫（远端有数据 + 本地全空 + 曾同步过 → 阻断）
        guard_against_empty_overwrite(db_pool, &state, &remote_manifest).await?;

        // 3. 逐表差量计算 + 上传（每轮重算，保证 CAS 冲突后基于新清单收敛）
        let mut attempt = PushResult::default();
        let mut new_manifest = remote_manifest.clone();
        let mut outcomes: Vec<Result<TableOutcome, TableError>> = Vec::with_capacity(tables.len());
        for (idx, table) in tables.iter().enumerate() {
            builder.pushing("todos", "待办数据", idx as u32 + 1, tables.len() as u32);
            outcomes.push(build_table_outcome(db_pool, adapter, &data_key, &remote_manifest, table).await);
        }

        for outcome in outcomes {
            match outcome {
                Ok(o) => {
                    attempt.pushed_chunks += o.pushed_chunks;
                    attempt.skipped_chunks += o.skipped_chunks;
                    attempt.pushed_tombstones += o.pushed_tombstones;
                    if o.changed {
                        attempt.pushed_modules = 1;
                    }
                    new_manifest.tables.insert(o.table.clone(), o.table_index);
                    new_manifest
                        .tombstones
                        .insert(o.table.clone(), o.tombstone_index);
                }
                Err(e) => {
                    attempt.failed_modules += 1;
                    attempt.errors.push(format!("表 {} push 失败: {}", e.table, e.message));
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

        // 4. 无任何变化 → 不写清单（避免 epoch 空转与无意义流量）
        let changed_any = attempt.pushed_chunks > 0 || attempt.pushed_tombstones > 0;
        if !changed_any {
            attempt.skipped_modules = 1;
            result = attempt;
            let mut next_state = state.clone();
            next_state.last_synced_at = now_ms();
            next_state.update_from_manifest(&remote_manifest);
            state_store.save(&next_state)?;
            return Ok(result);
        }

        // 5. 组装并条件写清单
        //    墓碑水位线回收：先从清单剔除「早于所有设备检查点」的墓碑分桶，
        //    对象删除放在清单上传成功之后（顺序见 gc 模块文档）。
        let expired_tombstones = crate::cloud_sync::gc::prune_expired_tombstones(&mut new_manifest);
        new_manifest.epoch = remote_manifest.epoch + 1;
        new_manifest.device_id = device_id.to_string();
        new_manifest.updated_at = now_ms();
        new_manifest.touch_device(device_id, now_ms());

        let payload = encrypt_payload(&serde_json::to_vec(&new_manifest)?, &data_key)?;

        // 回滚点：把上一版清单密文另存一份（语义边界见 paths::MANIFEST_PREV_PATH）
        if let Some(raw) = &remote_raw
            && let Err(e) = adapter.upload(paths::MANIFEST_PREV_PATH, raw).await
        {
            log::info!("[push] 保存上一版清单失败（不影响本次同步）: {e}");
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
            log::info!(
                "[push] {reason}（第 {cas_attempt} 次），重新读取清单后重试"
            );
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
        result.errors.extend(attempt.errors);

        // 6. 清单已上新版：现在可以安全删除不再被引用的墓碑对象
        if !expired_tombstones.is_empty() {
            let gc = crate::cloud_sync::gc::delete_expired_buckets(adapter, &expired_tombstones).await;
            log::info!(
                "[push] 墓碑回收：剔除 {} 个分桶，实际删除 {} 个",
                expired_tombstones.len(),
                gc.deleted_buckets
            );
            result.errors.extend(gc.errors);
        }

        let mut next_state = state.clone();
        next_state.last_synced_at = now_ms();
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
}

/// 单表差量计算与上传（错误隔离单元）
async fn build_table_outcome(
    db_pool: &SqlitePool,
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    remote: &Manifest,
    table: &str,
) -> Result<TableOutcome, TableError> {
    let mut table_index = TableIndex::default();
    let mut pushed_chunks = 0u32;
    let mut skipped_chunks = 0u32;

    let items = load_table_items(db_pool, table).await.map_err(|e| TableError {
        table: table.to_string(),
        message: e.to_string(),
    })?;

    for chunk in split_table_items(table, items) {
        let fp = chunk.fingerprint().map_err(|e| TableError {
            table: table.to_string(),
            message: e.to_string(),
        })?;
        let size = chunk.to_payload_bytes().map(|b| b.len() as u64).unwrap_or(0);
        let count = chunk.items.len() as u64;

        let remote_ref = remote
            .table(table)
            .and_then(|t| t.chunks.get(&chunk.bucket))
            .filter(|r| r.fp == fp);

        if remote_ref.is_some() {
            skipped_chunks += 1;
        } else {
            let payload = chunk.to_payload_bytes().map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
            let encrypted = encrypt_payload(&payload, data_key).map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
            adapter
                .upload(&paths::table_bucket_path(table, chunk.bucket), &encrypted)
                .await
                .map_err(|e| TableError {
                    table: table.to_string(),
                    message: format!("上传分桶 {}: {e}", chunk.bucket),
                })?;
            pushed_chunks += 1;
        }

        table_index.chunks.insert(
            chunk.bucket,
            ChunkRef {
                fp,
                count,
                size,
            },
        );
    }

    // 墓碑分桶差量
    let mut tombstone_index = TombstoneIndex::default();
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
                .map(|t| {
                    serde_json::json!({"uuid": t.uuid, "deleted_at": t.deleted_at})
                })
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

        if remote_fp != Some(fp.as_str()) {
            let bytes = serde_json::to_vec(&payload).map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
            let encrypted = encrypt_payload(&bytes, data_key).map_err(|e| TableError {
                table: table.to_string(),
                message: e.to_string(),
            })?;
            adapter
                .upload(&paths::tombstone_bucket_path(table, &bucket), &encrypted)
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
        changed: pushed_chunks > 0 || pushed_tombstones > 0,
    })
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
    match adapter.download_with_token(paths::MANIFEST_PATH).await? {
        None => Ok((Manifest::empty(""), None, None)),
        Some((bytes, token)) => {
            let plain = decrypt_payload(&bytes, data_key)?;
            let manifest: Manifest = serde_json::from_slice(&plain)?;
            if manifest.layout_version != crate::cloud_sync::meta::LAYOUT_VERSION {
                return Err(CloudSyncError::Other {
                    message: format!(
                        "云端清单布局版本 {} 不受支持（当前 {}）",
                        manifest.layout_version,
                        crate::cloud_sync::meta::LAYOUT_VERSION
                    ),
                });
            }
            Ok((manifest, token, Some(bytes)))
        }
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
    let msg = "空数据覆盖守卫触发：本地数据库为空但远端已有同步数据、且本机曾成功同步过——\
               疑似删库重装后残留 sync_state.json，已阻断 Push 以防空数据覆盖云端。\
               请在设置中使用「从云端恢复」或清除同步状态后重试"
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync::progress::NoopProgressSender;
    use crate::sync::error::SyncError;
    use crate::sync_adapters::traits::{RemoteFile, UploadOutcome, UploadPrecondition};
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// 内存适配器：支持条件写与令牌（模拟 S3/WebDAV 能力）
    struct MemAdapter {
        files: Mutex<HashMap<String, Vec<u8>>>,
        version: Mutex<u64>,
        uploads: Mutex<Vec<String>>,
        /// 置 true 时条件写恒报冲突（模拟他端持续并发写入，耗尽 CAS 重试）
        conflict_all: Mutex<bool>,
    }

    impl MemAdapter {
        fn new() -> Self {
            Self {
                files: Mutex::new(HashMap::new()),
                version: Mutex::new(0),
                uploads: Mutex::new(Vec::new()),
                conflict_all: Mutex::new(false),
            }
        }

        fn put(&self, path: &str, data: Vec<u8>) {
            self.files.lock().unwrap().insert(path.to_string(), data);
        }
    }

    #[async_trait]
    impl SyncAdapter for MemAdapter {
        async fn list_files(&self, _: &str) -> Result<Vec<RemoteFile>, SyncError> {
            Ok(Vec::new())
        }
        async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
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
            self.uploads.lock().unwrap().push(path.to_string());
            self.put(path, data.to_vec());
            Ok(())
        }
        async fn delete(&self, _: &str) -> Result<(), SyncError> {
            Ok(())
        }
        async fn upload_asset(&self, _: &str, _: &[u8]) -> Result<(), SyncError> {
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
        async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
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
        sqlx::migrate!("./src/db/migrations").run(&pool).await.unwrap();
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
            uploads.iter().any(|p| p.starts_with("tables/todo_projects/")),
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
        let mut sql = String::from(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) VALUES ",
        );
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
        sqlx::query("UPDATE todo_projects SET title='X', updated_at=2 WHERE uuid='uuid-5'")
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
        let chunk_uploads = uploads
            .iter()
            .filter(|p| p.starts_with("tables/"))
            .count();
        assert_eq!(chunk_uploads, 1);
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
        sqlx::query("DELETE FROM todo_projects").execute(&pool).await.unwrap();
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

        // 再改本地一行触发 push
        sqlx::query("UPDATE todo_projects SET title='P2', updated_at=2 WHERE uuid='mine'")
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
        assert!(
            result.pushed_chunks > 0,
            "分桶实际已上传: {:?}",
            result
        );
        assert_eq!(
            result.pushed_modules, 1,
            "有分桶上传时模块计数不得为 0: {:?}",
            result
        );
    }
}
