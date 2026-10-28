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
use bytes::Bytes;
use sqlx::SqlitePool;

use crate::cloud_sync::SyncResult;
use crate::cloud_sync::engine::{
    SYNC_TYPE_PULL_THEN_PUSH, SYNC_TYPE_PUSH_ONLY, SYNC_TYPE_SYNC_NOW, SyncEngine,
};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::progress::{ProgressSender, SyncOrigin};
use crate::cloud_sync::state::SyncState;
use crate::sync::cancel::SyncCancelToken;
use crate::sync::engine::{SyncConfig, create_adapter, validate_config};
use crate::sync::error::SyncError;
use crate::sync_adapters::traits::{
    RemoteAssetObject, RemoteFile, SyncAdapter, UploadOutcome, UploadPrecondition,
};
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
/// **不变量（F22，2026-09-19 第五轮探查）**：`SyncAdapter` 的**每一个**方法都必须
/// 在此显式转发。trait 为 `exists`/`download_with_token`/`upload_conditional`
/// 提供的是「mock 友好」的退化默认实现（HEAD 降级为下载、令牌恒 `None`、
/// 前置条件被忽略后无条件覆盖）——漏转发一个就等于静默关掉一层并发保护，
/// 且编译与既有单测都不会报警（生产弱于 mock，即假绿）。
///
/// full_sync_backup 不使用此包装器（它自行在调用层拼接完整路径），因此不受影响。
struct BasePathAdapter {
    /// 共享底层适配器（Arc 而非 Box）：同一轮同步里 raw 适配器与包装器
    /// 必须指向同一实例，否则各自持有独立的 reqwest 连接池（F40：
    /// 每轮两个全新 Client，phase 间无热连接）
    inner: Arc<dyn SyncAdapter>,
    base_path: String,
    /// N33 协作式取消令牌：每次转发前检查，数据桶 / 附件 / 清单请求之间
    /// 都能在毫秒级停下；分片循环内部的逐片检查由内层适配器负责
    cancel: Arc<SyncCancelToken>,
}

impl BasePathAdapter {
    fn new(inner: Arc<dyn SyncAdapter>, base_path: &str) -> Self {
        Self::with_cancel(inner, base_path, Arc::new(SyncCancelToken::new()))
    }

    fn with_cancel(
        inner: Arc<dyn SyncAdapter>,
        base_path: &str,
        cancel: Arc<SyncCancelToken>,
    ) -> Self {
        let trimmed = base_path.trim_matches('/');
        Self {
            inner,
            base_path: if trimmed.is_empty() {
                String::new()
            } else {
                trimmed.to_string()
            },
            cancel,
        }
    }

    /// N33：已取消则立即返回，不再发起下一次远端调用
    fn check_cancel(&self) -> Result<(), SyncError> {
        self.cancel.check()
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
    fn attach_cancel(&self, token: Arc<SyncCancelToken>) {
        // 包装器自身在构造时已绑定同一个令牌；这里只负责把令牌传给内层，
        // 让 S3/WebDAV 的分片循环也能逐片检查
        self.inner.attach_cancel(token);
    }

    fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    async fn list_all_files(&self, prefix: &str) -> Result<Vec<RemoteFile>, SyncError> {
        self.check_cancel()?;
        self.inner.list_all_files(&self.join(prefix)).await
    }

    async fn download(&self, path: &str) -> Result<Bytes, SyncError> {
        self.check_cancel()?;
        self.inner.download(&self.join(path)).await
    }

    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        self.check_cancel()?;
        self.inner.upload(&self.join(path), data).await
    }

    async fn upload_owned(&self, path: &str, data: Vec<u8>) -> Result<(), SyncError> {
        self.check_cancel()?;
        // A13：所有权透传给内层，避免包装层复制
        self.inner.upload_owned(&self.join(path), data).await
    }

    async fn delete(&self, path: &str) -> Result<(), SyncError> {
        self.check_cancel()?;
        self.inner.delete(&self.join(path)).await
    }

    async fn upload_asset(&self, hash: &str, data: Vec<u8>) -> Result<(), SyncError> {
        self.check_cancel()?;
        // S1（2026-09-13 探查）：统一附件命名口径为 paths::asset_path
        // （`assets/{hash}.orsync`，默认格式）。此前三套口径分裂曾致死循环，
        // 现写侧统一新后缀，读侧多级回退。
        // base_path 拼接仍由本包装器负责（内层构造不含 base_path 语义）。
        // F75：trait 默认实现（拼路径走上传）对本包装器不可用——它拼出的
        // 是**无 base_path 前缀**的路径；委托的也必须是内层上传而非
        // inner.upload_asset（后者经默认实现同样丢前缀）。
        // A13：走 `upload_owned`，附件是最大一类载荷，借用语义会多吃一次整包复制。
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.inner.upload_owned(&self.join(&path), data).await
    }

