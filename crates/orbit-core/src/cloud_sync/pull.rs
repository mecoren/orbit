//! pull — 清单驱动的差量下载与合并
//!
//! ## 流程
//! 1. 读远端清单；不存在说明云端尚未有数据 → 直接返回（首次同步前置）
//! 2. `epoch` 与本地账本一致 → 无任何远端变更，跳过（零分桶流量）
//! 3. 逐表：比对「远端桶指纹」与本地账本快照，**只下载变化的桶**；
//!    墓碑分桶同理；随后按表合并（LWW + 复活裁决）
//! 4. 用远端清单刷新本地账本快照（epoch + 桶索引）
//!
//! ## 为什么串行
//! 合并是 SQLite 写事务（单连接池写串行），下载并发只会把压力推给
//! 后续写锁等待；且 WebDAV（坚果云约 1 req/s）对并发请求敏感。差量后
//! 单轮待下载分桶数已从「全库」降到「变化桶」，串行开销可接受。
//!
//! ## 错误隔离
//! 单表失败只记入 `failed_modules`（push 侧据此跳过该表，防止本地旧快照
//! 覆盖云端新数据），不影响其他表。

use sqlx::SqlitePool;

use crate::cloud_sync::chunk::ChunkPayload;
use crate::cloud_sync::crypto_io::decrypt_payload;
use crate::cloud_sync::db_loader::now_ms;
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::{Manifest, TombstoneBucketPayload, TombstoneEntry};
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{ProgressBuilder, ProgressSender, SyncOrigin};
use crate::cloud_sync::state::{SyncState, SyncStateStore};
use crate::db::sync_registry::SYNCABLE_TABLES;
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

/// Pull 执行结果
#[derive(Debug, Clone, Default)]
pub struct PullResult {
    /// 实际拉取的模块数（有桶被下载即 1，保持 UI 计数语义）
    pub pulled_modules: u32,
    /// 跳过的模块数（远端无变更 / epoch 未变）
    pub skipped_modules: u32,
    /// 冲突裁决数合计
    pub conflicts: u64,
    /// 留档的冲突败方副本数合计
    pub copied_conflicts: u64,
    /// 收集的错误（不阻塞整体流程）
    pub errors: Vec<String>,
    /// 本轮 Pull 失败的表名（push 侧据此跳过，防陈旧覆盖）
    pub failed_modules: Vec<String>,
    /// 下载的数据分桶数
    pub downloaded_chunks: u32,
    /// 跳过的数据分桶数（指纹未变）
    pub skipped_chunks: u32,
    /// 下载的墓碑分桶数
    pub downloaded_tombstones: u32,
}

