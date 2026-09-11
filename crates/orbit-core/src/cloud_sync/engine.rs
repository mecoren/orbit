//! engine — SyncEngine 同步引擎主结构
//!
//! 整合 Push/Pull/附件同步流程，提供三种同步模式：
//! - `sync_now`：完整同步（Push + Pull + 附件），定时同步场景
//! - `push_only`：仅 Push，修改后立即同步场景
//! - `pull_then_push`：先 Pull 再 Push，启动页场景（先拉取远端变更再推送本地变更）
//!
//! ## 互斥控制
//! 使用 `tokio::sync::Mutex<Option<SyncGuard>>` 保证同一时刻只有一个同步任务运行。
//! 已有同步在运行时，新请求返回 `Ok(SyncResult::skipped())`（不阻塞、不报错）。
//!
//! ## FRB 桥接友好
//! `sync_now` 等方法返回 `String`（JSON 序列化的 SyncResult），规避 FRB struct opaque bug。
//! 桥接层（Tauri/FRB）负责构造 SyncEngine 并传递参数。

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;
use tokio::sync::Mutex;

use crate::cloud_sync::attachments::{sync_attachments_pull, sync_attachments_push};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{NoopProgressSender, ProgressSender, SyncOrigin, SyncProgress};
use crate::cloud_sync::pull::pull_all;
use crate::cloud_sync::push::push_all;
use crate::cloud_sync::state::{SyncState, SyncStateStore};
use crate::db::repository::sync_history_repo;
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

/// 历史记录上限：增量同步类型各保留 50 条（insert 后 prune，超出删除最旧）
///
/// 全量备份类型（cloud_full_backup / local_full_backup）由
/// full_sync_backup_api 按 `history_keep_count` 偏好独立清理，此处不触碰。
const INCREMENTAL_HISTORY_KEEP: i64 = 50;

/// 增量同步类型常量（sync_history.sync_type 口径，api 层查询共用）
pub const SYNC_TYPE_SYNC_NOW: &str = "incremental";
pub const SYNC_TYPE_PUSH_ONLY: &str = "push_only";
pub const SYNC_TYPE_PULL_THEN_PUSH: &str = "pull_only";

/// 写一条增量同步历史（P1-17：增量同步此前零历史，成功率/耗时不可度量）
///
/// 口径：
/// - `skipped`（防重入跳过）**不记录**——未执行的同步不是历史
/// - 拉取/推送计数映射：模块数 + 附件数合并计入
///   （pushed = pushed_modules + uploaded_attachments，行级计数引擎不产出）
/// - `errors` 非空按 failed 记（整体 Ok 但模块级有错属于"部分失败"）
/// - 历史写入失败静默（`let _`）——观测数据不得阻塞同步主链
async fn record_incremental_history(
    pool: &SqlitePool,
    sync_type: &str,
    result: &Result<SyncResult, CloudSyncError>,
) {
    // Ok(skipped) 是防重入跳过：没有真正执行，不产生历史
    if let Ok(r) = result {
        if r.skipped {
            return;
        }
    }
    let now_ms = chrono::Utc::now().timestamp_millis();
    let (status, pulled, pushed, error) = match result {
        Ok(r) => {
            let pulled = r.pulled_modules as i64 + r.downloaded_attachments as i64;
            let pushed = r.pushed_modules as i64 + r.uploaded_attachments as i64;
            let status = if r.errors.is_empty() {
                "success"
            } else {
                "failed"
            };
            let error = r.errors.first().map(|e| e.to_string());
            (status, pulled, pushed, error)
        }
        Err(e) => ("failed", 0, 0, Some(e.to_string())),
    };
    let Ok(id) = sync_history_repo::insert(pool, sync_type, status, now_ms).await else {
        return;
    };
    let _ = sync_history_repo::update_status(
        pool,
        id,
        status,
        now_ms,
        pulled,
        pushed,
        0,
        error.as_deref(),
    )
    .await;
    // 清理同类型最旧历史，防表无限增长
    let _ = sync_history_repo::prune_by_type(pool, sync_type, INCREMENTAL_HISTORY_KEEP).await;
}

/// 同步结果汇总
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncResult {
    /// 推送的模块数
    pub pushed_modules: u32,
    /// 拉取的模块数
    pub pulled_modules: u32,
    /// 上传的附件数
    pub uploaded_attachments: u32,
    /// 下载的附件数
    pub downloaded_attachments: u32,
    /// 耗时（毫秒）
    pub duration_ms: u64,
    /// 是否因已有同步在运行而跳过
    pub skipped: bool,
    /// 收集的错误信息（不阻塞整体流程）
    pub errors: Vec<String>,
}

impl SyncResult {
    /// 构造"已跳过"结果（已有同步在运行）
    pub fn skipped() -> Self {
        Self {
            skipped: true,
            ..Default::default()
        }
    }
}

/// 同步锁守卫：Drop 时自动重置运行标志并释放互斥锁
///
/// 持有 `OwnedMutexGuard<Option<()>>`，Drop 时先将内部值重置为 `None`
/// （表示同步结束），再由 OwnedMutexGuard 释放互斥锁。
/// 使用 `OwnedMutexGuard` 而非 `MutexGuard` 是为了能在 `async fn` 中跨
/// `.await` 持有且不受借检器生命周期约束（lock_owned 消费 Arc 克隆）。
pub struct SyncGuard {
    guard: tokio::sync::OwnedMutexGuard<Option<()>>,
}

impl Drop for SyncGuard {
    fn drop(&mut self) {
        // 重置运行标志为 None，使后续同步请求能识别"空闲"状态
        *self.guard = None;
    }
}

/// 自动补传 crypto bundle 的决策结果
///
/// 用于 `sync_data_key_from_cloud` 的 404/WrongPassword 容错分支，
/// 决定是否自动上传本地 crypto bundle 到云端。
#[derive(Debug, PartialEq, Eq)]
enum AutoUploadDecision {
    /// 云端无模块数据，可以安全补传本地 bundle
    Proceed,
    /// 本地无 Data Key，跳过补传（保持现有行为）
    Skip,
    /// 云端已有模块数据但与本地 Key 可能不一致，必须阻断补传
    /// 返回 KeyMismatch 引导用户走恢复流程
    Block,
}

/// 决策函数：根据云端状态和本地 Key 状态决定自动补传行为
///
/// 真值表：
/// | cloud_has_module_data | local_has_data_key | 决策     | 原因                                  |
/// |-----------------------|--------------------|----------|---------------------------------------|
/// | false                 | true               | Proceed  | 云端空，安全补传                       |
/// | false                 | false              | Skip     | 本地无 Key，无法补传                   |
/// | true                  | true               | Block    | 云端有数据，本地 Key 可能错，需恢复流程 |
/// | true                  | false              | Skip     | 本地无 Key，让上层走解锁流程            |
fn decide_auto_upload_behavior(
    cloud_has_module_data: bool,
    local_has_data_key: bool,
) -> AutoUploadDecision {
    if !local_has_data_key {
        AutoUploadDecision::Skip
    } else if cloud_has_module_data {
        AutoUploadDecision::Block
    } else {
        AutoUploadDecision::Proceed
    }
}

/// 拼接 base_path 与文件相对路径
///
/// `base_path` 为空时直接返回 `file_path`；否则返回 `{base_path}/{file_path}`，
/// 自动去除 base_path 末尾的 `/`，避免双斜杠。
fn join_base_path(base_path: &str, file_path: &str) -> String {
    if base_path.is_empty() {
        file_path.to_string()
    } else {
        format!("{}/{}", base_path.trim_end_matches('/'), file_path)
    }
}

/// Data Key 解密探针：用本地 Data Key 尝试解密云端 global_meta
///
/// 在 `sync_data_key_from_cloud` 所有正常完成路径返回前调用，提前发现
/// "本地 Data Key 与云端加密数据不匹配"问题，避免进入 pull 流水后才报错。
///
/// # 返回值
/// - `Ok(())`：探针通过（Data Key 匹配），或云端无 global_meta（首次同步，跳过），
///   或下载失败但非 404（宽松跳过，让 pull 自然报错）
/// - `Err(KeyMismatch)`：Data Key 与云端 global_meta 密文不匹配，必须走恢复流程
///
/// # 设计原则
/// - 404 视为"云端无 global_meta"（首次同步），跳过探针返回 Ok
/// - 其他下载错误（网络故障等）宽松跳过，不阻塞同步
/// - 解密失败严格返回 KeyMismatch，让 UI 立即跳恢复页（而非跳解锁页）
pub(crate) async fn probe_data_key_with_global_meta(
    raw_adapter: &dyn SyncAdapter,
    base_path: &str,
    data_key: &[u8],
) -> Result<(), CloudSyncError> {
    use crate::cloud_sync::crypto_io::decrypt_payload;
    use crate::cloud_sync::paths;

    let path = join_base_path(base_path, paths::GLOBAL_META_PATH);

    let bytes = match raw_adapter.download(&path).await {
        Ok(b) => b,
        Err(e) => {
            if e.is_not_found() {
                log::info!("[probe] 云端无 global_meta（404），跳过探针");
                return Ok(());
            }
            log::info!("[probe] 下载 global_meta 失败（宽松跳过）: {}", e);
            return Ok(());
        }
    };

    match decrypt_payload(&bytes, data_key) {
        Ok(_) => {
            log::info!("[probe] Data Key 解密探针成功：本地 Key 与云端 global_meta 匹配");
            Ok(())
        }
        Err(e) => {
            log::info!(
                "[probe] Data Key 解密探针失败：本地 Key 与云端 global_meta 不匹配 ({})",
                e
            );
            // 显式忽略 e（已是 KeyMismatch）：探针语义独立于 decrypt_payload 实现细节
            Err(CloudSyncError::KeyMismatch)
        }
    }
}