    async fn download_asset(&self, hash: &str) -> Result<Bytes, SyncError> {
        self.check_cancel()?;
        // 附件单一路径（无历史数据，不再回退遗留命名）。
        // 「单对象 → 分片拼装」的形态回退由内层适配器负责。
        // F75：同 upload_asset——包装器必须自己拼 base_path。
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.inner.download(&self.join(&path)).await
    }

    async fn upload_asset_file(
        &self,
        hash: &str,
        local_path: &std::path::Path,
        total_len: u64,
    ) -> Result<(), SyncError> {
        self.check_cancel()?;
        // M3：必须转发——内层 `upload_file` 才有流式/分片能力；
        // 默认实现会把加密容器整包读回来，等于白做流式化。
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.inner
            .upload_file(&self.join(&path), local_path, total_len)
            .await
    }

    async fn download_asset_to_file(
        &self,
        hash: &str,
        target: &std::path::Path,
    ) -> Result<u64, SyncError> {
        self.check_cancel()?;
        // M3：路径级转发，保留内层「单对象 → 分片拼装」回退。
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.inner.download_to_file(&self.join(&path), target).await
    }

    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
        self.check_cancel()?;
        // 内层适配器自带「单对象 → 分片清单」两段探测（HEAD 实现）
        // F75：同 upload_asset——包装器必须自己拼 base_path。
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.inner.exists(&self.join(&path)).await
    }

    async fn list_assets(&self, assets_dir: &str) -> Result<Vec<String>, SyncError> {
        self.check_cancel()?;
        // F23：委托内层适配器列举，包装器只负责把 base_path 拼进目录。
        // 此前这里是自行「list assets 目录 + 剥后缀」的复制品：看不见
        // assets_parts 下的分片附件（差集每轮缺席 → 空跑重传、云端孤儿
        // 永不清理），而内层实现（含 S4 并集逻辑）被架空成死代码。
        self.inner.list_assets(&self.join(assets_dir)).await
    }

    async fn list_assets_with_meta(
        &self,
        assets_dir: &str,
    ) -> Result<Vec<RemoteAssetObject>, SyncError> {
        self.check_cancel()?;
        // F22 口径：包装器的每个方法都必须显式转发并拼 base_path。漏转发会
        // 退化为默认实现（list_assets + 全零元数据）——扫描结果看起来正常，
        // 但年龄窗口判定因 mtime=0 全部跳过，清理按钮永远筛不出东西。
        self.inner
            .list_assets_with_meta(&self.join(assets_dir))
            .await
    }

    async fn exists(&self, path: &str) -> Result<bool, SyncError> {
        self.check_cancel()?;
        // 必须转发：默认实现会整对象下载来判存在（HEAD 优化随之失效）
        self.inner.exists(&self.join(path)).await
    }

    async fn download_with_token(
        &self,
        path: &str,
    ) -> Result<Option<(Bytes, Option<String>)>, SyncError> {
        self.check_cancel()?;
        // 必须转发：默认实现把令牌钉死为 None，清单 CAS 随之退化为裸覆盖
        self.inner.download_with_token(&self.join(path)).await
    }

    async fn upload_conditional(
        &self,
        path: &str,
        data: &[u8],
        precondition: UploadPrecondition,
    ) -> Result<UploadOutcome, SyncError> {
        self.check_cancel()?;
        // 必须转发：默认实现丢弃前置条件直接覆盖上传，
        // `If-Match`/`If-None-Match` 一个都不会发到网络上
        self.inner
            .upload_conditional(&self.join(path), data, precondition)
            .await
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

/// 构造一轮同步用的适配器对：`(原始适配器, 带 base_path 包装器)`
///
/// cloud_sync 的 push/pull 使用相对路径（`_meta.json`、`modules/...`），
/// 需通过 `BasePathAdapter` 包装器拼接 `config.base_path` 前缀，
/// 确保文件存放在 `{base_path}/` 目录下，与 meta.rs 文档的云端目录结构一致。
///
/// 原始适配器供引擎锁内的 Data Key 同步使用（`bundle_io` 内部自行拼接
/// base_path 与双读回退）。两者**共享同一底层实例**（F40）：此前各构造一次
/// `create_adapter` → 两个独立 reqwest 连接池，push/pull/DataKey 三个阶段
/// 互不复用热连接，每轮同步多付一次 TLS/连接建立成本。
fn create_adapters(
    config: &SyncConfig,
) -> Result<(Arc<dyn SyncAdapter>, BasePathAdapter), CloudSyncError> {
    create_adapters_with_cancel(config, None)
}

/// 同上，但把引擎的取消令牌同时绑到包装器与底层适配器（N33）
///
/// 包装器负责「每次远端调用前」检查（数据桶 / 附件 / 清单边界），
/// 底层 S3/WebDAV 负责「分片循环每片」检查。备份 / GC / 连通性探测
/// 不传令牌（`None`），行为与改前一致。
fn create_adapters_with_cancel(
    config: &SyncConfig,
    cancel: Option<&Arc<SyncCancelToken>>,
) -> Result<(Arc<dyn SyncAdapter>, BasePathAdapter), CloudSyncError> {
    validate_config(config).map_err(|e| CloudSyncError::Adapter {
        message: e.to_string(),
    })?;
    let inner: Arc<dyn SyncAdapter> =
        Arc::from(create_adapter(config).map_err(|e| CloudSyncError::Adapter {
            message: e.to_string(),
        })?);
    let adapter = match cancel {
        Some(token) => {
            // 底层适配器只用于分片循环的逐片检查；包装器持有同一令牌
            inner.attach_cancel(token.clone());
            BasePathAdapter::with_cancel(inner.clone(), &config.base_path, token.clone())
        }
        None => BasePathAdapter::new(inner.clone(), &config.base_path),
    };
    Ok((inner, adapter))
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
    let (raw_adapter, adapter) = create_adapters_with_cancel(config, Some(engine.cancel_token()))?;
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
    let (raw_adapter, adapter) = create_adapters_with_cancel(config, Some(engine.cancel_token()))?;
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
    let (raw_adapter, adapter) = create_adapters_with_cancel(config, Some(engine.cancel_token()))?;
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
// 强制同步（进入 / 退出应用）
// ============================================================================

/// 强制同步：进入应用与退出应用时使用
///
/// ## 与 `sync_now` / `pull_then_push` 的唯一差别
/// 只在**调用前提**：本函数不读取任何「自动同步开关 / 同步间隔 / 修改后
/// 立即同步」设置——是否该同步由调用方判定（壳层已确认「配置存在 + 已解锁」）。
/// 引擎侧仍走既有互斥与账本逻辑，不做任何开关绕过以外的特例。
///
/// ## 忙时语义
/// 引擎正忙时不立即返回 `skipped`（那会让"退出同步"静默丢失），而是等待
/// 最多 `wait_for_idle_ms` 再执行；等待超时仍忙则交由 `acquire_lock` 返回
/// `skipped`，调用方须把它当作"本轮未执行"处理。
pub async fn force_sync(
    engine: &SyncEngine,
    config: &SyncConfig,
    origin: SyncOrigin,
    device_id: &str,
    attachments_dir: &str,
    wait_for_idle_ms: u64,
) -> Result<SyncResult, CloudSyncError> {
    if wait_for_idle_ms > 0 {
        let idle = engine.wait_idle(wait_for_idle_ms).await;
        if !idle {
            log::info!("[force_sync] 等待引擎空闲超时（{wait_for_idle_ms}ms），仍尝试执行");
        }
    }
    pull_then_push(engine, config, origin, device_id, attachments_dir).await
}

// ============================================================================
// 云端孤儿附件清理（docs/15）
//
// 只读扫描 + 手动删除，**无自动触发路径**：本地优先，删除时机归用户。
// 判据/兜底/删除顺序全在 `cloud_sync::asset_gc`（业务下沉），本层只做
// 「构造适配器 + 读清单 + join 本地账本 + 账本收尾」。
// ============================================================================

/// 云端孤儿附件清单行（诊断页展示）
#[derive(Debug, Clone, serde::Serialize)]
pub struct CloudUnusedAttachmentView {
    pub hash: String,
    /// 密文体积；WebDAV 分片形态为 0（目录条目没有长度），展示时用 `size_bytes` 兜底
    pub cipher_bytes: u64,
    /// 服务端最后修改时间（Unix 秒）
    pub last_modified: i64,
    /// 云端形态：`whole` / `chunked` / `both`
    pub kind: String,
    /// 本地账本元数据（账本无该行时为空/0）
    pub original_name: String,
    /// 明文体积（本地账本；0 表示账本无记录）
    pub size_bytes: i64,
    pub is_local_cached: i32,
    pub is_uploaded: i32,
}

/// 扫描结果
#[derive(Debug, Clone, serde::Serialize)]
pub struct CloudUnusedScanResult {
    pub items: Vec<CloudUnusedAttachmentView>,
    /// 清单 epoch——删除时必须原样回传做 CAS
    pub epoch: u64,
    /// 年龄窗口（UI 文案展示「仅含 N 天前的对象」）
    pub min_age_secs: i64,
}

/// 删除结果（含本地账本收尾统计）
#[derive(Debug, Clone, serde::Serialize)]
pub struct CloudUnusedDeleteResult {
    pub deleted_assets: u32,
    pub deleted_objects: u32,
    pub skipped_referenced: u32,
    pub local_rows_cleaned: usize,
    pub stale_manifest: bool,
    pub errors: Vec<String>,
}

/// 只读扫描云端孤儿附件
///
/// 不写库、不 emit 事件（`sys_attachments` 不在同步白名单，诊断读数走独立查询）。
pub async fn cloud_unused_attachments_scan(
    engine: &SyncEngine,
    config: &SyncConfig,
) -> Result<CloudUnusedScanResult, String> {
    let (_raw, adapter) = create_adapters(config).map_err(|e| e.to_string())?;
    let data_key = engine
        .crypto_service()
        .get_data_key()
        .ok_or_else(|| "同步密钥未解锁，无法读取云端附件清单".to_string())?;
    let manifest = crate::cloud_sync::asset_gc::read_cloud_manifest(&adapter, &data_key)
        .await
        .map_err(|e| format!("读取云端清单失败: {e}"))?
        .ok_or_else(|| "云端尚无同步清单，请先完成一次同步".to_string())?;

    let now = chrono::Utc::now().timestamp();
    let objects = crate::cloud_sync::asset_gc::scan_cloud_orphan_assets(
        &adapter,
        &data_key,
        &manifest,
        crate::cloud_sync::asset_gc::DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .map_err(|e| format!("扫描云端孤儿附件失败: {e}"))?;

    // join 本地账本：展示名/明文体积/缓存状态（体积展示 WebDAV 分片时为 0 的兜底）
    let hashes: Vec<String> = objects.iter().map(|o| o.hash.clone()).collect();
    let rows = crate::db::repository::attachment_repo::get_by_hashes(engine.pool(), &hashes)
        .await
        .map_err(|e| format!("查询本地附件账本失败: {e}"))?;
    let by_hash: std::collections::HashMap<&str, &_> =
        rows.iter().map(|a| (a.hash.as_str(), a)).collect();

    let items: Vec<CloudUnusedAttachmentView> = objects
        .into_iter()
        .map(|o| {
            let row = by_hash.get(o.hash.as_str());
            CloudUnusedAttachmentView {
                hash: o.hash,
                cipher_bytes: o.cipher_bytes,
                last_modified: o.last_modified,
                kind: match o.kind {
                    crate::sync_adapters::traits::RemoteAssetKind::Whole => "whole",
                    crate::sync_adapters::traits::RemoteAssetKind::Chunked => "chunked",
                    crate::sync_adapters::traits::RemoteAssetKind::Both => "both",
                }
                .to_string(),
                original_name: row.map(|r| r.original_name.clone()).unwrap_or_default(),
                size_bytes: row.map(|r| r.size_bytes).unwrap_or(0),
                is_local_cached: row.map(|r| r.is_local_cached).unwrap_or(0),
                is_uploaded: row.map(|r| r.is_uploaded).unwrap_or(0),
            }
        })
        .collect();

    Ok(CloudUnusedScanResult {
        items,
        epoch: manifest.epoch,
        min_age_secs: crate::cloud_sync::asset_gc::DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
    })
}

/// 孤儿数据分桶回收结果（docs/07 #96 尾款入口）
#[derive(Debug, Clone, serde::Serialize)]
pub struct OrphanChunkGcResult {
    /// 删除成功（含原本已不存在）的分桶对象数
    pub deleted_buckets: u32,
    /// 单对象失败明细（不中断）
    pub errors: Vec<String>,
}

/// 回收「清单已无引用 + mtime 早于 24h」的孤儿数据分桶（手动触发）
///
/// 对应 `cloud_sync::gc::collect_and_delete_orphan_chunks` 的生产入口（此前只有
/// 原语没有调用方）。与附件清理同一张「云端存储」卡片，但**只动 `tables/`**，
/// 不碰附件对象；判据是清单索引（无引用即不可达）而不是引用行内容。
///
/// 必须在清单落定之后执行：本函数先读一次云端清单，删除的都是它未引用的桶。
pub async fn cloud_orphan_chunks_gc(
    engine: &SyncEngine,
    config: &SyncConfig,
) -> Result<OrphanChunkGcResult, String> {
    let (_raw, adapter) = create_adapters(config).map_err(|e| e.to_string())?;
    let data_key = engine
        .crypto_service()
        .get_data_key()
        .ok_or_else(|| "同步密钥未解锁，无法读取云端清单".to_string())?;
    let manifest = crate::cloud_sync::asset_gc::read_cloud_manifest(&adapter, &data_key)
        .await
        .map_err(|e| format!("读取云端清单失败: {e}"))?
        .ok_or_else(|| "云端尚无同步清单，请先完成一次同步".to_string())?;

    let result =
        crate::cloud_sync::gc::collect_and_delete_orphan_chunks(&adapter, &manifest, 24 * 3600)
            .await
            .map_err(|e| format!("回收孤儿数据分桶失败: {e}"))?;
    Ok(OrphanChunkGcResult {
        deleted_buckets: result.deleted_buckets,
        errors: result.errors,
    })
}

/// 删除云端孤儿附件（整包 + 分片），成功后收尾本地账本
///
/// `expected_epoch` 来自扫描结果的 `epoch`：云端刚有他端 push（引用集可能已变）
/// 时拒绝执行，前端提示重扫。云端删除有任一失败时**不动本地账本**——对象可能
/// 还在，账本行仍是有价值的元数据。
pub async fn cloud_unused_attachments_delete(
    engine: &SyncEngine,
    config: &SyncConfig,
    attachments_dir: &str,
    hashes: Vec<String>,
    expected_epoch: u64,
) -> Result<CloudUnusedDeleteResult, String> {
    let (_raw, adapter) = create_adapters(config).map_err(|e| e.to_string())?;
    let data_key = engine
        .crypto_service()
        .get_data_key()
        .ok_or_else(|| "同步密钥未解锁，无法删除云端附件".to_string())?;
    let now = chrono::Utc::now().timestamp();

    let deleted = crate::cloud_sync::asset_gc::delete_cloud_assets(
        &adapter,
        &data_key,
        expected_epoch,
        &hashes,
        crate::cloud_sync::asset_gc::DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .map_err(|e| format!("删除云端孤儿附件失败: {e}"))?;

    // 云端确认删除后，本地账本行按「无存活引用」原子复核收尾（同时清本地缓存
    // 文件）。被重新挂载的 hash 不会命中；stale/部分失败时整体跳过，保持可重试。
    let mut local_rows_cleaned = 0;
    if !deleted.stale_manifest && deleted.errors.is_empty() {
        local_rows_cleaned = crate::api::asset_api::delete_unused_attachments(
            engine.pool(),
            attachments_dir,
            &hashes,
        )
        .await
        .map_err(|e| format!("清理本地附件账本失败: {e}"))?;
    }

    Ok(CloudUnusedDeleteResult {
        deleted_assets: deleted.deleted_assets,
        deleted_objects: deleted.deleted_objects,
        skipped_referenced: deleted.skipped_referenced,
        local_rows_cleaned,
        stale_manifest: deleted.stale_manifest,
        errors: deleted.errors,
    })
}

// ============================================================================
// 状态查询
// ============================================================================

/// 获取本地同步状态（sync_state.json 内容）
pub fn get_state(engine: &SyncEngine) -> Result<SyncState, CloudSyncError> {
    engine.get_state()
}

/// 检查同步是否正在运行（S5：同步探测，不再阻塞等待锁）
pub fn is_running(engine: &SyncEngine) -> bool {
    engine.is_running()
}

// ============================================================================
// rekey 全量重传（v2 改密 / v1→v2 迁移 / KeyMismatch 恢复共用）
// ============================================================================

/// 用引擎当前内存中的 Data Key 重加密覆盖云端全部数据
///
/// 调用前置：`crypto` 已切换/解锁到目标 Key（引擎在锁内自校验，未解锁返回
/// `CryptoLocked`）。三个场景：
/// - v2 改密：云端旧密码 Key 密文全部失效，重传后其他设备输入新密码即可同步
/// - v1→v2 迁移：随机 Key → 确定性 Key，重传后其他设备同密码自动对齐
/// - KeyMismatch 恢复「以本机为准」：放弃解不开的云端数据（见恢复页）
///
/// **危险操作**：远端数据被有意覆盖且不做 Pull 合并，调用方必须用户确认后调用。
pub async fn rekey_cloud(
    engine: &SyncEngine,
    config: &SyncConfig,
    origin: SyncOrigin,
    device_id: &str,
    attachments_dir: &str,
) -> Result<SyncResult, CloudSyncError> {
    let (raw_adapter, adapter) = create_adapters(config)?;
    engine
        .rekey_cloud_reencrypt(
            &adapter,
            &*raw_adapter,
            &config.base_path,
            origin,
            device_id,
            attachments_dir,
        )
        .await
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

// ============================================================================
// 同步历史查询（sync_history 表只读聚合——不 emit 事件、不进同步白名单）
// ============================================================================

/// 查询增量同步历史（P1-17 展示面）
///
/// `scope` 口径：
/// - "incremental"：完整同步（定时/手动「立即同步」触发）
/// - "push_only"：修改后即时推送
/// - "pull_only"：启动先拉后推
/// - "all"：以上三类合并（不包含全量备份类型）
///
/// 按开始时间倒序返回最近 `limit` 条。
pub async fn incremental_history(
    pool: &SqlitePool,
    scope: &str,
    limit: i64,
) -> Result<Vec<crate::models::business::SyncHistory>, CloudSyncError> {
    let types: Vec<&str> = match scope {
        "incremental" => vec![SYNC_TYPE_SYNC_NOW],
        "push_only" => vec![SYNC_TYPE_PUSH_ONLY],
        "pull_only" => vec![SYNC_TYPE_PULL_THEN_PUSH],
        _ => vec![
            SYNC_TYPE_SYNC_NOW,
            SYNC_TYPE_PUSH_ONLY,
            SYNC_TYPE_PULL_THEN_PUSH,
        ],
    };
    crate::db::repository::sync_history_repo::get_recent_by_types(pool, &types, limit)
        .await
        .map_err(|e| CloudSyncError::Database {
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
            conflicts: 0,
            duration_ms: 500,
            skipped: false,
            errors: vec![],
            changed_tables: vec![],
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

    // ========================================================================
    // S1（2026-09-13 探查）：BasePathAdapter 附件命名口径对齐定向测试
    //
    // 统一 `assets/{hash}.orsync` 默认命名 + 遗留命名迁移兼容。
    // 历史 bug：多套口径分裂，桶中存在遗留对象时经 list 进差集 → 下载命中但
    // sha256 校验必失败 → 每轮重复下载死循环。
    // ========================================================================

    /// S1 定向测试 mock：维护 path → data 映射（未命中返回 NotFound 变体，
    /// 与 is_not_found() 的类型判断口径一致）；upload/list 调用经 Arc 共享
    /// 记录，包装器持有 Box 后测试侧仍可断言。
    struct AssetMockAdapter {
        files: std::collections::HashMap<String, Vec<u8>>,
        listing: Vec<RemoteFile>,
        uploads: Arc<std::sync::Mutex<Vec<String>>>,
        list_prefixes: Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl AssetMockAdapter {
        fn new() -> Self {
            Self {
                files: std::collections::HashMap::new(),
                listing: Vec::new(),
                uploads: Arc::new(std::sync::Mutex::new(Vec::new())),
                list_prefixes: Arc::new(std::sync::Mutex::new(Vec::new())),
            }
        }

        fn with_file(mut self, path: &str, data: &[u8]) -> Self {
            self.files.insert(path.to_string(), data.to_vec());
            self
        }

        fn with_listing(mut self, names: &[&str]) -> Self {
            self.listing = names
                .iter()
                .map(|n| RemoteFile {
                    name: n.to_string(),
                    size: 0,
                    last_modified: 0,
                    etag: None,
                })
                .collect();
            self
        }
    }

    #[async_trait]
    impl SyncAdapter for AssetMockAdapter {
        async fn list_all_files(&self, prefix: &str) -> Result<Vec<RemoteFile>, SyncError> {
            self.list_prefixes.lock().unwrap().push(prefix.to_string());
            Ok(self.listing.clone())
        }
        async fn download(&self, path: &str) -> Result<Bytes, SyncError> {
            match self.files.get(path) {
                Some(data) => Ok(Bytes::from(data.clone())),
                None => Err(SyncError::NotFound {
                    message: format!("资源不存在: {path}"),
                }),
            }
        }
        async fn upload(&self, path: &str, _data: &[u8]) -> Result<(), SyncError> {
            self.uploads.lock().unwrap().push(path.to_string());
            Ok(())
        }
        async fn delete(&self, _path: &str) -> Result<(), SyncError> {
            Ok(())
        }
        async fn upload_asset(&self, hash: &str, data: Vec<u8>) -> Result<(), SyncError> {
            self.upload(&format!("assets/{hash}.orsync"), &data).await
        }
        async fn download_asset(&self, hash: &str) -> Result<Bytes, SyncError> {
            self.download(&format!("assets/{hash}.orsync")).await
        }
        async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
            Ok(self.files.contains_key(&format!("assets/{hash}.orsync")))
        }
        async fn list_assets(&self, assets_dir: &str) -> Result<Vec<String>, SyncError> {
            // 与两个生产适配器的契约一致：入参是**完整云端目录**，返回裸 hash
            // （S3 的 Key 已按前缀剥离、WebDAV 的 name 是 basename，
            // 平铺 assets 目录下两口径同形——F23 归一化责任在下沉到适配器）
            self.list_prefixes
                .lock()
                .unwrap()
                .push(assets_dir.to_string());
            let mut hashes: Vec<String> = self
                .listing
                .iter()
                .map(|f| crate::cloud_sync::paths::strip_sync_extension(&f.name).to_string())
                .collect();
            hashes.sort();
            Ok(hashes)
        }
    }

    /// 附件命名单一口径（`assets/{hash}.orsync`），读写/列举/探测全部对齐
    ///
    /// 历史上曾并存多种命名，读侧要多段
    /// 回退，且"两个对象同一 hash"会让 list 差集与内容校验打架。现在只有一种
    /// 命名（开发阶段无历史数据），回退路径整体移除。
    #[tokio::test]
    async fn asset_paths_use_single_naming_scheme() {
        let mock = AssetMockAdapter::new()
            .with_file("wait-sync/user1/assets/abc123.orsync", b"abc-data")
            .with_listing(&["abc123.orsync", "def456.orsync"]);

        let uploads = mock.uploads.clone();
        let list_prefixes = mock.list_prefixes.clone();
        let adapter = BasePathAdapter::new(Arc::new(mock), "wait-sync/user1");

        // list_assets：委托内层适配器，前缀带 base_path，返回裸 hash
        // （F23：归一化与 assets_parts 并集是适配器的职责，包装器只拼前缀）
        let hashes = adapter.list_assets("assets").await.unwrap();
        assert_eq!(hashes, vec!["abc123".to_string(), "def456".to_string()]);
        assert_eq!(
            list_prefixes.lock().unwrap().as_slice(),
            ["wait-sync/user1/assets"],
            "list 前缀必须带 base_path"
        );

        // download_asset：命中即返回；未命中 → NotFound 透传（无回退）
        assert_eq!(
            &adapter.download_asset("abc123").await.unwrap()[..],
            b"abc-data"
        );
        assert!(
            adapter
                .download_asset("zzz")
                .await
                .unwrap_err()
                .is_not_found()
        );

        // asset_exists：存在 / 不存在
        assert!(adapter.asset_exists("abc123").await.unwrap());
        assert!(!adapter.asset_exists("missing").await.unwrap());

        // upload_asset：统一写 assets/{hash}.orsync 并拼接 base_path
        adapter.upload_asset("new1", b"x".to_vec()).await.unwrap();
        assert_eq!(
            uploads.lock().unwrap().as_slice(),
            ["wait-sync/user1/assets/new1.orsync"]
        );
    }

    /// base_path 为空时路径原样透传（根目录部署形态）
    #[tokio::test]
    async fn s1_empty_base_path_passes_through() {
        let mock = AssetMockAdapter::new();
        let uploads = mock.uploads.clone();
        let adapter = BasePathAdapter::new(Arc::new(mock), "");

        adapter.upload_asset("h1", b"x".to_vec()).await.unwrap();
        assert_eq!(uploads.lock().unwrap().as_slice(), ["assets/h1.orsync"]);
    }

    /// 带并发令牌与条件写的 mock（形状对齐 `cloud_sync::push::tests::MemAdapter`）
    ///
    /// 关键：它**实现**了 `download_with_token`/`upload_conditional`/`exists`。
    /// F22 的失效模式正是「包装器少转发一个方法 → 落到 trait 退化默认 →
    /// 生产实现比 mock 更弱」，所以断言必须打在「调用真的到达内层」上。
    struct CasMockAdapter {
        objects: std::sync::Mutex<std::collections::HashMap<String, (Vec<u8>, String)>>,
        seen: Arc<std::sync::Mutex<Vec<String>>>,
        seen_preconditions: Arc<std::sync::Mutex<Vec<String>>>,
        exists_hits: Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl CasMockAdapter {
        fn new(path: &str, data: &[u8], etag: &str) -> Self {
            let mut objects = std::collections::HashMap::new();
            objects.insert(path.to_string(), (data.to_vec(), etag.to_string()));
            Self {
                objects: std::sync::Mutex::new(objects),
                seen: Arc::new(std::sync::Mutex::new(Vec::new())),
                seen_preconditions: Arc::new(std::sync::Mutex::new(Vec::new())),
                exists_hits: Arc::new(std::sync::Mutex::new(Vec::new())),
            }
        }

        fn describe(precondition: &UploadPrecondition) -> String {
            match precondition {
                UploadPrecondition::None => "none".to_string(),
                UploadPrecondition::Absent => "absent".to_string(),
                UploadPrecondition::Match(token) => format!("match:{token}"),
            }
        }
    }

    #[async_trait]
    impl SyncAdapter for CasMockAdapter {
        async fn download(&self, path: &str) -> Result<Bytes, SyncError> {
            self.objects
                .lock()
                .unwrap()
                .get(path)
                .map(|(b, _)| Bytes::from(b.clone()))
                .ok_or_else(|| SyncError::NotFound {
                    message: path.to_string(),
                })
        }
        async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
            self.objects
                .lock()
                .unwrap()
                .insert(path.to_string(), (data.to_vec(), "v+1".to_string()));
            Ok(())
        }
        async fn delete(&self, _: &str) -> Result<(), SyncError> {
            Ok(())
        }
        async fn upload_asset(&self, _: &str, _: Vec<u8>) -> Result<(), SyncError> {
            Ok(())
        }
        async fn download_asset(&self, _: &str) -> Result<Bytes, SyncError> {
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
        async fn exists(&self, path: &str) -> Result<bool, SyncError> {
            self.exists_hits.lock().unwrap().push(path.to_string());
            Ok(self.objects.lock().unwrap().contains_key(path))
        }
        async fn download_with_token(
            &self,
            path: &str,
        ) -> Result<Option<(Bytes, Option<String>)>, SyncError> {
            self.seen.lock().unwrap().push(path.to_string());
            Ok(self
                .objects
                .lock()
                .unwrap()
                .get(path)
                .map(|(b, etag)| (Bytes::from(b.clone()), Some(etag.clone()))))
        }
        async fn upload_conditional(
            &self,
            path: &str,
            data: &[u8],
            precondition: UploadPrecondition,
        ) -> Result<UploadOutcome, SyncError> {
            self.seen.lock().unwrap().push(path.to_string());
            self.seen_preconditions
                .lock()
                .unwrap()
                .push(Self::describe(&precondition));
            let mut objects = self.objects.lock().unwrap();
            let current = objects.get(path).map(|(_, etag)| etag.clone());
            let satisfied = match &precondition {
                UploadPrecondition::None => true,
                UploadPrecondition::Absent => current.is_none(),
                UploadPrecondition::Match(token) => current.as_deref() == Some(token.as_str()),
            };
            if !satisfied {
                return Ok(UploadOutcome::PreconditionFailed);
            }
            objects.insert(path.to_string(), (data.to_vec(), "v+1".to_string()));
            Ok(UploadOutcome::Ok)
        }
    }

    /// F22 回归防线：包装器必须把「令牌 / 前置条件 / HEAD 探测」三件事真的送到内层
    ///
    /// 修复前本用例三处全红：令牌恒 `None`、前置条件塌成裸覆盖写、
    /// `exists` 走默认实现下载整对象。
    #[tokio::test]
    async fn wrapper_forwards_tokens_preconditions_and_head_probe() {
        let joined = "wait-sync/user1/manifest.orsync";
        let mock = CasMockAdapter::new(joined, b"remote-manifest", "etag-7");
        let seen = mock.seen.clone();
        let seen_pre = mock.seen_preconditions.clone();
        let exists_hits = mock.exists_hits.clone();
        let adapter = BasePathAdapter::new(Arc::new(mock), "wait-sync/user1");

        // 1. 令牌透出 + 路径已拼 base_path
        let got = adapter
            .download_with_token("manifest.orsync")
            .await
            .unwrap()
            .expect("对象存在必须返回 Some");
        assert_eq!(&got.0[..], b"remote-manifest");
        assert_eq!(
            got.1.as_deref(),
            Some("etag-7"),
            "并发令牌不得被包装器的 trait 默认实现吞成 None"
        );
        assert_eq!(seen.lock().unwrap().as_slice(), [joined]);

        // 2. 陈旧令牌 → PreconditionFailed（CAS 真的有在生效）
        let stale = adapter
            .upload_conditional(
                "manifest.orsync",
                b"mine",
                UploadPrecondition::Match("etag-stale".to_string()),
            )
            .await
            .unwrap();
        assert_eq!(
            stale,
            UploadOutcome::PreconditionFailed,
            "令牌不符必须回条件失败，而非静默覆盖对端"
        );

        // 3. 当前令牌 → 写入成功，且前置条件原样透传
        let fresh = adapter
            .upload_conditional(
                "manifest.orsync",
                b"mine",
                UploadPrecondition::Match("etag-7".to_string()),
            )
            .await
            .unwrap();
        assert_eq!(fresh, UploadOutcome::Ok);
        let absent = adapter
            .upload_conditional("brand-new.orsync", b"x", UploadPrecondition::Absent)
            .await
            .unwrap();
        assert_eq!(
            absent,
            UploadOutcome::Ok,
            "Absent 且远端无对象 → 首次写入成功"
        );
        assert_eq!(
            seen_pre.lock().unwrap().as_slice(),
            ["match:etag-stale", "match:etag-7", "absent",],
            "前置条件不得被降级成无条件上传"
        );
        assert_eq!(
            seen.lock().unwrap().as_slice(),
            [
                joined,
                joined,
                "wait-sync/user1/manifest.orsync",
                "wait-sync/user1/brand-new.orsync"
            ],
            "每一次条件写都要带 base_path 前缀"
        );

        // 4. exists 走内层 HEAD 探测，不退化成下载整对象
        assert!(adapter.exists("manifest.orsync").await.unwrap());
        assert!(!adapter.exists("nope.orsync").await.unwrap());
        assert_eq!(
            exists_hits.lock().unwrap().len(),
            2,
            "必须命中内层 HEAD 实现"
        );
    }

    /// F40 回归防线：一轮同步的 raw 适配器与 base_path 包装器必须共享同一底层实例
    ///
    /// 此前两个入口各调一次 `create_adapter` → 两个独立 `reqwest::Client`
    /// （各自连接池），push/pull/DataKey 三个阶段互不复用热连接。断言打在
    /// 指针相等上——任何「顺手再构造一个」的改动都会让它翻红。
    #[test]
    fn adapters_share_single_underlying_instance() {
        let config = SyncConfig {
            adapter_type: "webdav".into(),
            endpoint: "http://127.0.0.1:1/dav".into(),
            bucket: String::new(),
            region: String::new(),
            access_key: "user".into(),
            secret_key: "pass".into(),
            base_path: "orbit/dev".into(),
            device_id: "dev-1".into(),
            device_name: "dev-1".into(),
            timeout_secs: 5,
            skip_tls_verify: false,
            session_token: String::new(),
        };
        let (raw, wrapped) = create_adapters(&config).unwrap();
        assert!(
            Arc::ptr_eq(&raw, &wrapped.inner),
            "raw 适配器与包装器必须指向同一实例（一 run 一 Client）"
        );
    }
}