/// 执行差量 Pull
pub async fn pull_all(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
) -> Result<PullResult, CloudSyncError> {
    let mut state = match state_store.load() {
        Ok(s) => s,
        Err(e) => {
            log::warn!("[pull] 本地账本不可用，将完整比对远端分桶: {e}");
            SyncState::default()
        }
    };
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    // 1. 读远端清单
    let manifest = match adapter.download_with_token(paths::MANIFEST_PATH).await? {
        None => {
            log::info!("[pull] 云端无清单（首次同步/云端为空），跳过拉取");
            let mut next = state.clone();
            next.last_synced_at = now_ms();
            next.last_synced_clock_ms = crate::db::clock::next_ms();
            next.manifest_epoch = 0;
            next.remote_tables.clear();
            next.remote_tombstones.clear();
            state_store.save(&next)?;
            return Ok(PullResult {
                skipped_modules: 1,
                ..Default::default()
            });
        }
        Some((bytes, _)) => {
            let plain = decrypt_payload(&bytes, &data_key)?;
            let m: Manifest = serde_json::from_slice(&plain)?;
            if m.layout_version != crate::cloud_sync::meta::LAYOUT_VERSION {
                return Err(CloudSyncError::Other {
                    message: format!(
                        "云端清单布局版本 {} 不受支持（当前 {}）",
                        m.layout_version,
                        crate::cloud_sync::meta::LAYOUT_VERSION
                    ),
                });
            }
            m
        }
    };

    // 2. epoch 快速跳过
    if manifest.epoch > 0 && manifest.epoch == state.manifest_epoch {
        log::info!("[pull] 清单 epoch 未变（{}），跳过", manifest.epoch);
        state.last_synced_at = now_ms();
        state.last_synced_clock_ms = crate::db::clock::next_ms();
        state_store.save(&state)?;
        return Ok(PullResult {
            skipped_modules: 1,
            ..Default::default()
        });
    }

    let builder = ProgressBuilder::new(progress_sender, origin);
    // 表集合 = 有数据分桶的表 ∪ 有墓碑分桶的表。
    // 数据被删光的表只剩墓碑，若只遍历 tables 会漏掉删除传播。
    let mut table_names: std::collections::BTreeSet<&String> = manifest.tables.keys().collect();
    table_names.extend(manifest.tombstones.keys());
    let tables: Vec<&String> = table_names.into_iter().collect();
    builder.starting(tables.len() as u32);

    let mut result = PullResult::default();
    let mut changed_records_total = 0u64;

    for (idx, table) in tables.iter().enumerate() {
        let table: &str = table;
        builder.pulling("todos", "待办数据", idx as u32 + 1, tables.len() as u32);

        match pull_single_table(
            db_pool,
            &data_key,
            adapter,
            &state,
            &manifest,
            table,
            state.last_synced_clock_ms,
        )
        .await
        {
            Ok(outcome) => {
                result.downloaded_chunks += outcome.downloaded_chunks;
                result.skipped_chunks += outcome.skipped_chunks;
                result.downloaded_tombstones += outcome.downloaded_tombstones;
                result.conflicts += outcome.merge.conflicts;
                result.copied_conflicts += outcome.merge.copied;
                changed_records_total +=
                    outcome.merge.inserted + outcome.merge.updated + outcome.merge.deleted;
                result.errors.extend(outcome.merge.errors);
                if outcome.downloaded_chunks > 0 || outcome.downloaded_tombstones > 0 {
                    result.pulled_modules = 1;
                }
                builder.merging(
                    "todos",
                    "待办数据",
                    outcome.merge.inserted,
                    outcome.merge.updated,
                    outcome.merge.deleted,
                );
            }
            Err(e) => {
                log::info!("[pull] 表 {table} 拉取失败（隔离不中断）: {e}");
                result.errors.push(format!("表 {table} 拉取失败: {e}"));
                result.failed_modules.push(table.to_string());
            }
        }
    }

    if changed_records_total > 0 {
        builder.local_data_applied(changed_records_total);
    }

    // 3. 刷新整体快照；失败表回滚桶指纹到最后一次成功状态（强制下轮重试）。
    //    存在失败表时 epoch 不推进——否则下轮在「epoch 未变」快速跳过处
    //    整轮早退，失败表要等他端改写清单才有机会重试。
    let mut next = state.clone();
    next.last_synced_at = now_ms();
    next.update_from_manifest(&manifest);
    if !result.failed_modules.is_empty() {
        next.manifest_epoch = state.manifest_epoch;
    }
    // 逻辑时钟基线推进到「本轮同步结束时刻」，下一轮据此判定记录是否被本地改过；
    // 同时把时钟（可能已被远端时间戳抬升）落盘 —— 慢表重启后不得回落到墙上时钟
    next.last_synced_clock_ms = crate::db::clock::next_ms();
    crate::db::clock::persist(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("逻辑时钟落盘失败: {e}"),
        })?;
    // 失败表回滚快照到最后一次成功状态（强制下轮重试）
    for table in &result.failed_modules {
        if let Some(prev) = state.remote_tables.get(table) {
            next.remote_tables.insert(table.clone(), prev.clone());
        } else {
            next.remote_tables.remove(table);
        }
        if let Some(prev) = state.remote_tombstones.get(table) {
            next.remote_tombstones.insert(table.clone(), prev.clone());
        } else {
            next.remote_tombstones.remove(table);
        }
    }
    state_store.save(&next)?;

    Ok(result)
}

