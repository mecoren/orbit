//! state — 本地同步账本（`sync_state.json`）
//!
//! ## 账本内容与用途
//! - `manifest_epoch`：上次成功同步后远端清单的 epoch（pull 的快速跳过判据）
//! - `remote_tables` / `remote_tombstones`：上次同步后远端**桶索引快照**
//!   （表 → 桶键 → 指纹）。pull 据此只下载「远端指纹与快照不同」的桶；
//!   没有这份快照就只能每次全量下载，差量无从谈起。
//! - `last_synced_at`：上次同步完成时间（调度器与 UI 展示，墙上时钟）
//! - `last_synced_clock_ms`：上次同步完成时的**逻辑时钟**值（`db::clock`）——
//!   记录级「是否在上次同步之后被改过」的判定基线，供冲突败方副本留档使用
//!   （与 `last_synced_at` 区分：后者是墙上时钟，是墓碑回收水位线的依据，
//!   不能混用逻辑时钟，否则会把未见过墓碑的设备误判为已见过）
//!
//! 快照是**纯缓存**：丢失只损失一次增量能力（退化为完整下载一轮），
//! 不涉及业务数据；而 push 侧的差量基准始终是实时读取的远端清单，
//! 不依赖本地快照，因此不会出现「本地账本漂移导致云端被误覆盖」。
//!
//! ## 与 v1 的区别
//! v1 用 `fp` / `remote_fp` 双指纹描述「整个模块」，粒度粗且双真相源易漂移；
//! v2 快照精确到分桶，且只描述**远端**状态（本地状态由实时扫描得到）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::cloud_sync::error::CloudSyncError;

/// 同步账本文件名
const STATE_FILE_NAME: &str = "sync_state.json";

/// 本地同步账本
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SyncState {
    /// 最后一次同步完成时间（Unix 毫秒，墙上时钟）
    pub last_synced_at: i64,
    /// 最后一次同步完成时的逻辑时钟值（见 `db::clock`；0 = 从未成功同步）
    ///
    /// 冲突败方副本的「真并发」判据：只有本地记录时间戳**晚于**本值，
    /// 才说明这条记录在上次同步之后被本地改过，此时远端同 uuid 的更新
    /// 才算冲突（否则只是他端顺延更新，属正常传播，不该留档噪声）。
    #[serde(default)]
    pub last_synced_clock_ms: i64,
    /// 当前设备 ID
    pub device_id: String,
    /// 上次成功同步后远端清单的 epoch（0 = 从未成功同步）
    pub manifest_epoch: u64,
    /// 远端数据桶索引快照：表 → 桶号 → 指纹
    #[serde(default)]
    pub remote_tables: BTreeMap<String, BTreeMap<u32, String>>,
    /// 远端墓碑桶索引快照：表 → 桶键（YYYY-MM）→ 指纹
    #[serde(default)]
    pub remote_tombstones: BTreeMap<String, BTreeMap<String, String>>,
}

impl SyncState {
    /// 构造空账本（首次同步场景）
    pub fn empty(device_id: &str) -> Self {
        Self {
            last_synced_at: 0,
            last_synced_clock_ms: 0,
            device_id: device_id.to_string(),
            manifest_epoch: 0,
            remote_tables: BTreeMap::new(),
            remote_tombstones: BTreeMap::new(),
        }
    }

    /// 上次所见远端数据桶指纹（无记录返回 None）
    pub fn remote_chunk_fp(&self, table: &str, bucket: u32) -> Option<&str> {
        self.remote_tables
            .get(table)
            .and_then(|m| m.get(&bucket))
            .map(|s| s.as_str())
    }

    /// 用清单刷新「远端桶索引快照」与 epoch
    ///
    /// push/pull 结束时调用：此后本地记录的远端状态与清单一致，下轮
    /// pull 才能准确判断「哪些桶是远端新增/变更」。
    pub fn update_from_manifest(&mut self, manifest: &crate::cloud_sync::meta::ManifestV2) {
        self.manifest_epoch = manifest.epoch;
        self.remote_tables = manifest
            .tables
            .iter()
            .map(|(table, idx)| {
                (
                    table.clone(),
                    idx.chunks
                        .iter()
                        .map(|(bucket, r)| (*bucket, r.fp.clone()))
                        .collect(),
                )
            })
            .collect();
        self.remote_tombstones = manifest
            .tombstones
            .iter()
            .map(|(table, idx)| {
                (
                    table.clone(),
                    idx.buckets
                        .iter()
                        .map(|(bucket, r)| (bucket.clone(), r.fp.clone()))
                        .collect(),
                )
            })
            .collect();
    }

