//! state — 本地同步状态持久化
//!
//! 管理 `sync_state.json`，记录每个模块的本地指纹、远端指纹、记录数、时间戳。
//! 用于 Push/Pull 时跳过未变化的模块，实现增量同步。
//!
//! 文件布局：
//! ```text
//! {app_data_dir}/sync_state.json
//! ```
//!
//! ## 字段语义
//! - `fp`：本地计算的指纹（compute_fingerprint），Push 成功后更新
//! - `remote_fp`：远端拉取的指纹（GlobalMeta.modules[name].fp），Pull 成功后更新
//! - Push 跳过条件：`fp == 上次 Push 后的 fp`（业务数据未变）
//! - Pull 跳过条件：`remote_fp == 上次 Pull 后的 remote_fp`（远端数据未变）

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::cloud_sync::error::CloudSyncError;

/// 同步状态文件名
const STATE_FILE_NAME: &str = "sync_state.json";

/// 全局同步状态
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SyncState {
    /// 最后一次同步完成时间（Unix 毫秒）
    pub last_synced_at: i64,
    /// 当前设备 ID
    pub device_id: String,
    /// 各模块同步状态（key = 模块名）
    pub modules: BTreeMap<String, ModuleSyncState>,
}

/// 单个模块的同步状态
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ModuleSyncState {
    /// 本地指纹（上次 Push 时计算的 sha256）
    pub fp: String,
    /// 远端指纹（上次 Pull 时从 GlobalMeta 获取的 sha256）
    pub remote_fp: String,
    /// 记录数（不含软删除）
    pub count: u64,
    /// 上次 Pull 时间（Unix 毫秒）
    pub pulled_at: i64,
    /// 上次 Push 时间（Unix 毫秒）
    pub pushed_at: i64,
}

impl SyncState {
    /// 构造空状态（首次同步场景）
    pub fn empty(device_id: &str) -> Self {
        Self {
            last_synced_at: 0,
            device_id: device_id.to_string(),
            modules: BTreeMap::new(),
        }
    }

    /// 获取指定模块的状态，不存在则返回默认值
    pub fn module(&self, name: &str) -> ModuleSyncState {
        self.modules.get(name).cloned().unwrap_or_default()
    }

    /// 更新模块状态并写入文件（便利方法）
    pub fn set_module(&mut self, name: &str, state: ModuleSyncState) {
        self.modules.insert(name.to_string(), state);
    }
}

/// 本地状态存储器
///
/// 封装 `sync_state.json` 的读写操作。无缓存，每次读写都直接操作文件
/// （同步频率低，文件几 KB，无需内存缓存）。
#[derive(Debug, Clone)]
pub struct SyncStateStore {
    app_data_dir: PathBuf,
}

impl SyncStateStore {
    /// 创建状态存储器
    pub fn new(app_data_dir: &Path) -> Self {
        Self {
            app_data_dir: app_data_dir.to_path_buf(),
        }
    }

    /// 状态文件路径
    pub fn path(&self) -> PathBuf {
        self.app_data_dir.join(STATE_FILE_NAME)
    }

    /// 加载状态
    ///
    /// 文件不存在或解析失败时返回空状态（回退到首次同步模式，记录 warning 日志）。
    /// 解析失败时先隔离损坏文件（Fix-04 留证），避免被下次保存静默覆盖。
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
                // 损坏留证：sync_state 损坏仅损失增量跳过能力（回退全量同步），
                // 但留证有助于诊断"为什么突然全量重传"
                let quarantined =
                    crate::fs_util::quarantine_corrupt_file(&path).unwrap_or_else(|_| path.clone());
                log::warn!(
                    "[state] sync_state.json 损坏已隔离至 {:?}，将回退到首次同步模式: {}",
                    quarantined,
                    e
                );
                Err(CloudSyncError::State {
                    message: format!("解析 sync_state.json 失败（回退到首次同步）: {e}"),
                })
            }
        }
    }

    /// 保存状态（原子写，Fix-04）
    pub fn save(&self, state: &SyncState) -> Result<(), CloudSyncError> {
        let path = self.path();
        let content = serde_json::to_string_pretty(state)?;
        crate::fs_util::write_atomic(&path, content.as_bytes()).map_err(|e| {
            CloudSyncError::State {
                message: format!("写入 sync_state.json 失败: {e}"),
            }
        })?;
        Ok(())
    }

    /// 更新单个模块状态并立即持久化
    pub fn update_module(&self, name: &str, update: ModuleSyncState) -> Result<(), CloudSyncError> {
        let mut state = self.load()?;
        state.set_module(name, update);
        self.save(&state)
    }

    /// 清除状态（用于重置同步）
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
        assert!(state.modules.is_empty());
    }

    #[test]
    fn save_load_roundtrip() {
        let (store, _tmp) = make_store();
        let mut state = SyncState::empty("device-001");
        state.last_synced_at = 12345;
        state.set_module(
            "movies",
            ModuleSyncState {
                fp: "fp123".to_string(),
                remote_fp: "rfp456".to_string(),
                count: 10,
                pulled_at: 100,
                pushed_at: 200,
            },
        );

        store.save(&state).unwrap();
        let loaded = store.load().unwrap();

        assert_eq!(loaded.last_synced_at, 12345);
        assert_eq!(loaded.device_id, "device-001");
        let m = loaded.module("movies");
        assert_eq!(m.fp, "fp123");
        assert_eq!(m.remote_fp, "rfp456");
        assert_eq!(m.count, 10);
    }

    #[test]
    fn update_module_persists_immediately() {
        let (store, _tmp) = make_store();
        // 初始为空
        assert!(store.load().unwrap().modules.is_empty());

        // 更新单个模块
        store
            .update_module(
                "todos",
                ModuleSyncState {
                    fp: "todos_fp".to_string(),
                    count: 5,
                    pushed_at: 999,
                    ..Default::default()
                },
            )
            .unwrap();

        // 重新加载验证
        let loaded = store.load().unwrap();
        let m = loaded.module("todos");
        assert_eq!(m.fp, "todos_fp");
        assert_eq!(m.count, 5);
        assert_eq!(m.pushed_at, 999);
    }

    #[test]
    fn clear_removes_file() {
        let (store, _tmp) = make_store();
        store.save(&SyncState::empty("d")).unwrap();
        assert!(store.path().exists());

        store.clear().unwrap();
        assert!(!store.path().exists());

        // 清除不存在的文件不报错
        store.clear().unwrap();
    }

    #[test]
    fn corrupted_file_returns_error() {
        let (store, _tmp) = make_store();
        std::fs::write(store.path(), "{ invalid json").unwrap();
        let result = store.load();
        assert!(matches!(result, Err(CloudSyncError::State { .. })));
    }

    #[test]
    fn module_returns_default_when_missing() {
        let state = SyncState::empty("d");
        let m = state.module("nonexistent");
        assert!(m.fp.is_empty());
        assert_eq!(m.count, 0);
    }

    #[test]
    fn path_is_in_app_data_dir() {
        let store = SyncStateStore::new(Path::new("/tmp/test_app"));
        assert_eq!(store.path(), Path::new("/tmp/test_app/sync_state.json"));
    }
}