/// 单表拉取结果
struct TablePullOutcome {
    merge: crate::cloud_sync::merge::MergeResult,
    downloaded_chunks: u32,
    skipped_chunks: u32,
    downloaded_tombstones: u32,
}

/// 单表差量下载与合并
async fn pull_single_table(
    db_pool: &SqlitePool,
    data_key: &[u8],
    adapter: &dyn SyncAdapter,
    state: &SyncState,
    manifest: &Manifest,
    table: &str,
    baseline_ms: i64,
) -> Result<TablePullOutcome, CloudSyncError> {
    if !SYNCABLE_TABLES.contains(&table) {
        return Err(CloudSyncError::UnknownModule(format!(
            "远端清单包含非白名单表 `{table}`，疑似数据被篡改或版本不兼容"
        )));
    }

    let mut items: Vec<serde_json::Value> = Vec::new();
    let mut downloaded_chunks = 0u32;
    let mut skipped_chunks = 0u32;

    if let Some(index) = manifest.table(table) {
        for (bucket, chunk_ref) in &index.chunks {
            if state.remote_chunk_fp(table, *bucket) == Some(chunk_ref.fp.as_str()) {
                skipped_chunks += 1;
                continue;
            }
            let path = paths::table_bucket_path(table, *bucket);
            let bytes = adapter.download(&path).await?;
            let plain = decrypt_payload(&bytes, data_key)?;
            let payload: ChunkPayload = serde_json::from_slice(&plain)?;
            if payload.table != table || payload.bucket != *bucket {
                return Err(CloudSyncError::Merge {
                    message: format!(
                        "分桶内容与路径不一致（路径 {table}/{bucket}，载荷 {}/{}）",
                        payload.table, payload.bucket
                    ),
                });
            }
            items.extend(payload.items);
            downloaded_chunks += 1;
        }
    }

    let mut tombstones: Vec<TombstoneEntry> = Vec::new();
    let mut downloaded_tombstones = 0u32;
    if let Some(index) = manifest.tombstone_index(table) {
        for (bucket, entry) in &index.buckets {
            if state.remote_tombstone_fp(table, bucket) == Some(entry.fp.as_str()) {
                continue;
            }
            let path = paths::tombstone_bucket_path(table, bucket);
            let bytes = adapter.download(&path).await?;
            let plain = decrypt_payload(&bytes, data_key)?;
            let payload: TombstoneBucketPayload = serde_json::from_slice(&plain)?;
            if payload.table != table || payload.bucket != *bucket {
                return Err(CloudSyncError::Merge {
                    message: format!("墓碑分桶内容与路径不一致（路径 {table}/{bucket}）"),
                });
            }
            tombstones.extend(payload.tombstones);
            downloaded_tombstones += 1;
        }
    }

    let merge = crate::cloud_sync::merge::merge_table_items(
        db_pool,
        table,
        &items,
        &tombstones,
        baseline_ms,
    )
    .await?;

    Ok(TablePullOutcome {
        merge,
        downloaded_chunks,
        skipped_chunks,
        downloaded_tombstones,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync::chunk::split_table_items;
    use crate::cloud_sync::crypto_io::encrypt_payload;
    use crate::cloud_sync::meta::{ChunkRef, TableIndex};
    use crate::cloud_sync::progress::NoopProgressSender;
    use crate::sync::error::SyncError;
    use crate::sync_adapters::traits::RemoteFile;
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct MemAdapter {
        files: Mutex<HashMap<String, Vec<u8>>>,
        downloads: Mutex<Vec<String>>,
    }

    impl MemAdapter {
        fn new() -> Self {
            Self {
                files: Mutex::new(HashMap::new()),
                downloads: Mutex::new(Vec::new()),
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
        async fn download_with_token(
            &self,
            path: &str,
        ) -> Result<Option<(Vec<u8>, Option<String>)>, SyncError> {
            // 读清单不记入 downloads（避免"零下载"断言被清单读取干扰）
            Ok(self
                .files
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .map(|b| (b, None)))
        }
        async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
            Ok(Vec::new())
        }
    }

    const KEY: [u8; 32] = [9u8; 32];

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
        crypto.init_with_data_key("pw", &KEY).unwrap();
        let store = SyncStateStore::new(tmp.path());
        (pool, crypto, store, tmp)
    }

    /// 构造「远端含一行 todo_projects」的云端环境
    fn seed_remote(adapter: &MemAdapter, uuid: &str, title: &str, updated_at: i64) -> Manifest {
        let mut manifest = Manifest::empty("dev-2");
        manifest.epoch = 3;

        let items = vec![serde_json::json!({
            "uuid": uuid, "title": title, "is_deleted": 0, "deleted_at": 0,
            "updated_at": updated_at, "version": 1
        })];
        let chunks = split_table_items("todo_projects", items);
        let mut index = TableIndex::default();
        for chunk in &chunks {
            let bytes = chunk.to_payload_bytes().unwrap();
            adapter.put(
                &paths::table_bucket_path("todo_projects", chunk.bucket),
                encrypt_payload(&bytes, &KEY).unwrap(),
            );
            index.chunks.insert(
                chunk.bucket,
                ChunkRef {
                    fp: chunk.fingerprint().unwrap(),
                    count: chunk.items.len() as u64,
                    size: bytes.len() as u64,
                },
            );
        }
        manifest.tables.insert("todo_projects".to_string(), index);

        let payload = encrypt_payload(&serde_json::to_vec(&manifest).unwrap(), &KEY).unwrap();
        adapter.put(paths::MANIFEST_PATH, payload);
        manifest
    }

    #[tokio::test]
    async fn first_pull_downloads_and_merges() {
        let (pool, crypto, store, _tmp) = env().await;
        let adapter = MemAdapter::new();
        seed_remote(&adapter, "remote-1", "来自他端", 100);

        let result = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        assert!(result.downloaded_chunks >= 1);
        let (title,): (String,) =
            sqlx::query_as("SELECT title FROM todo_projects WHERE uuid='remote-1'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(title, "来自他端");

        // 账本已记录远端快照
        let state = store.load().unwrap();
        assert_eq!(state.manifest_epoch, 3);
        assert!(
            state.remote_chunk_fp("todo_projects", 0).is_some() || !state.remote_tables.is_empty()
        );
    }

    #[tokio::test]
    async fn second_pull_with_same_epoch_downloads_nothing() {
        let (pool, crypto, store, _tmp) = env().await;
        let adapter = MemAdapter::new();
        seed_remote(&adapter, "remote-1", "A", 100);

        pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        adapter.downloads.lock().unwrap().clear();
        let result = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        assert_eq!(result.skipped_modules, 1, "epoch 未变必须跳过");
        assert!(
            adapter.downloads.lock().unwrap().is_empty(),
            "epoch 未变不得产生任何下载"
        );
    }

    #[tokio::test]
    async fn failed_table_keeps_epoch_and_retries_next_round() {
        // 表下载失败时必须记录 failed_modules 且 epoch 不推进——否则下一轮
        // 在「epoch 未变」快速跳过处整轮早退，失败表要等他端改写清单才重试
        let (pool, crypto, store, _tmp) = env().await;
        let adapter = MemAdapter::new();
        let manifest = seed_remote(&adapter, "remote-1", "A", 100);

        // 制造下载失败：清单在、桶对象没了（NotFound）
        adapter
            .files
            .lock()
            .unwrap()
            .retain(|p, _| *p == paths::MANIFEST_PATH);
        let result = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();
        assert_eq!(
            result.failed_modules,
            vec!["todo_projects".to_string()],
            "桶下载失败必须登记 failed_modules"
        );
        let state = store.load().unwrap();
        assert_eq!(
            state.manifest_epoch, 0,
            "有失败表时 epoch 不得推进（清单实际为 {}）",
            manifest.epoch
        );

        // 恢复云端内容后，下一轮不得被快速跳过，必须真正重试该表
        seed_remote(&adapter, "remote-1", "A", 100);
        let retry = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();
        assert!(
            retry.downloaded_chunks >= 1 && retry.failed_modules.is_empty(),
            "下一轮必须重试并成功: {:?}",
            retry
        );
        assert_eq!(store.load().unwrap().manifest_epoch, manifest.epoch);
    }

    #[tokio::test]
    async fn epoch_change_but_same_bucket_fp_downloads_nothing() {
        let (pool, crypto, store, _tmp) = env().await;
        let adapter = MemAdapter::new();
        let mut manifest = seed_remote(&adapter, "remote-1", "A", 100);

        pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        // 他端只推进了 epoch（例如上传了别的表），本项目桶未变
        manifest.epoch = 5;
        let payload = encrypt_payload(&serde_json::to_vec(&manifest).unwrap(), &KEY).unwrap();
        adapter.put(paths::MANIFEST_PATH, payload);

        adapter.downloads.lock().unwrap().clear();
        let result = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        assert_eq!(result.downloaded_chunks, 0, "桶指纹未变不得下载");
        assert!(result.skipped_chunks >= 1);
    }

    #[tokio::test]
    async fn missing_manifest_is_noop() {
        let (pool, crypto, store, _tmp) = env().await;
        let adapter = MemAdapter::new();

        let result = pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();
        assert_eq!(result.pulled_modules, 0);
        assert_eq!(result.skipped_modules, 1);
    }

    #[tokio::test]
    async fn tombstone_bucket_propagates_delete() {
        let (pool, crypto, store, _tmp) = env().await;
        // 本地先有一行
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, is_deleted, deleted_at, created_at, updated_at, version)
             VALUES ('victim','V',0,0,1,50,1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let adapter = MemAdapter::new();
        let mut manifest = Manifest::empty("dev-2");
        manifest.epoch = 7;
        // 远端墓碑：删除时间 100 > 本地更新时间 50 → 删除胜出
        let tombstones = vec![TombstoneEntry::new("victim".to_string(), 100)];
        let bucket = crate::cloud_sync::db_loader::local_month_key(100);
        let payload = TombstoneBucketPayload {
            table: "todo_projects".to_string(),
            bucket: bucket.clone(),
            tombstones: tombstones.clone(),
        };
        let bytes = serde_json::to_vec(&payload).unwrap();
        adapter.put(
            &paths::tombstone_bucket_path("todo_projects", &bucket),
            encrypt_payload(&bytes, &KEY).unwrap(),
        );
        let fp = crate::cloud_sync::compute_fingerprint(
            &tombstones
                .iter()
                .map(|t| serde_json::json!({"uuid": t.uuid, "deleted_at": t.deleted_at}))
                .collect::<Vec<_>>(),
        )
        .unwrap();
        manifest.tombstones.insert(
            "todo_projects".to_string(),
            crate::cloud_sync::meta::TombstoneIndex {
                buckets: std::collections::BTreeMap::from([(
                    bucket.clone(),
                    crate::cloud_sync::meta::TombstoneBucketRef {
                        fp,
                        count: 1,
                        max_deleted_at: 100,
                    },
                )]),
            },
        );
        let mbytes = encrypt_payload(&serde_json::to_vec(&manifest).unwrap(), &KEY).unwrap();
        adapter.put(paths::MANIFEST_PATH, mbytes);

        pull_all(
            &pool,
            &crypto,
            &store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
        )
        .await
        .unwrap();

        let (is_deleted, deleted_at): (i64, i64) =
            sqlx::query_as("SELECT is_deleted, deleted_at FROM todo_projects WHERE uuid='victim'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(is_deleted, 1, "远端墓碑必须传播为本地软删");
        assert_eq!(deleted_at, 100, "删除时间必须保留原始值");
    }
}