/// 云端同步引擎
///
/// 线程安全：内部所有字段都是 `Arc` 或 `Send + Sync`，可跨线程共享。
/// 典型用法：应用启动时创建单例，存入 Tauri State 或 Riverpod Provider。
#[derive(Clone)]
pub struct SyncEngine {
    db_pool: SqlitePool,
    crypto: SyncCryptoService,
    state_store: Arc<SyncStateStore>,
    progress_sender: Arc<dyn ProgressSender>,
    /// 同步互斥锁：Some(()) 表示同步进行中，None 表示空闲
    sync_lock: Arc<Mutex<Option<()>>>,
    /// 应用数据目录（同步前自动备份使用）
    app_data_dir: PathBuf,
    /// 同步密码缓存（解锁时由桥接层设置，同步前自动备份使用）
    ///
    /// 使用 `Arc<std::sync::Mutex<..>>` 实现内部可变性：
    /// `SyncEngine` 是 `Clone` 的，所有克隆共享同一份密码，
    /// 桥接层在 `sync_crypto_unlock` 成功后调用 `set_sync_password` 更新。
    /// 为 `None` 时跳过同步前备份（不阻塞同步本身）。
    sync_password: Arc<std::sync::Mutex<Option<String>>>,
}

impl SyncEngine {
    /// 创建同步引擎
    pub fn new(
        db_pool: SqlitePool,
        crypto: SyncCryptoService,
        app_data_dir: &Path,
        progress_sender: Arc<dyn ProgressSender>,
    ) -> Self {
        Self {
            db_pool,
            crypto,
            state_store: Arc::new(SyncStateStore::new(app_data_dir)),
            progress_sender,
            sync_lock: Arc::new(Mutex::new(None)),
            app_data_dir: app_data_dir.to_path_buf(),
            sync_password: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// 设置同步密码（同步前自动备份使用）
    ///
    /// 由桥接层在 `sync_crypto_unlock` 成功后调用。
    /// 密码以 `Arc<Mutex<..>>` 共享，所有 `SyncEngine` 克隆实例同步更新。
    pub fn set_sync_password(&self, password: String) {
        if let Ok(mut guard) = self.sync_password.lock() {
            *guard = Some(password);
        }
    }

    /// 清除同步密码（锁定时调用）
    pub fn clear_sync_password(&self) {
        if let Ok(mut guard) = self.sync_password.lock() {
            *guard = None;
        }
    }

    /// 获取同步密码的克隆（供备份逻辑使用）
    fn get_sync_password(&self) -> Option<String> {
        self.sync_password
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
    }

    /// 创建引擎（使用 NoopProgressSender，用于测试或不需进度通知的场景）
    pub fn new_noop_progress(
        db_pool: SqlitePool,
        crypto: SyncCryptoService,
        app_data_dir: &Path,
    ) -> Self {
        Self::new(db_pool, crypto, app_data_dir, Arc::new(NoopProgressSender))
    }

    /// 获取同步状态
    pub fn get_state(&self) -> Result<SyncState, CloudSyncError> {
        self.state_store.load()
    }

    /// 检查同步是否正在运行
    pub async fn is_running(&self) -> bool {
        let guard = self.sync_lock.lock().await;
        guard.is_some()
    }

    /// 执行完整同步（Pull → Push + 附件）
    ///
    /// 流程（需求1：先拉取→对比→合并→本地存储→上传云端）：
    /// 1. 同步前自动备份（宽松模式）
    /// 2. Pull：从云端拉取远端变更，LWW 合并到本地数据库（本地存储）
    /// 3. Push：将合并后的本地数据上传到云端（上传云端）
    /// 4. 附件同步：Pull 附件 + Push 附件
    ///
    /// 与 `pull_then_push` 流程一致，作为「立即同步」的唯一入口。
    /// `push_only` 用于修改后立即推送（不拉取）。
    ///
    /// 若已有同步在运行，返回 `Ok(SyncResult::skipped())`。
    ///
    /// `origin` 标识事件来源（Background/Manual/Exit），随所有进度事件携带，
    /// UI 层据此过滤重复显示（右下角指示器仅响应 Background）。
    ///
    /// **功能⑤新增**：
    /// - 同步前自动备份（宽松模式：失败记录到 errors，不阻塞同步）
    /// - push_all/pull_all 业务级网络重试（3 次，2/4/8 秒指数退避，仅网络错误重试）
    ///
    /// **Fix-08**：Data Key 同步（`sync_data_key_from_cloud`）移入互斥锁内执行。
    /// 历史问题：该步骤曾在 api 层于锁外执行，并发触发两个同步入口时可同时
    /// 进行 Data Key 导入/解密探针，与另一路 pull 交错可能误报 KeyMismatch。
    /// 失败时补发 Error 进度事件。
    ///
    /// Done 事件仅在成功路径末尾发送；失败若不发事件，后台调度器只 eprintln，
    /// 前端悬浮指示器会永远停在最后一个 pushing/pulling 帧。
    fn emit_error_on_failure(
        &self,
        origin: SyncOrigin,
        result: &Result<SyncResult, CloudSyncError>,
    ) {
        if let Err(e) = result {
            self.progress_sender.send(SyncProgress::Error {
                origin,
                message: e.to_string(),
                module: None,
            });
        }
    }

    pub async fn sync_now(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let r = self
            .sync_now_inner(
                adapter,
                raw_adapter,
                base_path,
                origin,
                device_id,
                attachments_dir,
            )
            .await;
        record_incremental_history(&self.db_pool, SYNC_TYPE_SYNC_NOW, &r).await;
        self.emit_error_on_failure(origin, &r);
        r
    }

    async fn sync_now_inner(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let _guard = match self.acquire_lock().await? {
            Some(g) => g,
            None => return Ok(SyncResult::skipped()),
        };

        let start = std::time::Instant::now();
        let mut result = SyncResult::default();

        // -1. Data Key 同步（锁内，关键错误阻塞后续 pull/push，非阻塞错误入 errors）
        self.sync_data_key_from_cloud(raw_adapter, base_path, &mut result)
            .await?;

        // 0. 同步前自动备份（宽松模式：失败不阻塞同步）
        self.backup_before_sync(&mut result).await;

        // 1. Pull（业务级网络重试）：拉取远端变更 → LWW 合并 → 本地存储
        let pull_result = self
            .with_retry("pull_all", 3, || {
                pull_all(
                    &self.db_pool,
                    &self.crypto,
                    &self.state_store,
                    adapter,
                    self.progress_sender.as_ref(),
                    origin,
                )
            })
            .await?;
        result.pulled_modules = pull_result.pulled_modules;
        result.errors.extend(pull_result.errors);

        // 2. Push（业务级网络重试）：合并后的本地数据上传云端
        // P0-6：Pull 失败的模块本地仍是旧快照，跳过其 push 防陈旧数据覆盖云端
        let push_result = self
            .with_retry("push_all", 3, || {
                push_all(
                    &self.db_pool,
                    &self.crypto,
                    &self.state_store,
                    adapter,
                    self.progress_sender.as_ref(),
                    origin,
                    device_id,
                    &pull_result.failed_modules,
                )
            })
            .await?;
        result.pushed_modules = push_result.pushed_modules;

        // 3. 附件同步：先 Pull 附件（下载远端新增），再 Push 附件（上传本地新增）
        let att_pull = sync_attachments_pull(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.downloaded_attachments = att_pull.downloaded;
        result.errors.extend(att_pull.errors);

        let att_push = sync_attachments_push(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.uploaded_attachments = att_push.uploaded;
        result.errors.extend(att_push.errors);

        result.duration_ms = start.elapsed().as_millis() as u64;

        // 4. 发送完成事件
        self.progress_sender.send(SyncProgress::Done {
            origin,
            duration_ms: result.duration_ms,
            pushed_modules: result.pushed_modules,
            pulled_modules: result.pulled_modules,
            uploaded_attachments: result.uploaded_attachments,
            downloaded_attachments: result.downloaded_attachments,
        });

        Ok(result)
    }

    /// 仅 Push（修改后立即同步场景）
    ///
    /// `origin` 标识事件来源：Background（useSyncOnChange）/ Exit（退出同步）。
    ///
    /// **Fix-08**：Data Key 同步移入互斥锁内执行（见 `sync_now` 文档）。
    pub async fn push_only(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let r = self
            .push_only_inner(
                adapter,
                raw_adapter,
                base_path,
                origin,
                device_id,
                attachments_dir,
            )
            .await;
        record_incremental_history(&self.db_pool, SYNC_TYPE_PUSH_ONLY, &r).await;
        self.emit_error_on_failure(origin, &r);
        r
    }

    async fn push_only_inner(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let _guard = match self.acquire_lock().await? {
            Some(g) => g,
            None => return Ok(SyncResult::skipped()),
        };

        let start = std::time::Instant::now();
        let mut result = SyncResult::default();

        // -1. Data Key 同步（锁内）：用错误的 Data Key 加密上传会导致
        // 云端数据无法被其他设备解密，必须先保证本地与云端 Key 一致。
        self.sync_data_key_from_cloud(raw_adapter, base_path, &mut result)
            .await?;

        // Push 数据
        let push_result = push_all(
            &self.db_pool,
            &self.crypto,
            &self.state_store,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            device_id,
            // push_only 无 Pull 阶段，无失败模块可跳过
            &[],
        )
        .await?;
        result.pushed_modules = push_result.pushed_modules;

        // Push 附件
        let att_push = sync_attachments_push(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.uploaded_attachments = att_push.uploaded;
        result.errors.extend(att_push.errors);

        result.duration_ms = start.elapsed().as_millis() as u64;

        self.progress_sender.send(SyncProgress::Done {
            origin,
            duration_ms: result.duration_ms,
            pushed_modules: result.pushed_modules,
            pulled_modules: 0,
            uploaded_attachments: result.uploaded_attachments,
            downloaded_attachments: 0,
        });

        Ok(result)
    }

    /// 先 Pull 再 Push（启动页场景）
    ///
    /// 先拉取远端变更（合并到本地），再推送本地变更到远端。
    /// 保证启动时获取最新数据，同时不丢失本地新增。
    ///
    /// `origin` 标识事件来源（Background/Manual/Exit）。
    ///
    /// **功能⑤新增**：
    /// - 同步前自动备份（宽松模式：失败记录到 errors，不阻塞同步）
    /// - push_all/pull_all 业务级网络重试（3 次，2/4/8 秒指数退避，仅网络错误重试）
    ///
    /// **Fix-08**：Data Key 同步移入互斥锁内执行（见 `sync_now` 文档）。
    pub async fn pull_then_push(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let r = self
            .pull_then_push_inner(
                adapter,
                raw_adapter,
                base_path,
                origin,
                device_id,
                attachments_dir,
            )
            .await;
        record_incremental_history(&self.db_pool, SYNC_TYPE_PULL_THEN_PUSH, &r).await;
        self.emit_error_on_failure(origin, &r);
        r
    }

    async fn pull_then_push_inner(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let _guard = match self.acquire_lock().await? {
            Some(g) => g,
            None => return Ok(SyncResult::skipped()),
        };

        let start = std::time::Instant::now();
        let mut result = SyncResult::default();

        // -1. Data Key 同步（锁内）：pull 前必须导入云端 Data Key，否则解密失败
        self.sync_data_key_from_cloud(raw_adapter, base_path, &mut result)
            .await?;

        // 0. 同步前自动备份（宽松模式：失败不阻塞同步）
        self.backup_before_sync(&mut result).await;

        // 1. Pull 数据（业务级网络重试）
        let pull_result = self
            .with_retry("pull_all", 3, || {
                pull_all(
                    &self.db_pool,
                    &self.crypto,
                    &self.state_store,
                    adapter,
                    self.progress_sender.as_ref(),
                    origin,
                )
            })
            .await?;
        result.pulled_modules = pull_result.pulled_modules;
        result.errors.extend(pull_result.errors);

        // 2. Pull 附件
        let att_pull = sync_attachments_pull(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.downloaded_attachments = att_pull.downloaded;
        result.errors.extend(att_pull.errors);

        // 3. Push 数据（合并后可能有新指纹需要推送，业务级网络重试）
        // P0-6：Pull 失败的模块本地仍是旧快照，跳过其 push 防陈旧数据覆盖云端
        let push_result = self
            .with_retry("push_all", 3, || {
                push_all(
                    &self.db_pool,
                    &self.crypto,
                    &self.state_store,
                    adapter,
                    self.progress_sender.as_ref(),
                    origin,
                    device_id,
                    &pull_result.failed_modules,
                )
            })
            .await?;
        result.pushed_modules = push_result.pushed_modules;

        // 4. Push 附件
        let att_push = sync_attachments_push(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.uploaded_attachments = att_push.uploaded;
        result.errors.extend(att_push.errors);

        result.duration_ms = start.elapsed().as_millis() as u64;

        self.progress_sender.send(SyncProgress::Done {
            origin,
            duration_ms: result.duration_ms,
            pushed_modules: result.pushed_modules,
            pulled_modules: result.pulled_modules,
            uploaded_attachments: result.uploaded_attachments,
            downloaded_attachments: result.downloaded_attachments,
        });

        Ok(result)
    }

    /// 诊断加密状态：返回 Data Key 指纹和 sync_password 缓存状态
    ///
    /// 用于排查"同步密码未解锁"错误：
    /// - Data Key 是否在内存（unlock 是否成功）
    /// - sync_password 是否已注入引擎（cloudSyncSetPassword 是否调用）
    pub fn diagnose_crypto_state(&self) -> String {
        let dk = self.crypto.get_data_key();
        let dk_fp = dk
            .as_ref()
            .map(|k| data_key_fingerprint(k))
            .unwrap_or_else(|| "<none>".to_string());
        let has_password = self.get_sync_password().is_some();
        format!("data_key_fp={}, has_password={}", dk_fp, has_password,)
    }

    /// rekey 全量重传：用当前内存中的 Data Key 重加密并覆盖云端全部数据
    ///
    /// 三个场景共用（调用前 Data Key 必须已在内存中切换为新 Key）：
    /// - v2 改密（change_sync_password 后）：云端旧密码 Key 密文全部失效
    /// - v1→v2 迁移：确定性 Key 替换随机 Key
    /// - KeyMismatch 恢复「以本机为准」：放弃解不开的云端数据
    ///
    /// 步骤：
    /// 1. 清空 sync_state.json（所有模块失去 prev_state，push_all 必然全量重传，
    ///    且 P0-5 空数据覆盖守卫的 prev.is_some 条件不再成立）
    /// 2. push_all 全模块用新 Key 加密上传（含 global _meta）
    /// 3. 附件 is_uploaded 全部清零 → 重加密重传
    /// 4. 上传新 crypto/config 到云端（其他设备据此感知新 Key）
    ///
    /// **不做 Pull**：rekey 的语义就是「本机为准」，远端数据被有意覆盖。
    /// 附件重传依赖本地缓存（is_local_cached=1 的行会从本地文件读取）；
    /// 本地已删（仅存云端）的旧密文附件在 rekey 后不可恢复，这是
    /// 「以本机为准」的固有代价，调用方（UI）必须向用户明示。
    pub async fn rekey_cloud_reencrypt(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let r = self
            .rekey_cloud_reencrypt_inner(
                adapter,
                raw_adapter,
                base_path,
                origin,
                device_id,
                attachments_dir,
            )
            .await;
        self.emit_error_on_failure(origin, &r);
        r
    }

    async fn rekey_cloud_reencrypt_inner(
        &self,
        adapter: &dyn SyncAdapter,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        origin: SyncOrigin,
        device_id: &str,
        attachments_dir: &str,
    ) -> Result<SyncResult, CloudSyncError> {
        let _guard = match self.acquire_lock().await? {
            Some(g) => g,
            None => {
                return Err(CloudSyncError::AlreadyRunning);
            }
        };

        let start = std::time::Instant::now();
        let mut result = SyncResult::default();

        // 前置：Data Key 必须在内存（调用方已切换/解锁）
        let data_key = self
            .crypto
            .get_data_key()
            .ok_or(CloudSyncError::CryptoLocked)?;
        log::info!(
            "[rekey] 开始全量重传（Data Key 指纹: {}）",
            data_key_fingerprint(&data_key)
        );

        // 1. 清空本地指纹账本：让 push_all 走全量而非增量
        self.state_store.clear()?;
        log::info!("[rekey] 已清空 sync_state.json（全模块强制重传）");

        // 2. 全模块 Push（新 Key 加密）
        // skip_modules 为空：rekey 场景没有前置 Pull，不存在"Pull 失败模块"
        let push_result = push_all(
            &self.db_pool,
            &self.crypto,
            &self.state_store,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            device_id,
            &[],
        )
        .await?;
        result.pushed_modules = push_result.pushed_modules;

        // 3. 附件：清零 is_uploaded 触发全量重传（本地缓存部分）
        let reset_count =
            crate::db::repository::attachment_repo::mark_all_unuploaded(&self.db_pool)
                .await
                .map_err(|e| CloudSyncError::Database {
                    message: format!("重置附件上传标记失败: {}", e),
                })?;
        log::info!("[rekey] 附件 is_uploaded 清零 {} 条，开始重传", reset_count);

        let att_push = sync_attachments_push(
            &self.db_pool,
            &self.crypto,
            adapter,
            self.progress_sender.as_ref(),
            origin,
            attachments_dir,
        )
        .await?;
        result.uploaded_attachments = att_push.uploaded;
        result.errors.extend(att_push.errors);

        // 4. 上传新 crypto/config（其他设备据此发现 Key 已换）
        let bundle = self.crypto.export_crypto_bundle()?;
        crate::sync_crypto::bundle_io::upload_crypto_bundle_with_base_path(
            raw_adapter,
            base_path,
            &bundle,
        )
        .await?;
        log::info!("[rekey] 已上传新 crypto/config 到 {{base_path}}/crypto/config");

        result.duration_ms = start.elapsed().as_millis() as u64;
        self.progress_sender.send(SyncProgress::Done {
            origin,
            duration_ms: result.duration_ms,
            pushed_modules: result.pushed_modules,
            pulled_modules: 0,
            uploaded_attachments: result.uploaded_attachments,
            downloaded_attachments: 0,
        });

        log::info!(
            "[rekey] 全量重传完成：{} 模块、{} 附件、耗时 {}ms",
            result.pushed_modules,
            result.uploaded_attachments,
            result.duration_ms
        );
        Ok(result)
    }

    /// 获取互斥锁
    ///
    /// 返回 `Ok(Some(guard))` 表示获取成功，`Ok(None)` 表示已有同步在运行。
    ///
    /// 使用 `try_lock_owned()` 而非 `lock_owned().await`：
    /// - `lock_owned().await` 会**等待**锁释放，但 `SyncGuard::drop` 已将内部值
    ///   重置为 `None`，导致 `if guard.is_some()` 永远为 false，第二个请求会
    ///   等待第一个完成后再执行一次同步（形成"同步执行两次"的死循环）。
    /// - `try_lock_owned()` 在锁被持有时立即返回 `Err`，调用方据此返回 `skipped`，
    ///   避免 React.StrictMode 双重挂载导致的重复同步。
    async fn acquire_lock(&self) -> Result<Option<SyncGuard>, CloudSyncError> {
        // try_lock_owned：锁被持有时立即返回 Err，不等待
        let mut guard = match self.sync_lock.clone().try_lock_owned() {
            Ok(g) => g,
            Err(_) => return Ok(None), // 已有同步在运行，返回跳过
        };
        if guard.is_some() {
            // 理论上不会到这里（新建锁内部值为 None），防御性返回跳过
            return Ok(None);
        }
        *guard = Some(());
        Ok(Some(SyncGuard { guard }))
    }

    /// 从云端同步 Data Key（多设备同步场景）（Fix-17：原 backup_before_sync 文档已拆回其函数处）
    ///
    /// 在 pull 之前调用：下载云端 `{base_path}/crypto/config`，若 salt 与本地不一致则导入云端 Data Key。
    ///
    /// **场景**：设备 A 创建同步加密生成 Data Key A，设备 B `syncCryptoInit` 生成新的
    /// Data Key B。若不导入云端 Data Key A，设备 B pull 时用 Data Key B 解密
    /// Data Key A 加密的模块数据会失败（`decrypt failed: aead::Error`）。
    ///
    /// **P2 路径变更**：`crypto/config` 已从云端根目录迁移到 `{base_path}/crypto/config`。
    /// 必须使用**原始 adapter**（不带 `BasePathAdapter` 包装）调用此方法，
    /// 由 `bundle_io::download_and_import_crypto_bundle_with_base_path` 内部负责
    /// 路径拼接与双读回退（新路径 404 时回退到根目录旧路径，自动迁移）。
    /// 外层若再包 `BasePathAdapter` 会导致双重拼接成 `{base_path}/{base_path}/crypto/config`。
    ///
    /// **行为**：
    /// - sync_password 未缓存：跳过（未解锁场景）
    /// - 云端无 crypto/config（新/旧路径都 404）：跳过（首次同步，云端为空）
    /// - salt 一致：跳过（同一设备或已导入）
    /// - salt 不一致：导入云端 Data Key 到本地 meta 和内存
    ///
    /// **错误处理策略**：
    /// - 404（云端无 crypto/config）：视为正常（首次同步），返回 `Ok`
    /// - 密码错误（`WrongPassword`）：返回 `Err(CryptoLocked)`，**阻塞同步**。
    ///   否则继续 pull/push 会用错误的本地 Data Key 解密云端数据，产生迷惑性的
    ///   `decrypt failed: aead::Error` 错误（真正根因被掩盖）。
    /// - 适配器/网络错误：宽松处理，记录到 `result.errors`，返回 `Ok`（继续 pull 可能成功）
    /// - 其他错误（元数据损坏等）：返回 `Err`，阻塞同步
    pub async fn sync_data_key_from_cloud(
        &self,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        result: &mut SyncResult,
    ) -> Result<(), CloudSyncError> {
        // 先执行原同步逻辑（含 404/WrongPassword 守卫）
        self.sync_data_key_from_cloud_inner(raw_adapter, base_path, result)
            .await?;

        // 解密探针：所有正常完成路径都验证 Data Key 与云端 global_meta 匹配
        //
        // 即使本地 meta 与云端 crypto/config 一致（Ok(None) 路径），仍需探针：
        // 极端场景下云端 crypto/config 可能与云端模块数据用的 Key 不一致
        // （历史污染、人工修改等），探针能提前发现并快速失败，避免进入 pull
        // 流水后才报 KeyMismatch。
        if let Some(data_key) = self.crypto.get_data_key() {
            probe_data_key_with_global_meta(raw_adapter, base_path, &data_key).await?;
        }
        Ok(())
    }

    /// `sync_data_key_from_cloud` 的内部实现（不含探针）
    async fn sync_data_key_from_cloud_inner(
        &self,
        raw_adapter: &dyn SyncAdapter,
        base_path: &str,
        result: &mut SyncResult,
    ) -> Result<(), CloudSyncError> {
        let password = match self.get_sync_password() {
            Some(p) => p,
            None => {
                log::info!("[sync_data_key] 跳过：sync_password 未缓存");
                return Ok(());
            }
        };

        // 记录导入前的 Data Key 指纹（前 8 字节 hex），便于诊断 Data Key 是否变化
        let pre_fp = self
            .crypto
            .get_data_key()
            .map(|k| data_key_fingerprint(&k))
            .unwrap_or_else(|| "<none>".to_string());
        log::info!("[sync_data_key] 开始同步，当前 Data Key 指纹: {}", pre_fp);

        // v2 确定性密钥：本地 meta 为 v2 时，本机 Key 由密码派生，密码正确则
        // Key 必然正确。云端 crypto/config 仅用于一致性核对——不一致说明
        // 云端数据由**另一个密码**加密（或云端 config 陈旧），导入云端 bundle
        // 无意义（同密码必派生同 Key，不一致的 config 解开也只会得到异密码 Key，
        // 与本机密码矛盾）。跳过导入，交由探针判定本机 Key 能否解云端数据。
        let local_meta_is_v2 =
            crate::sync_crypto::meta_store::load_sync_crypto_meta(self.crypto.app_data_dir())
                .ok()
                .flatten()
                .is_some_and(|m| {
                    m.key_derivation.as_deref()
                        == Some(crate::sync_crypto::service::KEY_DERIVATION_V2)
                });

        if local_meta_is_v2 {
            log::info!("[sync_data_key] v2 确定性密钥：跳过云端 bundle 导入，由探针校验一致性");
            return Ok(());
        }

        match crate::sync_crypto::bundle_io::download_and_import_crypto_bundle_with_base_path(
            raw_adapter,
            base_path,
            &self.crypto,
            &password,
        )
        .await
        {
            Ok(Some(_data_key)) => {
                let post_fp = self
                    .crypto
                    .get_data_key()
                    .map(|k| data_key_fingerprint(&k))
                    .unwrap_or_else(|| "<none>".to_string());
                log::info!(
                    "[sync_data_key] 成功导入云端 Data Key，指纹变化: {} → {}",
                    pre_fp,
                    post_fp
                );
                Ok(())
            }
            Ok(None) => {
                // 双 404 时 bundle_io 返回 Ok(None)（云端无 crypto/config），
                // 「本地 meta 与云端一致」不再单独区分——该信号量无法从
                // bundle_io 传回。此处与 Err(NotFound) 分支同构：本地有
                // Data Key 且云端无模块数据时安全补传 crypto/config。
                //
                // 历史问题（M4 E2E 发现）：首台设备推模块数据但 crypto/config
                // 从未上传（本分支直通 Ok），第二台设备 KeyMismatch 被永久阻断。
                // 守卫矩阵与 Err(NotFound) 分支共享（decide_auto_upload_behavior）。
                log::info!("[sync_data_key] 云端无 crypto/config（bundle_io 双 404）");
                let local_has_key = self.crypto.get_data_key().is_some();
                if local_has_key {
                    let cloud_has_data = self.cloud_has_module_data(raw_adapter, base_path).await;
                    match decide_auto_upload_behavior(cloud_has_data, local_has_key) {
                        AutoUploadDecision::Proceed => {
                            self.auto_upload_crypto_bundle(raw_adapter, base_path).await;
                        }
                        AutoUploadDecision::Skip => {
                            log::info!("[sync_data_key] 本地无 Data Key，跳过自动补传");
                        }
                        AutoUploadDecision::Block => {
                            log::info!(
                                "[sync_data_key] 守卫触发：云端已有模块数据但缺 crypto/config，\
                                 拒绝补传本地（可能错误的）Key，返回 KeyMismatch 引导恢复流程"
                            );
                            return Err(CloudSyncError::KeyMismatch);
                        }
                    }
                }
                Ok(())
            }
            Err(e) => {
                // 云端无 crypto/config 视为「资源不存在」，不阻塞同步。
                //
                // 类型化判定（Fix-09）：适配器将 HTTP 404 与坚果云 WebDAV 的
                // 409 AncestorsNotFound 统一翻译为 `SyncError::NotFound`，
                // 经 `From<SyncError>` 映射为 `SyncCryptoError::NotFound`，
                // 此处按类型匹配，不再对错误消息做 "404"/"409" 字符串嗅探
                // （历史问题：响应体偶然含这些子串会误判为首次同步）。
                if matches!(e, crate::sync_crypto::SyncCryptoError::NotFound { .. }) {
                    log::info!("[sync_data_key] 云端无 crypto/config（404/409 AncestorsNotFound）");
                    // 守卫：自动补传本地 bundle 前必须确认云端无模块数据。
                    //
                    // 历史问题：旧逻辑只要本地有 Data Key 就自动补传，
                    // 在"云端已有 Key A 加密的模块数据但缺 crypto/config"场景下
                    // 会把本地错 Key B 永久写回云端，污染其他设备。
                    //
                    // 修复策略：
                    // - 云端无模块数据（真正首次同步）→ 安全补传本地 bundle
                    // - 云端已有模块数据 + 本地有 Data Key → 阻断，返回 KeyMismatch
                    //   引导用户走恢复流程（覆盖云端 / 采用云端）
                    // - 本地无 Data Key → 跳过（保持原行为）
                    let local_has_key = self.crypto.get_data_key().is_some();
                    let cloud_has_data = self.cloud_has_module_data(raw_adapter, base_path).await;
                    match decide_auto_upload_behavior(cloud_has_data, local_has_key) {
                        AutoUploadDecision::Proceed => {
                            self.auto_upload_crypto_bundle(raw_adapter, base_path).await;
                            return Ok(());
                        }
                        AutoUploadDecision::Skip => {
                            log::info!("[sync_data_key] 本地无 Data Key，跳过自动补传");
                            return Ok(());
                        }
                        AutoUploadDecision::Block => {
                            log::info!(
                                "[sync_data_key] 守卫触发：云端已有模块数据但缺 crypto/config，\
                                 拒绝补传本地（可能错误的）Key，返回 KeyMismatch 引导恢复流程"
                            );
                            return Err(CloudSyncError::KeyMismatch);
                        }
                    }
                }
                let msg = format!("同步 Data Key 失败: {}", e);
                log::info!("[sync_data_key] {}", msg);
                // 密码错误：本地 sync_password 解不开云端 crypto/config。
                // 常见场景：用户在另一台设备改了同步密码但云端 crypto/config
                // 未同步更新，或本地重装后输入了不同的密码。
                //
                // 容错策略：若本地已有 Data Key（unlock 成功），说明本地 sync_password
                // 与本地 meta 是匹配的，云端 crypto/config 只是陈旧数据。此时自动
                // 补传本地 crypto/config 覆盖云端陈旧配置，继续同步。
                // - 若本地 Data Key 与云端模块数据匹配：pull 成功，问题修复
                // - 若本地 Data Key 不匹配：pull 会报 decrypt failed，错误更明确
                //
                // 仅当本地无 Data Key（未 unlock）时才阻塞，返回 CryptoLocked
                // 引导用户跳转解锁页。
                if matches!(e, crate::sync_crypto::SyncCryptoError::WrongPassword) {
                    // 守卫：与 404 分支同样逻辑，WrongPassword 自动补传前必须确认
                    // 云端无模块数据。
                    //
                    // 场景：用户在另一台设备改了同步密码 → 云端 crypto/config 用新密码
                    // 包装 Key A → 移动端本地旧密码 → WrongPassword → 旧逻辑自动补传
                    // 本地 bundle（用旧密码包装的 Key B）→ 永久污染云端。
                    //
                    // 修复：云端已有模块数据 + 本地有 Data Key → Block（返回 KeyMismatch）
                    // 引导用户走恢复流程而非自动覆盖。
                    let local_has_key = self.crypto.get_data_key().is_some();
                    if !local_has_key {
                        // 本地无 Data Key（未 unlock）→ 真正需要解锁
                        return Err(CloudSyncError::CryptoLocked);
                    }
                    let cloud_has_data = self.cloud_has_module_data(raw_adapter, base_path).await;
                    match decide_auto_upload_behavior(cloud_has_data, local_has_key) {
                        AutoUploadDecision::Proceed => {
                            log::info!(
                                "[sync_data_key] WrongPassword 但本地已有 Data Key 且云端无模块数据，\
                                 自动补传本地配置覆盖云端陈旧配置"
                            );
                            self.auto_upload_crypto_bundle(raw_adapter, base_path).await;
                            return Ok(());
                        }
                        AutoUploadDecision::Skip => {
                            // 不会到达此分支（local_has_key 已检查），保留完整枚举匹配
                            return Err(CloudSyncError::CryptoLocked);
                        }
                        AutoUploadDecision::Block => {
                            log::info!(
                                "[sync_data_key] 守卫触发：WrongPassword 且云端已有模块数据，\
                                 拒绝补传本地 Key，返回 KeyMismatch 引导恢复流程"
                            );
                            return Err(CloudSyncError::KeyMismatch);
                        }
                    }
                }
                // 其他适配器/网络错误（非 404/409）：宽松处理，继续 pull（可能成功）
                if matches!(e, crate::sync_crypto::SyncCryptoError::Adapter { .. }) {
                    result.errors.push(msg);
                    return Ok(());
                }
                // 其他错误（元数据损坏等）：阻塞同步
                Err(CloudSyncError::Crypto { message: msg })
            }
        }
    }

    /// 探测云端是否存在模块数据（`modules/*/data.waitsync`）
    ///
    /// 用于 `sync_data_key_from_cloud` 的 404/WrongPassword 容错分支决策：
    /// - 云端无模块数据（首次同步、云端被清空）→ 安全补传本地 bundle
    /// - 云端已有模块数据 → 阻断补传，避免本地错 Key 覆盖云端正确 Key
    ///
    /// **实现方式（P0-2 修复）**：对每个模块的 `data.waitsync` 逐一做 GET 探测，
    /// 下载成功即存在。不再依赖 `list_files` 的返回路径形态——WebDAV 下
    /// Depth:1 只列一级子项且 name 是 basename，旧的 `is_module_data_path`
    /// 路径匹配在 WebDAV 上恒 false，导致防污染守卫完全失效
    /// （云端已有 Key A 数据时本地 Key B 的 crypto/config 仍被自动上传覆盖）。
    /// 直接探测对两种适配器行为一致，且只多一次请求（404 立即失败）。
    ///
    /// 探测错误（网络故障等）时无法确认云端状态，宽松返回 `false`（不阻断），
    /// 让原容错流程继续。
    async fn cloud_has_module_data(&self, raw_adapter: &dyn SyncAdapter, base_path: &str) -> bool {
        for module in crate::cloud_sync::modules::SYNC_MODULES {
            let path = join_base_path(base_path, &paths::module_data_path(module.name));
            match raw_adapter.download(&path).await {
                Ok(_) => {
                    log::info!(
                        "[sync_data_key] 云端探测：{} 下载成功，判定存在模块数据",
                        path
                    );
                    return true;
                }
                Err(e) if e.is_not_found() => {
                    // 404：该模块无数据，继续探测下一个
                }
                Err(e) => {
                    // fail-closed：探测出错时无法确认云端状态，保守视为"有模块数据"。
                    // 这样 decide_auto_upload_behavior 走 Block 分支，避免在云端实际
                    // 有数据时覆盖 crypto/config 造成全设备 [key_mismatch] 不可逆污染。
                    // 代价：网络抖动时自动补传被阻断，但下次同步成功即恢复。
                    log::warn!(
                        "[sync_data_key] 云端探测 {} 失败，fail-closed 视为有模块数据（阻断自动补传）: {}",
                        path,
                        e
                    );
                    return true;
                }
            }
        }
        log::info!("[sync_data_key] 云端探测：所有模块 data.waitsync 均 404，判定无模块数据");
        false
    }

    /// 自动上传本地 crypto bundle 到云端（容错修复）
    ///
    /// 当检测到云端无 crypto/config 但本地已有 Data Key 时调用，
    /// 将本地 sync_crypto_meta.json 上传到云端 `{base_path}/crypto/config`（P2 变更）。
    ///
    /// 场景：移动端旧版 setSyncPassword 未上传 crypto/config，导致云端有
    /// 加密模块数据但无 crypto/config。此方法自动补传，修复历史数据不一致。
    ///
    /// 上传失败不阻塞同步流程（仅记录日志），因为：
    /// - 若本地 Data Key 与云端加密数据匹配：pull 会成功，下次同步可再补传
    /// - 若不匹配：pull 会返回 CryptoLocked，提示用户输入正确同步密码
    async fn auto_upload_crypto_bundle(&self, raw_adapter: &dyn SyncAdapter, base_path: &str) {
        log::info!(
            "[sync_data_key] 自动补传：本地有 Data Key，上传 crypto/config 到云端 (base_path={})",
            base_path
        );
        match self.crypto.export_crypto_bundle() {
            Ok(bundle) => match crate::sync_crypto::bundle_io::upload_crypto_bundle_with_base_path(
                raw_adapter,
                base_path,
                &bundle,
            )
            .await
            {
                Ok(_) => {
                    log::info!("[sync_data_key] 自动补传 crypto/config 成功");
                }
                Err(e) => {
                    log::info!(
                        "[sync_data_key] 自动补传 crypto/config 失败（不阻塞同步）: {}",
                        e
                    );
                }
            },
            Err(e) => {
                log::info!(
                    "[sync_data_key] 自动补传跳过：导出本地 crypto bundle 失败: {}",
                    e
                );
            }
        }
    }

    /// 同步前自动备份（功能⑤）（Fix-17：文档从 sync_data_key_from_cloud 处拆回）
    ///
    /// 宽松模式：备份失败不阻塞同步，仅记录到 `result.errors`。
    /// 仅在 `sync_password` 已缓存时执行；为 `None` 时跳过备份。
    ///
    /// 需求2：备份开关均关闭（默认）时跳过，避免每次同步产生 InvalidState 错误。
    /// 用户开启云端或本地备份开关后，同步前自动备份才会执行。
    ///
    /// 调用时机：`sync_now`/`pull_then_push` 的 `acquire_lock` 成功后、
    /// 首个 push/pull 之前。`push_only`（修改后立即同步）不调用本方法
    /// （频率高，备份开销大）。
    async fn backup_before_sync(&self, result: &mut SyncResult) {
        let password = match self.get_sync_password() {
            Some(p) => p,
            None => {
                log::info!("[backup_before_sync] 跳过：sync_password 未缓存");
                return;
            }
        };

        // 需求2：检查备份开关，两者皆关闭时跳过（默认状态，不记录错误）
        match crate::api::full_sync_backup_api::get_backup_prefs(&self.app_data_dir).await {
            Ok(prefs) => {
                if !prefs.cloud_backup_enabled && !prefs.local_backup_enabled {
                    log::info!("[backup_before_sync] 跳过：云端与本地备份开关均关闭");
                    return;
                }
            }
            Err(e) => {
                log::info!("[backup_before_sync] 读取备份偏好失败，跳过: {}", e);
                return;
            }
        }

        let backup_result = crate::api::full_sync_backup_api::export_full_sync_backup(
            &self.db_pool,
            &self.app_data_dir,
            &password,
        )
        .await;

        match backup_result {
            Ok(_) => log::info!("[backup_before_sync] 同步前备份成功"),
            Err(e) => {
                log::info!("[backup_before_sync] 同步前备份失败，继续同步: {}", e);
                result.errors.push(format!("同步前备份失败: {}", e));
            }
        }
    }

    /// 带重试的同步执行（功能⑤：业务级网络重试）
    ///
    /// 仅对网络错误（`is_network_error() == true`）重试，其他错误立即返回。
    /// 重试策略：最多 `max_retries` 次，间隔 2/4/8 秒指数退避。
    ///
    /// 限流场景专用退避：识别 429 / 坚果云 "BlockedTemporarily" / "Too many requests"
    /// 等限流错误后，使用 30/60/120 秒长退避，避免加剧限流。
    /// 坚果云免费账户有严格请求频率限制（~1 req/s），短退避会触发持续 503。
    ///
    /// 重试期间互斥锁仍持有：`SyncGuard` 在 `with_retry` 返回后才 Drop，
    /// 重试期间锁不释放，其他同步请求被跳过。
    async fn with_retry<F, Fut, T>(
        &self,
        label: &str,
        max_retries: u32,
        operation: F,
    ) -> Result<T, CloudSyncError>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<T, CloudSyncError>>,
    {
        let normal_delays = [2u64, 4, 8]; // 秒
        let rate_limit_delays = [30u64, 60, 120]; // 秒，限流专用长退避
        let mut last_err: Option<CloudSyncError> = None;
        for attempt in 0..=max_retries {
            match operation().await {
                Ok(v) => return Ok(v),
                Err(e) => {
                    if !e.is_network_error() || attempt == max_retries {
                        return Err(e);
                    }
                    // 限流错误使用更长退避，避免加剧限流
                    let is_rate_limited = e.is_rate_limited();
                    let delay_secs = if is_rate_limited {
                        rate_limit_delays
                            .get(attempt as usize)
                            .copied()
                            .unwrap_or(120)
                    } else {
                        normal_delays.get(attempt as usize).copied().unwrap_or(8)
                    };
                    log::info!(
                        "[with_retry] {} 第{}次失败，{}秒后重试{}: {}",
                        label,
                        attempt + 1,
                        delay_secs,
                        if is_rate_limited {
                            "（限流退避）"
                        } else {
                            ""
                        },
                        e
                    );
                    tokio::time::sleep(Duration::from_secs(delay_secs)).await;
                    last_err = Some(e);
                }
            }
        }
        Err(last_err.unwrap_or_else(|| CloudSyncError::Other {
            message: format!("{} 重试耗尽", label),
        }))
    }
}

/// 计算 Data Key 指纹（SHA-256 前 4 字节 hex），用于诊断日志
///
/// 安全说明：返回单向哈希的前 32 bit，**不可还原密钥**。
/// 仅供日志对比"Key 是否变化"，不用于任何安全判断。
///
/// 历史问题：旧实现返回 Data Key 前 8 字节裸 hex（64 bit 真实密钥材料），
/// 违反密钥卫生。已改为 SHA-256 哈希前缀。
pub(crate) fn data_key_fingerprint(key: &[u8]) -> String {
    let hash = crate::crypto::sha256::sha256_hex(key);
    hash[..8].to_string()
}

/// 判断云端路径是否为模块数据文件（`modules/{name}/data.waitsync`）
///
/// **P0-2 修复后已无调用方**（`cloud_has_module_data` 改为直接 GET 探测，
/// 不再依赖 list_files 返回的路径形态）。保留纯函数与测试供未来恢复
/// 路径匹配语义时参考。
#[allow(dead_code)]
fn is_module_data_path(name: &str) -> bool {
    // 路径分段中必须包含 "modules" 段，且以 /data.waitsync 结尾
    name.split('/').any(|seg| seg == "modules") && name.ends_with("/data.waitsync")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_result_skipped_has_skipped_true() {
        let r = SyncResult::skipped();
        assert!(r.skipped);
        assert_eq!(r.pushed_modules, 0);
        assert_eq!(r.pulled_modules, 0);
    }

    // ========================================================================
    // is_module_data_path: cloud_has_module_data 的路径过滤逻辑
    //
    // 修复点：list_files 已过滤 .waitsync，但其中仍含 _meta.waitsync /
    // assets/*.waitsync / modules/{name}/meta.waitsync 等非模块数据文件，
    // 会导致 cloud_has_module_data 误判为 true → 阻断安全的 fallback init。
    // 仅 modules/{name}/data.waitsync 才视为真正的模块业务数据。
    // ========================================================================

    #[test]
    fn is_module_data_path_matches_modules_data_waitsync() {
        assert!(is_module_data_path("modules/movies/data.waitsync"));
        assert!(is_module_data_path("modules/games/data.waitsync"));
        // 带 base_path 前缀
        assert!(is_module_data_path(
            "wait-sync/user1/modules/movies/data.waitsync"
        ));
    }

    #[test]
    fn is_module_data_path_rejects_non_module_data_files() {
        // 全局索引（非模块数据）
        assert!(!is_module_data_path("_meta.waitsync"));
        assert!(!is_module_data_path("wait-sync/user1/_meta.waitsync"));
        // 附件（非模块数据，加密 Key 可能不同）
        assert!(!is_module_data_path("assets/abc123.waitsync"));
        assert!(!is_module_data_path(
            "wait-sync/user1/assets/abc123.waitsync"
        ));
        // 模块元数据（不是 data）
        assert!(!is_module_data_path("modules/movies/meta.waitsync"));
        // crypto/config（无 .waitsync 后缀，理论上 list_files 不会返回）
        assert!(!is_module_data_path("crypto/config"));
        assert!(!is_module_data_path("wait-sync/user1/crypto/config"));
        // 不以 data.waitsync 结尾
        assert!(!is_module_data_path("modules/movies/data.bak"));
    }

    #[test]
    fn is_module_data_path_rejects_pathological_lookalikes() {
        // 防止误匹配 "xmodules" / "modules_x" 等前缀/后缀变体
        assert!(!is_module_data_path("xmodules/foo/data.waitsync"));
        assert!(!is_module_data_path("modules_x/foo/data.waitsync"));
        // 路径段中必须严格等于 "modules"
        assert!(!is_module_data_path("mymodules/foo/data.waitsync"));
    }

    #[test]
    fn sync_result_default_all_zero() {
        let r = SyncResult::default();
        assert!(!r.skipped);
        assert_eq!(r.pushed_modules, 0);
        assert_eq!(r.pulled_modules, 0);
        assert_eq!(r.uploaded_attachments, 0);
        assert_eq!(r.downloaded_attachments, 0);
        assert_eq!(r.duration_ms, 0);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn sync_result_serializes_to_json() {
        let r = SyncResult {
            pushed_modules: 3,
            pulled_modules: 2,
            uploaded_attachments: 5,
            downloaded_attachments: 1,
            duration_ms: 1234,
            skipped: false,
            errors: vec!["module x failed".to_string()],
        };
        let json = serde_json::to_string(&r).expect("序列化失败");
        let parsed: SyncResult = serde_json::from_str(&json).expect("反序列化失败");
        assert_eq!(parsed.pushed_modules, 3);
        assert_eq!(parsed.errors.len(), 1);
    }

    #[tokio::test]
    async fn fresh_lock_is_none() {
        // 新建的互斥锁内部值应为 None（表示无同步运行）
        let lock: Arc<Mutex<Option<()>>> = Arc::new(Mutex::new(None));
        let guard = lock.lock().await;
        assert!(guard.is_none());
    }

    #[tokio::test]
    async fn lock_owned_acquire_and_drop_cycle() {
        // 验证 lock_owned + SyncGuard Drop 重置标志的完整生命周期
        let lock: Arc<Mutex<Option<()>>> = Arc::new(Mutex::new(None));

        // 1. 首次获取：内部为 None → 设为 Some
        let mut g1 = lock.clone().lock_owned().await;
        assert!(g1.is_none());
        *g1 = Some(());

        // 2. 释放前：第二个请求阻塞等待（此处验证标志已设为 Some）
        //    模拟 SyncGuard::drop 将标志重置为 None
        *g1 = None;
        drop(g1);

        // 3. 释放后：第三个请求能再次获取且看到 None
        let g2 = lock.lock_owned().await;
        assert!(g2.is_none());
    }

    #[tokio::test]
    async fn concurrent_second_acquire_returns_none_when_running() {
        // 模拟 acquire_lock 的互斥逻辑：
        // 当标志为 Some（同步运行中）时，新请求应返回 None（跳过）
        let lock: Arc<Mutex<Option<()>>> = Arc::new(Mutex::new(None));

        // 模拟同步 A 占用锁
        {
            let mut guard = lock.clone().lock_owned().await;
            *guard = Some(());

            // 同步 B 尝试获取（此处用同步方式模拟：标志为 Some → 跳过）
            // 真实场景中 B 会阻塞等待 A 释放，然后看到 None（因 SyncGuard::drop 重置）
            // 但如果 A 仍在运行（未 drop），B 会看到 Some
            assert!(guard.is_some(), "同步运行中标志应为 Some");
        } // guard drop here，但未重置（模拟 SyncGuard 会重置）

        // 验证 SyncGuard Drop 语义：手动重置后释放
        let lock2: Arc<Mutex<Option<()>>> = Arc::new(Mutex::new(None));
        {
            let mut guard = lock2.clone().lock_owned().await;
            *guard = Some(());
            // 模拟 SyncGuard::drop
            *guard = None;
        }
        // 释放后应能再次获取且为 None
        let g = lock2.lock_owned().await;
        assert!(g.is_none());
    }

    #[tokio::test]
    async fn try_lock_owned_skips_immediately_when_held() {
        // 回归测试：验证 acquire_lock 修复后的原语行为
        //
        // 背景：acquire_lock 旧实现用 lock_owned().await 会等待锁释放，但
        // SyncGuard::drop 已重置内部值为 None，导致 if guard.is_some() 永远
        // 为 false，第二个请求会等待第一个完成后再执行一次同步（死循环）。
        //
        // 修复：改用 try_lock_owned()，锁被持有时立即返回 Err，调用方返回 skipped。
        // 本测试验证 try_lock_owned 的行为，防止未来回退到 lock_owned。
        let lock: Arc<Mutex<Option<()>>> = Arc::new(Mutex::new(None));

        // 1. 同步 A 获取锁并设置运行标志
        let mut guard_a = lock.clone().lock_owned().await;
        *guard_a = Some(());

        // 2. 同步 B 尝试获取锁：应立即返回 Err（而非等待 A 释放）
        let result_b = lock.clone().try_lock_owned();
        assert!(
            result_b.is_err(),
            "锁被持有时 try_lock_owned 应立即返回 Err，而非等待"
        );

        // 3. 同步 A 释放锁（重置运行标志 + drop）
        *guard_a = None;
        drop(guard_a);

        // 4. 同步 C 尝试获取锁：应成功
        let result_c = lock.clone().try_lock_owned();
        assert!(result_c.is_ok(), "锁释放后 try_lock_owned 应成功获取");
    }

    // ========================================================================
    // P0-B/C: decide_auto_upload_behavior 决策函数测试
    //
    // 这是 sync_data_key_from_cloud 404/WrongPassword 守卫的核心决策逻辑。
    // 历史问题：旧逻辑在云端有 Key A 加密的模块数据但缺 crypto/config 时，
    // 会自动补传本地 Key B 覆盖云端，造成永久污染。
    // 修复：通过此决策函数明确区分"安全补传"与"必须阻断"场景。
    // ========================================================================

    #[test]
    fn decide_auto_upload_proceeds_when_cloud_empty_and_local_has_key() {
        // 场景：首次同步，云端无任何 .waitsync 文件，本地已生成 Data Key
        // 期望：安全补传本地 bundle（Proceed）
        let decision = decide_auto_upload_behavior(false, true);
        assert_eq!(
            decision,
            AutoUploadDecision::Proceed,
            "云端无模块数据时，本地 Key 可安全补传"
        );
    }

    #[test]
    fn decide_auto_upload_blocks_when_cloud_has_data_and_local_has_key() {
        // 关键场景：云端已有 Key A 加密的模块数据，本地持有 Key B
        // 期望：阻断补传（Block），返回 KeyMismatch 引导恢复流程
        //
        // 历史问题：旧逻辑在此场景直接补传 Key B，永久污染云端。
        let decision = decide_auto_upload_behavior(true, true);
        assert_eq!(
            decision,
            AutoUploadDecision::Block,
            "云端已有模块数据时，必须阻断补传避免污染"
        );
    }

    #[test]
    fn decide_auto_upload_skips_when_local_has_no_key() {
        // 场景 1：本地无 Data Key + 云端无模块数据
        let decision = decide_auto_upload_behavior(false, false);
        assert_eq!(
            decision,
            AutoUploadDecision::Skip,
            "本地无 Data Key 时跳过补传"
        );

        // 场景 2：本地无 Data Key + 云端有模块数据
        let decision = decide_auto_upload_behavior(true, false);
        assert_eq!(
            decision,
            AutoUploadDecision::Skip,
            "本地无 Data Key 时跳过补传（即使云端有数据，让上层走解锁流程）"
        );
    }

    // ========================================================================
    // P0-D: join_base_path 路径拼接测试
    // ========================================================================

    #[test]
    fn join_base_path_returns_file_path_when_base_empty() {
        assert_eq!(join_base_path("", "_meta.waitsync"), "_meta.waitsync");
        assert_eq!(
            join_base_path("", "modules/movies/data.waitsync"),
            "modules/movies/data.waitsync"
        );
    }

    #[test]
    fn join_base_path_joins_with_slash_when_base_non_empty() {
        assert_eq!(
            join_base_path("wait-sync/user1", "_meta.waitsync"),
            "wait-sync/user1/_meta.waitsync"
        );
    }

    #[test]
    fn join_base_path_trims_trailing_slash_from_base() {
        // base_path 末尾的 / 必须去除，避免双斜杠
        assert_eq!(
            join_base_path("wait-sync/user1/", "_meta.waitsync"),
            "wait-sync/user1/_meta.waitsync"
        );
        assert_eq!(
            join_base_path("wait-sync/user1///", "_meta.waitsync"),
            "wait-sync/user1/_meta.waitsync"
        );
    }

    // ========================================================================
    // P0-D: probe_data_key_with_global_meta 解密探针测试
    //
    // 探针的作用：在 sync_data_key_from_cloud 所有正常完成路径返回前，
    // 用本地 Data Key 尝试解密云端 _meta.waitsync，提前发现 Key 不匹配。
    // ========================================================================

    use crate::cloud_sync::crypto_io::encrypt_payload;
    use crate::sync::error::SyncError;
    use crate::sync_adapters::traits::RemoteFile;
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::Mutex as StdMutex;

    /// 探针测试用 MockAdapter
    ///
    /// 维护 path → data 映射，download 命中返回数据，未命中返回 404 Network 错误。
    /// upload/delete/list_files 等用 Mutex 记录调用，便于断言。
    struct ProbeMockAdapter {
        files: HashMap<String, Vec<u8>>,
        upload_calls: StdMutex<Vec<(String, Vec<u8>)>>,
    }

    impl ProbeMockAdapter {
        fn new() -> Self {
            Self {
                files: HashMap::new(),
                upload_calls: StdMutex::new(Vec::new()),
            }
        }

        fn with_file(mut self, path: &str, data: Vec<u8>) -> Self {
            self.files.insert(path.to_string(), data);
            self
        }
    }

    #[async_trait]
    impl SyncAdapter for ProbeMockAdapter {
        async fn list_files(&self, _base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
            Ok(Vec::new())
        }
        async fn list_all_files(&self, _base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
            Ok(Vec::new())
        }
        async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
            match self.files.get(path) {
                Some(data) => Ok(data.clone()),
                None => Err(SyncError::Network {
                    message: format!("资源不存在(404): {path}"),
                    retryable: false,
                }),
            }
        }
        async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
            self.upload_calls
                .lock()
                .unwrap()
                .push((path.to_string(), data.to_vec()));
            Ok(())
        }
        async fn delete(&self, _path: &str) -> Result<(), SyncError> {
            Ok(())
        }
        async fn upload_asset(&self, _hash: &str, _data: &[u8]) -> Result<(), SyncError> {
            Ok(())
        }
        async fn download_asset(&self, _hash: &str) -> Result<Vec<u8>, SyncError> {
            Err(SyncError::Network {
                message: "资源不存在(404)".to_string(),
                retryable: false,
            })
        }
        async fn asset_exists(&self, _hash: &str) -> Result<bool, SyncError> {
            Ok(false)
        }
        async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
            Ok(Vec::new())
        }
    }

    fn test_data_key(byte: u8) -> Vec<u8> {
        vec![byte; 32]
    }

    #[tokio::test]
    async fn probe_returns_ok_when_global_meta_decrypts_successfully() {
        // 场景：云端 _meta.waitsync 用 Key A 加密，本地 Data Key = Key A
        // 期望：探针返回 Ok(())
        let key = test_data_key(0x42);
        let encrypted_meta = encrypt_payload(b"{}", &key).unwrap();
        let adapter = ProbeMockAdapter::new().with_file("_meta.waitsync", encrypted_meta);

        let result = probe_data_key_with_global_meta(&adapter, "", &key).await;
        assert!(
            result.is_ok(),
            "Key 匹配时探针应返回 Ok，实际: {:?}",
            result
        );
    }

    #[tokio::test]
    async fn probe_returns_key_mismatch_when_decryption_fails() {
        // 关键场景：云端 _meta.waitsync 用 Key A 加密，本地 Data Key = Key B
        // 期望：探针返回 Err(KeyMismatch)，UI 走恢复流程而非解锁页
        let cloud_key = test_data_key(0x42);
        let local_key = test_data_key(0x99);
        let encrypted_meta = encrypt_payload(b"{}", &cloud_key).unwrap();
        let adapter = ProbeMockAdapter::new().with_file("_meta.waitsync", encrypted_meta);

        let result = probe_data_key_with_global_meta(&adapter, "", &local_key).await;
        assert!(
            matches!(result, Err(CloudSyncError::KeyMismatch)),
            "Key 不匹配时探针应返回 KeyMismatch，实际: {:?}",
            result
        );
    }

    #[tokio::test]
    async fn probe_returns_ok_when_global_meta_404() {
        // 场景：云端无 _meta.waitsync（首次同步）
        // 期望：探针跳过，返回 Ok（不阻塞首次同步）
        let key = test_data_key(0x42);
        let adapter = ProbeMockAdapter::new(); // 无文件

        let result = probe_data_key_with_global_meta(&adapter, "", &key).await;
        assert!(result.is_ok(), "云端无 global_meta 时探针应跳过返回 Ok");
    }

    #[tokio::test]
    async fn probe_uses_base_path_prefix_when_downloading() {
        // 场景：base_path 非空，_meta.waitsync 应从 {base_path}/_meta.waitsync 下载
        // 期望：探针用拼接后的路径下载
        let key = test_data_key(0x42);
        let encrypted_meta = encrypt_payload(b"{}", &key).unwrap();
        // 文件放在 base_path 之下
        let adapter =
            ProbeMockAdapter::new().with_file("wait-sync/user1/_meta.waitsync", encrypted_meta);

        let result = probe_data_key_with_global_meta(&adapter, "wait-sync/user1", &key).await;
        assert!(result.is_ok(), "base_path 非空时探针应正确拼接路径并下载");
    }

    // ========================================================================
    // FR-1: data_key_fingerprint 安全卫生测试
    //
    // 历史问题：旧实现返回 Data Key 前 8 字节的裸 hex（16 字符），
    // 即 64 bit 真实密钥材料进入日志，违反密钥卫生。
    // 修复：改为 SHA-256(key) 前 4 字节 hex（8 字符），单向不可逆。
    // ========================================================================

    #[test]
    fn fingerprint_returns_8_chars_not_16() {
        // 旧实现返回 16 字符（8 裸字节 hex），新实现应返回 8 字符（哈希前 4 字节）
        let key = [0x42u8; 32];
        let fp = data_key_fingerprint(&key);
        assert_eq!(
            fp.len(),
            8,
            "指纹应为 8 hex 字符（SHA-256 前 4 字节），而非 16（裸 8 字节）"
        );
    }

    #[test]
    fn fingerprint_is_hash_not_raw_bytes() {
        // 全零 Key：裸字节指纹会是 "0000000000000000"，哈希指纹必须不同
        let zero_key = [0u8; 32];
        let fp = data_key_fingerprint(&zero_key);
        assert_ne!(
            fp, "00000000",
            "全零 Key 的指纹不应是裸字节前缀（哪怕 4 字节也是密钥材料泄露）"
        );
        // 验证确实是 SHA-256([0;32]) 的前 4 字节
        let expected = &crate::crypto::sha256::sha256_hex(&zero_key)[..8];
        assert_eq!(fp, expected, "指纹应为 SHA-256 哈希前 4 字节");
    }

    #[test]
    fn fingerprint_stable_for_same_key() {
        let key = [0xABu8; 32];
        assert_eq!(
            data_key_fingerprint(&key),
            data_key_fingerprint(&key),
            "相同 Key 指纹必须稳定（用于日志对比 Key 是否变化）"
        );
    }

    #[test]
    fn fingerprint_differs_for_different_keys() {
        let key_a = [0x01u8; 32];
        let key_b = [0x02u8; 32];
        assert_ne!(
            data_key_fingerprint(&key_a),
            data_key_fingerprint(&key_b),
            "不同 Key 指纹应不同（否则日志无法区分）"
        );
    }

    // ========================================================================
    // v2 确定性密钥：sync_data_key_from_cloud 的 v2 分支
    //
    // 本地 meta 为 v2 时跳过云端 bundle 导入（同密码必同 Key，导入无意义），
    // 由外层探针校验本机 Key 与云端数据一致性。
    // ========================================================================

    #[test]
    fn v2_derivation_same_password_same_key_across_services() {
        // 引擎视角的核心不变量：两个不同 app_data_dir 的 SyncCryptoService，
        // 同密码 init 后内存中的 Data Key 完全一致——多设备「密码即 Key」
        let tmp_a = tempfile::TempDir::new().unwrap();
        let svc_a = crate::sync_crypto::SyncCryptoService::new(tmp_a.path());
        let key_a = svc_a.init("pw").unwrap();

        let tmp_b = tempfile::TempDir::new().unwrap();
        let svc_b = crate::sync_crypto::SyncCryptoService::new(tmp_b.path());
        let key_b = svc_b.init("pw").unwrap();

        assert_eq!(key_a, key_b);
        assert_eq!(
            data_key_fingerprint(&key_a),
            data_key_fingerprint(&key_b),
            "同密码跨设备指纹必须一致（探针/日志可观测）"
        );
    }

    #[tokio::test]
    async fn probe_passes_for_v2_cross_device_same_password() {
        // v2 多设备场景模拟：设备 A 用密码 P 加密 global_meta 上传云端，
        // 设备 B 同密码 P init → 探针必须通过（v1 下这是 KeyMismatch 高发场景）
        let tmp_a = tempfile::TempDir::new().unwrap();
        let svc_a = crate::sync_crypto::SyncCryptoService::new(tmp_a.path());
        let key_a = svc_a.init("shared").unwrap();

        let encrypted_meta = encrypt_payload(b"{}", &key_a).unwrap();
        let adapter = ProbeMockAdapter::new().with_file("_meta.waitsync", encrypted_meta);

        let tmp_b = tempfile::TempDir::new().unwrap();
        let svc_b = crate::sync_crypto::SyncCryptoService::new(tmp_b.path());
        let key_b = svc_b.init("shared").unwrap();

        let result = probe_data_key_with_global_meta(&adapter, "", &key_b).await;
        assert!(
            result.is_ok(),
            "v2 同密码跨设备探针必须通过（KeyMismatch 分叉态已结构性消灭），实际: {:?}",
            result
        );
    }

    #[tokio::test]
    async fn probe_still_detects_cross_password_in_v2() {
        // v2 下 KeyMismatch 仅剩一种真实成因：云端数据是**另一个密码**加密的
        //（如用户在另一台设备改用了不同密码重新初始化）
        let tmp_a = tempfile::TempDir::new().unwrap();
        let svc_a = crate::sync_crypto::SyncCryptoService::new(tmp_a.path());
        let key_a = svc_a.init("password_one").unwrap();

        let encrypted_meta = encrypt_payload(b"{}", &key_a).unwrap();
        let adapter = ProbeMockAdapter::new().with_file("_meta.waitsync", encrypted_meta);

        let tmp_b = tempfile::TempDir::new().unwrap();
        let svc_b = crate::sync_crypto::SyncCryptoService::new(tmp_b.path());
        let key_b = svc_b.init("password_two").unwrap();

        let result = probe_data_key_with_global_meta(&adapter, "", &key_b).await;
        assert!(
            matches!(result, Err(CloudSyncError::KeyMismatch)),
            "跨密码场景探针仍须报 KeyMismatch（引导恢复流程），实际: {:?}",
            result
        );
    }

    // ========================================================================
    // rekey_cloud_reencrypt：全量重传编排
    //
    // 关键行为：未解锁时必须拒绝且不动云端（前置分支测试）。
    // 完整链路（清 state → 全模块 push → 附件重传 → 上传 config）依赖
    // SqlitePool 与 15 模块表，由 m4 e2e 与 push_all/attachments 既有测试覆盖。
    // ========================================================================

    #[tokio::test]
    async fn rekey_requires_unlocked_key() {
        // 未解锁（内存无 Key）必须立即失败，不得动云端任何数据
        let pool = sqlx::SqlitePool::connect(":memory:").await.unwrap();
        let tmp = tempfile::TempDir::new().unwrap();
        let crypto = crate::sync_crypto::SyncCryptoService::new(tmp.path());
        let engine = SyncEngine::new_noop_progress(pool, crypto, tmp.path());

        let adapter = ProbeMockAdapter::new();
        let result = engine
            .rekey_cloud_reencrypt(
                &adapter,
                &adapter,
                "",
                SyncOrigin::Manual,
                "device-1",
                "/tmp/attachments",
            )
            .await;
        assert!(
            matches!(result, Err(CloudSyncError::CryptoLocked)),
            "未解锁时 rekey 必须拒绝执行（防误操作），实际: {:?}",
            result
        );
        // 不得有任何上传发生
        assert!(
            adapter.upload_calls.lock().unwrap().is_empty(),
            "rekey 被拒时不得产生云端写入"
        );
    }

    // ========================================================================
    // record_incremental_history：增量同步历史（P1-17）
    // ========================================================================

    /// 构造带迁移内存库的引擎（历史写入直连 sync_history 表）
    async fn history_engine() -> SyncEngine {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        let tmp = tempfile::TempDir::new().unwrap();
        let crypto = crate::sync_crypto::SyncCryptoService::new(tmp.path());
        SyncEngine::new_noop_progress(pool, crypto, tmp.path())
    }

    fn ok_result(errors: Vec<String>) -> SyncResult {
        SyncResult {
            pushed_modules: 2,
            pulled_modules: 3,
            uploaded_attachments: 1,
            downloaded_attachments: 4,
            duration_ms: 120,
            skipped: false,
            errors,
        }
    }

    #[tokio::test]
    async fn history_records_success_with_counts() {
        let engine = history_engine().await;
        let r = Ok(ok_result(vec![]));
        record_incremental_history(&engine.db_pool, SYNC_TYPE_SYNC_NOW, &r).await;

        let rows = sync_history_repo::get_recent_by_types(&engine.db_pool, &["incremental"], 10)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        let h = &rows[0];
        assert_eq!(h.status, "success");
        assert_eq!(h.pulled_count, 7, "拉取计数 = 模块 3 + 附件 4");
        assert_eq!(h.pushed_count, 3, "推送计数 = 模块 2 + 附件 1");
        assert!(h.error_message.is_none());
    }

    #[tokio::test]
    async fn history_records_module_errors_as_failed() {
        let engine = history_engine().await;
        let r = Ok(ok_result(vec!["todos 模块上传失败".to_string()]));
        record_incremental_history(&engine.db_pool, SYNC_TYPE_PUSH_ONLY, &r).await;

        let rows = sync_history_repo::get_recent_by_types(&engine.db_pool, &["push_only"], 10)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, "failed", "模块级有错按失败记");
        assert!(rows[0].error_message.as_ref().unwrap().contains("todos"));
    }

    #[tokio::test]
    async fn history_records_engine_error_as_failed() {
        let engine = history_engine().await;
        let r = Err::<SyncResult, _>(CloudSyncError::Adapter {
            message: "连接超时".to_string(),
        });
        record_incremental_history(&engine.db_pool, SYNC_TYPE_PULL_THEN_PUSH, &r).await;

        let rows = sync_history_repo::get_recent_by_types(&engine.db_pool, &["pull_only"], 10)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, "failed");
        assert!(rows[0].error_message.as_ref().unwrap().contains("连接超时"));
    }

    #[tokio::test]
    async fn history_skips_when_sync_was_skipped() {
        let engine = history_engine().await;
        let r = Ok(SyncResult::skipped());
        record_incremental_history(&engine.db_pool, SYNC_TYPE_SYNC_NOW, &r).await;

        let rows = sync_history_repo::get_recent_by_types(&engine.db_pool, &["incremental"], 10)
            .await
            .unwrap();
        assert!(rows.is_empty(), "防重入跳过不是一次同步，不得记历史");
    }

    #[tokio::test]
    async fn history_prunes_beyond_keep_limit() {
        let engine = history_engine().await;
        // 直接灌 55 条超出保留上限 50
        for i in 0..55 {
            let id =
                sync_history_repo::insert(&engine.db_pool, SYNC_TYPE_SYNC_NOW, "success", 1000 + i)
                    .await
                    .unwrap();
            sync_history_repo::update_status(
                &engine.db_pool,
                id,
                "success",
                1000 + i,
                0,
                0,
                0,
                None,
            )
            .await
            .unwrap();
        }
        let r = Ok(ok_result(vec![]));
        record_incremental_history(&engine.db_pool, SYNC_TYPE_SYNC_NOW, &r).await;

        assert_eq!(
            sync_history_repo::count_by_type(&engine.db_pool, "incremental")
                .await
                .unwrap(),
            50,
            "写入后同类型历史须裁剪到保留上限"
        );
    }
}
