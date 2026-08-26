//! cloud_sync_api — 云端增量同步高阶 API
//!
//! 在 `cloud_sync::SyncEngine` 之上提供薄壳封装：
//! - 接受 `&SyncEngine` + `&SyncConfig` + 基本参数
//! - 内部构造适配器并调用引擎方法
//! - 返回 `SyncResult`（可序列化为 JSON 字符串供 FRB/Tauri 桥接）
//!
//! ## 单例管理
//! `SyncEngine` 持有 `Arc<Mutex<Option<()>>>` 互斥锁，必须跨调用持久。
//! 桥接层（Tauri managed state / FRB OnceLock）负责创建并持有单例，
//! 本层函数接受 `&SyncEngine` 引用，不管理生命周期。
//!
//! ## FRB 兼容
//! 桥接层将 `SyncResult` 序列化为 JSON 字符串返回，规避跨 crate struct opaque bug。

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::cloud_sync::SyncResult;
use crate::cloud_sync::engine::SyncEngine;
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::progress::{ProgressSender, SyncOrigin};
use crate::cloud_sync::state::SyncState;
use crate::sync::engine::{SyncConfig, create_adapter, validate_config};
use crate::sync::error::SyncError;
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter};
use crate::sync_crypto::SyncCryptoService;

// ============================================================================
// BasePathAdapter：为 cloud_sync 路径自动拼接 base_path 前缀
// ============================================================================

/// 适配器包装器：为所有路径操作自动拼接 `base_path` 前缀
///
/// cloud_sync 的 push/pull/attachments 使用相对路径（如 `_meta.json`、
/// `modules/movies/data.json`），但云端目录结构要求文件存放在 `{base_path}/` 下。
/// 此包装器在不改变 push/pull/attachments 函数签名的前提下，透明地为所有
/// download/upload/upload_asset/download_asset 等调用拼接 base_path。
///
/// full_sync_backup 不使用此包装器（它自行在调用层拼接完整路径），因此不受影响。
struct BasePathAdapter {
    inner: Box<dyn SyncAdapter>,
    base_path: String,
}

impl BasePathAdapter {
    fn new(inner: Box<dyn SyncAdapter>, base_path: &str) -> Self {
        let trimmed = base_path.trim_matches('/');
        Self {
            inner,
            base_path: if trimmed.is_empty() {
                String::new()
            } else {
                trimmed.to_string()
            },
        }
    }

    /// 将相对路径拼接为 `{base_path}/{path}`，base_path 为空时原样返回
    fn join(&self, path: &str) -> String {
        if self.base_path.is_empty() {
            return path.to_string();
        }
        let p = path.trim_start_matches('/');
        if p.is_empty() {
            self.base_path.clone()
        } else {
            format!("{}/{}", self.base_path, p)
        }
    }
}

#[async_trait]
impl SyncAdapter for BasePathAdapter {
    async fn list_files(&self, prefix: &str) -> Result<Vec<RemoteFile>, SyncError> {
        // list_files 的 prefix 由调用方传入，此处拼接 base_path
        self.inner.list_files(&self.join(prefix)).await
    }

    async fn list_all_files(&self, prefix: &str) -> Result<Vec<RemoteFile>, SyncError> {
        self.inner.list_all_files(&self.join(prefix)).await
    }