    /// 上次所见远端墓碑桶指纹（无记录返回 None）
    pub fn remote_tombstone_fp(&self, table: &str, bucket: &str) -> Option<&str> {
        self.remote_tombstones
            .get(table)
            .and_then(|m| m.get(bucket))
            .map(|s| s.as_str())
    }
}

/// 本地账本存储器
///
/// 封装 `sync_state.json` 的读写。无缓存，每次读写直接操作文件
/// （同步频率低、文件仅数百字节，无需内存缓存）。
#[derive(Debug, Clone)]
pub struct SyncStateStore {
    app_data_dir: PathBuf,
}

impl SyncStateStore {
    /// 创建账本存储器
    pub fn new(app_data_dir: &Path) -> Self {
        Self {
            app_data_dir: app_data_dir.to_path_buf(),
        }
    }

    /// 账本文件路径
    pub fn path(&self) -> PathBuf {
        self.app_data_dir.join(STATE_FILE_NAME)
    }

    /// 加载账本
    ///
    /// 文件不存在返回空账本；解析失败先隔离损坏文件（留证）再返回错误，
    /// 由调用方决定是否降级为全量比对。
    pub fn load(&self) -> Result<SyncState, CloudSyncError> {
        let path = self.path();
        if !path.exists() {
            return Ok(SyncState::default());
        }
        let content = std::fs::read_to_string(&path).map_err(|e| CloudSyncError::State {
            message: format!("读取 sync_state.json 失败: {e}"),
        })?;
        match serde_json::from_str::<SyncState>(&content) {
            Ok(state) => Ok(state),
            Err(e) => {
                let quarantined =
                    crate::fs_util::quarantine_corrupt_file(&path).unwrap_or_else(|_| path.clone());
                log::warn!(
                    "[state] sync_state.json 损坏已隔离至 {:?}，将退化为完整比对: {}",
                    quarantined,
                    e
                );
                Err(CloudSyncError::State {
                    message: format!("解析 sync_state.json 失败（退化为完整比对）: {e}"),
                })
            }
        }
    }

    /// 保存账本（原子写）
    pub fn save(&self, state: &SyncState) -> Result<(), CloudSyncError> {
        let content = serde_json::to_string_pretty(state)?;
        crate::fs_util::write_atomic(&self.path(), content.as_bytes()).map_err(|e| {
            CloudSyncError::State {
                message: format!("写入 sync_state.json 失败: {e}"),
            }
        })?;
        Ok(())
    }

    /// 清除账本（用于断开同步 / rekey 强制全量重传）
    pub fn clear(&self) -> Result<(), CloudSyncError> {
        let path = self.path();
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| CloudSyncError::State {
                message: format!("删除 sync_state.json 失败: {e}"),
            })?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_store() -> (SyncStateStore, TempDir) {
        let tmp = TempDir::new().unwrap();
        (SyncStateStore::new(tmp.path()), tmp)
    }

    #[test]
    fn load_returns_default_when_no_file() {
        let (store, _tmp) = make_store();
        let state = store.load().unwrap();
        assert_eq!(state.last_synced_at, 0);
        assert_eq!(state.manifest_epoch, 0);
    }

    #[test]
    fn save_load_roundtrip() {
        let (store, _tmp) = make_store();
        let mut state = SyncState::empty("device-001");
        state.last_synced_at = 12345;
        state.manifest_epoch = 7;
        store.save(&state).unwrap();

        let loaded = store.load().unwrap();
        assert_eq!(loaded.last_synced_at, 12345);
        assert_eq!(loaded.device_id, "device-001");
        assert_eq!(loaded.manifest_epoch, 7);
    }

    #[test]
    fn clear_removes_file_and_is_idempotent() {
        let (store, _tmp) = make_store();
        store.save(&SyncState::empty("d")).unwrap();
        assert!(store.path().exists());
        store.clear().unwrap();
        assert!(!store.path().exists());
        store.clear().unwrap();
    }

    #[test]
    fn corrupted_file_returns_error_after_quarantine() {
        let (store, _tmp) = make_store();
        std::fs::write(store.path(), "{ invalid json").unwrap();
        let result = store.load();
        assert!(matches!(result, Err(CloudSyncError::State { .. })));
        // 损坏文件已隔离（原路径不再持有坏内容）
        assert!(!store.path().exists() || store.load().is_ok());
    }

    #[test]
    fn path_is_in_app_data_dir() {
        let store = SyncStateStore::new(Path::new("/tmp/test_app"));
        assert_eq!(store.path(), Path::new("/tmp/test_app/sync_state.json"));
    }
}