    async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
        self.inner.download(&self.join(path)).await
    }

    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        self.inner.upload(&self.join(path), data).await
    }

    async fn delete(&self, path: &str) -> Result<(), SyncError> {
        self.inner.delete(&self.join(path)).await
    }

    async fn upload_asset(&self, hash: &str, data: &[u8]) -> Result<(), SyncError> {
        // 附件路径 = {base_path}/assets/{hash}
        let path = format!("assets/{}", hash);
        self.inner.upload(&self.join(&path), data).await
    }

    async fn download_asset(&self, hash: &str) -> Result<Vec<u8>, SyncError> {
        let path = format!("assets/{}", hash);
        self.inner.download(&self.join(&path)).await
    }

    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
        // 通过尝试下载检测存在性；404 视为不存在，其他错误向上传播
        // 注意：此方法未被 cloud_sync push/pull 调用，仅用于 trait 完整性
        let path = format!("assets/{}", hash);
        match self.inner.download(&self.join(&path)).await {
            Ok(_) => Ok(true),
            Err(e) if e.is_not_found() => Ok(false),
            Err(e) => Err(e),
        }
    }

    async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
        // 列出 {base_path}/assets/ 下的文件
        let prefix = self.join("assets");
        let files = self.inner.list_all_files(&prefix).await?;
        Ok(files.into_iter().map(|f| f.name).collect())
    }
}

// ============================================================================
// 引擎构造
// ============================================================================

/// 创建 SyncEngine 实例（使用自定义进度发送器）
///
/// 桥接层应在应用启动时调用一次，将返回的引擎存入 managed state / OnceLock。
/// 后续所有同步操作复用同一实例，保证互斥锁跨调用持久。
pub fn create_engine(
    db_pool: SqlitePool,
    crypto: SyncCryptoService,
    app_data_dir: &Path,
    progress_sender: Arc<dyn ProgressSender>,
) -> SyncEngine {
    SyncEngine::new(db_pool, crypto, app_data_dir, progress_sender)
}

/// 创建 SyncEngine 实例（使用 NoopProgressSender，用于无进度通知场景）
pub fn create_engine_noop(
    db_pool: SqlitePool,
    crypto: SyncCryptoService,
    app_data_dir: &Path,
) -> SyncEngine {
    SyncEngine::new_noop_progress(db_pool, crypto, app_data_dir)
}

// ============================================================================
// 同步操作
// ============================================================================

/// 构造带 base_path 前缀的适配器（供 cloud_sync push/pull/attachments 使用）
///
/// cloud_sync 的 push/pull 使用相对路径（`_meta.json`、`modules/...`），
/// 需通过 `BasePathAdapter` 包装器拼接 `config.base_path` 前缀，
/// 确保文件存放在 `{base_path}/` 目录下，与 meta.rs 文档的云端目录结构一致。
fn create_base_path_adapter(config: &SyncConfig) -> Result<BasePathAdapter, CloudSyncError> {
    validate_config(config).map_err(|e| CloudSyncError::Adapter {
        message: e.to_string(),
    })?;
    let inner = create_adapter(config).map_err(|e| CloudSyncError::Adapter {
        message: e.to_string(),
    })?;
    Ok(BasePathAdapter::new(inner, &config.base_path))
}

/// 构造原始适配器（不带 base_path 前缀）
///
/// 供引擎锁内的 Data Key 同步使用（`bundle_io` 内部自行拼接 base_path 与双读回退）。
/// Fix-08 起 Data Key 同步在 `SyncEngine` 各方法锁内执行，api 层只需传入原始适配器。
fn create_raw_adapter(config: &SyncConfig) -> Result<Box<dyn SyncAdapter>, CloudSyncError> {
    validate_config(config).map_err(|e| CloudSyncError::Adapter {
        message: e.to_string(),
    })?;
    create_adapter(config).map_err(|e| CloudSyncError::Adapter {
        message: e.to_string(),
    })
}

/// 执行完整同步（Push + Pull + 附件）
///
/// 适用于定时同步场景。若已有同步在运行，返回 `SyncResult::skipped()`。
///
/// # 参数
/// - `engine`: 同步引擎单例
/// - `config`: 同步配置（S3/WebDAV）
/// - `origin`: 事件来源（Background/Manual/Exit），UI 层据此过滤重复显示
/// - `device_id`: 当前设备 ID
/// - `attachments_dir`: 本地附件目录
pub async fn sync_now(
    engine: &SyncEngine,
    config: &SyncConfig,
    origin: SyncOrigin,
    device_id: &str,
    attachments_dir: &str,
) -> Result<SyncResult, CloudSyncError> {
    // Fix-08：Data Key 同步已移入 engine.sync_now 互斥锁内，
    // 此处仅需构造两种适配器（带/不带 base_path 前缀）。
    let raw_adapter = create_raw_adapter(config)?;
    let adapter = create_base_path_adapter(config)?;
    engine
        .sync_now(
            &adapter,
            &*raw_adapter,
            &config.base_path,
            origin,
            device_id,
            attachments_dir,
        )
        .await
}

/// 仅 Push（修改后立即同步场景）
///
/// 仅推送本地变更到云端，不拉取远端数据。适用于"修改后立即同步"模式。
///
/// # 参数
/// - `origin`: 事件来源（Background=useSyncOnChange / Exit=退出同步）
pub async fn push_only(
    engine: &SyncEngine,
    config: &SyncConfig,
    origin: SyncOrigin,
    device_id: &str,
    attachments_dir: &str,
) -> Result<SyncResult, CloudSyncError> {
    // Fix-08：Data Key 同步在 engine.push_only 锁内执行
    // （用错误的 Data Key 加密上传会导致云端数据无法被其他设备解密）。
    let raw_adapter = create_raw_adapter(config)?;
    let adapter = create_base_path_adapter(config)?;
    engine
        .push_only(
            &adapter,
            &*raw_adapter,
            &config.base_path,
            origin,
            device_id,
            attachments_dir,
        )
        .await
}

/// 先 Pull 再 Push（启动页场景）
///
/// 先拉取远端变更合并到本地，再推送本地变更到远端。
/// 保证启动时获取最新数据，同时不丢失本地新增。
///
/// # 参数
/// - `origin`: 事件来源（Background/Manual/Exit）
pub async fn pull_then_push(
    engine: &SyncEngine,
    config: &SyncConfig,
    origin: SyncOrigin,
    device_id: &str,
    attachments_dir: &str,
) -> Result<SyncResult, CloudSyncError> {
    // Fix-08：Data Key 同步在 engine.pull_then_push 锁内执行
    // （pull 前必须导入云端 Data Key，否则解密失败）。
    let raw_adapter = create_raw_adapter(config)?;
    let adapter = create_base_path_adapter(config)?;
    engine
        .pull_then_push(
            &adapter,
            &*raw_adapter,
            &config.base_path,
            origin,
            device_id,
            attachments_dir,
        )
        .await
}

// ============================================================================
// 状态查询
// ============================================================================

/// 获取本地同步状态（sync_state.json 内容）
pub fn get_state(engine: &SyncEngine) -> Result<SyncState, CloudSyncError> {
    engine.get_state()
}

/// 检查同步是否正在运行
pub async fn is_running(engine: &SyncEngine) -> bool {
    engine.is_running().await
}

/// 将 SyncResult 序列化为 JSON 字符串（供 FRB/Tauri 桥接返回）
pub fn result_to_json(result: &SyncResult) -> Result<String, CloudSyncError> {
    serde_json::to_string(result).map_err(|e| CloudSyncError::Serialize {
        message: e.to_string(),
    })
}

/// 将 SyncState 序列化为 JSON 字符串
pub fn state_to_json(state: &SyncState) -> Result<String, CloudSyncError> {
    serde_json::to_string(state).map_err(|e| CloudSyncError::Serialize {
        message: e.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_to_json_roundtrip() {
        let result = SyncResult {
            pushed_modules: 3,
            pulled_modules: 2,
            uploaded_attachments: 1,
            downloaded_attachments: 0,
            duration_ms: 500,
            skipped: false,
            errors: vec![],
        };
        let json = result_to_json(&result).unwrap();
        assert!(json.contains("\"pushed_modules\":3"));
        assert!(json.contains("\"skipped\":false"));
    }

    #[test]
    fn result_to_json_skipped() {
        let result = SyncResult::skipped();
        let json = result_to_json(&result).unwrap();
        assert!(json.contains("\"skipped\":true"));
    }
}
