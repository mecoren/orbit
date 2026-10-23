//! attachments — 附件同步（内容寻址 + 全加密）
//!
//! 附件以 sha256 hash 为云端文件名，用 Data Key AES-256-GCM 加密后上传。
//! Push 上传本地有但云端无的附件，Pull 下载云端有但本地无的附件。
//!
//! ## 同步策略（M3/T1.1 起改为流式）
//! - **Push**：查询 `sys_attachments WHERE is_local_cached = 1 AND is_uploaded = 0`，
//!   把本地明文流式加密成 `OSAC` 分块容器临时文件（峰值 ≈ 一帧明文 + 一帧密文）→
//!   `adapter.upload_asset_file(hash, tmp, len)` 由适配器按块读取上传 →
//!   删除临时文件 → 标记 `is_uploaded = 1`
//! - **Pull**：列出云端附件 → 对比本地 `sys_attachments` → 流式下载到临时文件 →
//!   按首字节分流：`OSAC` 逐帧解密（末尾整体 sha256 校验），存量整包 `OSZS` 仍
//!   走旧路径 → 原子重命名到 `{attachments_dir}/{hash}` → 更新 `is_local_cached = 1`
//!
//! 存量对象无需迁移：读侧按 magic 分流，旧附件照常可读（整包路径的峰值仍是
//! 对象大小，但只发生在尚未重传的旧对象上）。
//!
//! ## 并发控制
//! 默认 **2 路并发**（原为 4 路）并叠加**在途字节预算**（默认 64MiB，可配置）：
//! 4 路并发在大附件场景下等于把峰值乘以 4，而流式化之后单件本身已与文件大小
//! 解耦，瓶颈回到网络——2 路足以跑满家用上行/下行，预算则防「两个 50MB 同时
//! 在途」把适配器内部的整包回退路径叠加起来。
//! `SyncAdapter: Send + Sync`，共享引用可跨并发 future 借用，无需 spawn + 'static。
//!
//! 预算口径：Push 按附件明文大小申请配额（单件超过预算时按预算上限放行，
//! 不因超额而永久排队）；Pull 的云端列表不含大小，且下载已是分块流式，故按
//! 1 个并发单位申请——真正约束 pull 峰值的是帧大小而非预算。
//!
//! ## Pull 的差集为何收窄到「有活跃引用」（S31，不是缺陷）
//!
//! 差集是 `云端 - 本地已缓存 - 无本地任务引用`。前两项无争议；第三项防的是
//! 「GC ↔ pull 对打架循环」：本端 GC 删掉无引用附件后，云端对象仍在
//! （其他设备视角可能还挂着），朴素差集会把它拉回、插占位行、下轮 GC 又删。
//!
//! **新设备不会因此漏附件**：两个同步入口都是先 `pull_all`（模块合并，
//! `todo_task_attachments` 关联行随之落地）再 `attachments_pull`，所以
//! 真实引用在过滤前已经就位——见 `pull_downloads_attachment_whose_link_arrived_same_round`。
//! 唯一的暴露面是「模块 pull 失败但附件 pull 仍执行」的那一轮，此时关联表为空、
//! 附件全被跳过；该轮本身带 errors、账本不推进，下一轮会重试。
//! 收窄结果已落日志（见 F83），避免这类轮次看起来像「静默什么都没发生」。
//!
//! ## 错误隔离
//! 单个附件上传/下载失败不阻塞其他附件，错误收集到返回值。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use futures::stream::{self, StreamExt};
use sqlx::SqlitePool;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::cloud_sync::asset_container;
use crate::cloud_sync::crypto_io::decrypt_payload;
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::progress::{ProgressSender, SyncOrigin, SyncProgress};
use crate::db::repository::attachment_repo;
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

/// 默认并发路数（4 → 2：大附件并发叠加是原方案的主要峰值来源）
pub const DEFAULT_MAX_CONCURRENT_TRANSFERS: usize = 2;

/// 默认在途字节预算（64MiB：两个 32MB 级流式传输的上限档）
pub const DEFAULT_MAX_IN_FLIGHT_BYTES: u64 = 64 * 1024 * 1024;

/// 附件传输限额（可配置：测试与未来的「网络带宽设置」共用同一入口）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttachmentTransferLimits {
    /// 同时进行的上传/下载件数
    pub max_concurrent: usize,
    /// 在途字节预算（Push 按明文大小申请；单件超预算时按预算上限放行）
    pub max_in_flight_bytes: u64,
}

impl Default for AttachmentTransferLimits {
    fn default() -> Self {
        Self {
            max_concurrent: DEFAULT_MAX_CONCURRENT_TRANSFERS,
            max_in_flight_bytes: DEFAULT_MAX_IN_FLIGHT_BYTES,
        }
    }
}

/// 在途字节预算闸门（按 MiB 粒度加权，`Semaphore` 保证公平等待）
struct TransferGate {
    budget_mib: usize,
    sem: Arc<Semaphore>,
}

impl TransferGate {
    fn new(limits: AttachmentTransferLimits) -> Self {
        let budget_mib = ((limits.max_in_flight_bytes / (1024 * 1024)) as usize).max(1);
        Self {
            budget_mib,
            sem: Arc::new(Semaphore::new(budget_mib)),
        }
    }

    /// 申请 `bytes` 对应的配额（1MiB 起算；超预算按预算上限，避免大文件饿死）
    async fn acquire(&self, bytes: u64) -> Option<OwnedSemaphorePermit> {
        let units = ((bytes / (1024 * 1024)) as usize + 1).min(self.budget_mib);
        self.sem.clone().acquire_many_owned(units as u32).await.ok()
    }
}

/// 附件同步结果
#[derive(Debug, Clone, Default)]
pub struct AttachmentSyncResult {
    /// 上传的附件数
    pub uploaded: u32,
    /// 下载的附件数
    pub downloaded: u32,
    /// 跳过的附件数（已存在）
    pub skipped: u32,
    /// 错误信息（不阻塞整体流程）
    pub errors: Vec<String>,
}

/// 单个附件的并发下载结果：`(hash, 下载结局, 实际字节数)`
///
/// 结局内层是 `(本地路径, 字节数)`；失败只带可读原因，由主流程汇总进
/// `AttachmentSyncResult.errors`（单件失败不阻塞本轮其他附件）。
type DownloadOutcome = (String, Result<(String, i64), String>, i64);

/// 抽取本地未上传附件中的首个 hash（空列表防御的探针）
///
/// 返回 None 表示列表为空（调用方已提前 return，此分支不可达，防御性处理）。
fn to_upload_probe(unuploaded: &[crate::models::business::Attachment]) -> Option<&str> {
    unuploaded.first().map(|a| a.hash.as_str())
}

/// Push 附件：上传本地有但云端无的附件（默认限额）
///
/// `attachments_dir` 是本地附件文件目录（与 `asset_api` 使用同一目录）。
/// `origin` 标识事件来源（Background/Manual/Exit），用于 UI 层过滤重复显示。
pub async fn sync_attachments_push(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    attachments_dir: &str,
) -> Result<AttachmentSyncResult, CloudSyncError> {
    sync_attachments_push_with_limits(
        db_pool,
        crypto,
        adapter,
        progress_sender,
        origin,
        attachments_dir,
        AttachmentTransferLimits::default(),
    )
    .await
}

/// Push 附件（显式并发/字节预算，测试与未来「带宽设置」用）
pub async fn sync_attachments_push_with_limits(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    attachments_dir: &str,
    limits: AttachmentTransferLimits,
) -> Result<AttachmentSyncResult, CloudSyncError> {
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    let mut result = AttachmentSyncResult::default();

    // 1. 查询本地已缓存但未上传的附件
    let unuploaded = attachment_repo::get_unuploaded(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("查询未上传附件失败: {}", e),
        })?;

    if unuploaded.is_empty() {
        return Ok(result);
    }

    // 2. 查询云端已有附件（避免重复上传）
    // Fix-13：list 失败不得静默视为"云端为空"——那会导致全量重复上传，
    // 在坚果云等严格限流服务上雪上加霜。本轮终止，下次同步重试。
    // 目录传相对 ASSETS_DIR：base_path 前缀由 BasePathAdapter 负责（F23）
    let cloud_hashes: HashSet<String> = match adapter
        .list_assets(crate::cloud_sync::paths::ASSETS_DIR)
        .await
    {
        Ok(list) => list.into_iter().collect(),
        Err(e) => {
            result
                .errors
                .push(format!("列出云端附件失败，本轮跳过附件上传: {}", e));
            return Ok(result);
        }
    };

    // S7（2026-09-13 探查）：空列表防御——本地有未上传附件但云端列表为空，
    // 大概率是 list 探测异常（部分服务对空 prefix 返回空而非 404），
    // 而非真的"云端无附件"（真被清空时 reconcile 已触发全量重传）。
    // 直接上传会产生 N 个对象的全量风暴，在限流服务上雪崩。防御性跳过本轮。
    //
    // 2026-09-14 修正：首台设备从零同步时云端资产目录确实不存在（list 404
    // → 空列表），空列表防御会把附件上传永久死锁（每轮都判"疑似探测异常"）。
    // 区分两态：抽本地首个未上传附件做存在性探测（asset_exists 双路径）——
    // 该附件在云端真实存在说明列表结果不可信（防御生效）；
    // 404 确认不存在说明是真正的空云（首传/被清空后重传），放行上传。
    if cloud_hashes.is_empty() {
        let probe = &to_upload_probe(&unuploaded);
        if let Some(first_hash) = probe {
            match adapter.asset_exists(first_hash).await {
                Ok(true) => {
                    result.errors.push(format!(
                        "云端附件列表为空但附件 {} 实际存在，疑似列举异常，本轮跳过附件上传",
                        first_hash
                    ));
                    return Ok(result);
                }
                Ok(false) => {
                    log::info!(
                        "[attachments_push] 云端列表为空且 {} 确认不存在（首传/清空后重传），放行上传",
                        first_hash
                    );
                }
                Err(e) => {
                    // 探测失败无法区分两态，保守跳过（下轮重试），不做全量风暴赌注
                    result
                        .errors
                        .push(format!("附件存在性探测失败，本轮跳过附件上传: {}", e));
                    return Ok(result);
                }
            }
        } else {
            // unuploaded 非空但取不到首个 hash（理论不可达，防御性跳过）
            result
                .errors
                .push("云端附件列表为空且无法探测本地附件，本轮跳过附件上传".to_string());
            return Ok(result);
        }
    }

    // 3. 分离"云端已存在"（仅修正标记）与"待上传"两组
    let mut to_upload = Vec::new();
    for attachment in unuploaded {
        if cloud_hashes.contains(&attachment.hash) {
            // 标记为已上传（本地状态与云端不一致，修正）
            // S9：吞错收敛——DB 标记失败记入 errors 可见（此前 let _ = 静默，
            // 标记持续失败时每轮重复走修正分支且不可观测）
            if let Err(e) = attachment_repo::mark_uploaded(db_pool, &attachment.hash).await {
                result
                    .errors
                    .push(format!("标记附件 {} 为已上传失败: {}", attachment.hash, e));
            }
            result.skipped += 1;
        } else {
            to_upload.push(attachment);
        }
    }

    if to_upload.is_empty() {
        return Ok(result);
    }

    let total = to_upload.len() as u32;
    // 已完成计数（并发下按完成序报告进度，而非任务下标序）
    let done_counter = AtomicU32::new(0);
    let gate = TransferGate::new(limits);
    let max_concurrent = limits.max_concurrent.max(1);

    // 4. 并发上传（默认 2 路 + 在途字节预算，M3/T1.1）
    //
    // `buffer_unordered` 在当前 task 内并发驱动至多 N 个 future，
    // future 仅借用 `adapter`/`data_key` 等共享引用（SyncAdapter: Send + Sync），
    // 无需 tokio::spawn 的 'static 约束。加密与上传全流程并行，但**每一步都
    // 是分块流式**：内存峰值 ≈ 一帧明文 + 一帧密文，与附件大小无关。
    let outcomes: Vec<(String, Result<(), String>)> = stream::iter(to_upload)
        .map(|attachment| {
            let data_key = &data_key;
            let done_counter = &done_counter;
            let gate = &gate;
            async move {
                let hash = attachment.hash.clone();
                let local_path = attachment.local_path.clone().unwrap_or_default();
                let _budget = gate.acquire(attachment.size_bytes.max(0) as u64).await;

                // 4a. 定位本地明文
                //
                // F68（2026-09-30 第六轮）：读取失败必须报真实原因（权限不足 /
                // 文件被外部删除 / 磁盘错误），不得统一吞成「文件内容为空」。
                let path = if local_path.is_empty() {
                    Path::new(attachments_dir).join(&hash)
                } else {
                    PathBuf::from(&local_path)
                };
                if let Ok(meta) = tokio::fs::metadata(&path).await {
                    if meta.len() == 0 {
                        return (hash, Err(format!("本地附件内容为空: {}", path.display())));
                    }
                } else {
                    return (hash, Err(format!("读取本地附件失败 {}", path.display())));
                }

                // 4b. 流式加密成临时容器（峰值 ≈ 2 帧，不再整包读 + 整包加密）
                let tmp_container =
                    crate::fs_util::temp_sibling(&Path::new(attachments_dir).join(&hash), "upload");
                let encrypted = match asset_container::encrypt_file_to_container(
                    &path,
                    &tmp_container,
                    data_key,
                    &hash,
                ) {
                    Ok(info) => info,
                    Err(e) => {
                        let _ = tokio::fs::remove_file(&tmp_container).await;
                        return (hash.clone(), Err(format!("加密附件 {} 失败: {}", hash, e)));
                    }
                };

                // 4c. 上传（适配器按块读取临时容器；失败路径同样清理）
                let outcome = match adapter
                    .upload_asset_file(&hash, &tmp_container, encrypted.container_bytes)
                    .await
                {
                    Ok(()) => Ok(()),
                    Err(e) => Err(format!("上传附件 {} 失败: {}", hash, e)),
                };
                let _ = tokio::fs::remove_file(&tmp_container).await;

                // 4d. 按完成序发送进度
                let current = done_counter.fetch_add(1, Ordering::SeqCst) + 1;
                progress_sender.send(SyncProgress::Attachments {
                    origin,
                    action: "upload".to_string(),
                    current,
                    total,
                });

                (hash, outcome)
            }
        })
        .buffer_unordered(max_concurrent)
        .collect()
        .await;

    // 5. 汇总结果 + 落库标记（DB 写入回到主流程串行执行，避免连接池争用）
    for (hash, outcome) in outcomes {
        match outcome {
            Ok(()) => {
                // S9：吞错收敛——上传成功但 DB 标记失败时，附件实际已在云端，
                // 下轮会走"云端已存在→修正标记"分支自愈；错误记入 errors
                // 保证可观测（此前 let _ = 静默，用户无感知每轮重复上传）
                if let Err(e) = attachment_repo::mark_uploaded(db_pool, &hash).await {
                    result
                        .errors
                        .push(format!("标记附件 {} 为已上传失败: {}", hash, e));
                }
                result.uploaded += 1;
            }
            Err(e) => {
                result.errors.push(e);
            }
        }
    }

    Ok(result)
}

/// Pull 附件：下载云端有但本地无的附件（默认限额）
///
/// 对比云端附件列表与本地 `sys_attachments`，下载缺失的附件。
/// `origin` 标识事件来源（Background/Manual/Exit），用于 UI 层过滤重复显示。
pub async fn sync_attachments_pull(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    attachments_dir: &str,
) -> Result<AttachmentSyncResult, CloudSyncError> {
    sync_attachments_pull_with_limits(
        db_pool,
        crypto,
        adapter,
        progress_sender,
        origin,
        attachments_dir,
        AttachmentTransferLimits::default(),
    )
    .await
}

/// Pull 附件（显式并发/字节预算）
pub async fn sync_attachments_pull_with_limits(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    attachments_dir: &str,
    limits: AttachmentTransferLimits,
) -> Result<AttachmentSyncResult, CloudSyncError> {
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    let mut result = AttachmentSyncResult::default();

    // 1. 列出云端附件
    // Fix-13：list 失败不得静默视为"云端无附件"（那会静默跳过全部下载且无感知），
    // 记入 errors 让 UI 可见，下次同步重试。
    let cloud_hashes: Vec<String> = match adapter
        .list_assets(crate::cloud_sync::paths::ASSETS_DIR)
        .await
    {
        Ok(list) => list,
        Err(e) => {
            result
                .errors
                .push(format!("列出云端附件失败，本轮跳过附件下载: {}", e));
            return Ok(result);
        }
    };
    // 注意：云端为空时**不能**提前 return——本端有活跃引用但云端对象已消失
    // （网盘端误删/他端旧版本清理）同样要走下面的缺失对账自愈（2.6）。

    // 2. 查询本地已缓存的附件 hash 集合
    let local_cached = attachment_repo::get_all_local_cached(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("查询本地缓存附件失败: {}", e),
        })?;
    let local_set: HashSet<String> = local_cached.iter().map(|a| a.hash.clone()).collect();

    // 2.5 活跃引用集合（S31：GC ↔ pull 对打架循环修复，2026-09-14 审查）
    //
    // 云端孤儿附件（本端 GC 删除无引用附件后，其他设备视角仍挂载的对象）
    // 若按「云端有 - 本地无」朴素差集拉回：下载 → 插占位行 → 下轮 GC 又删
    // → 再下轮 pull 又拉回，无限循环耗磁盘与流量。差集只保留本端仍有
    // 存活任务引用的 hash——真正被任务挂载的附件（含关联行刚从 pull 合并
    // 进来的新引用）一定会被拉回，孤儿留在云端不下载。
    let active_refs: HashSet<String> = attachment_repo::get_active_referenced_hashes(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("查询附件活跃引用失败: {}", e),
        })?
        .into_iter()
        .collect();

    // 2.6 云端缺失对账（docs/15 §4.5，必须与云端清理同批上线）
    //
    // 场景：云端对象已不存在（本机手动清理、用户在网盘端误删、其他设备旧版
    // 清理），但本端任务仍挂着它。朴素差集只会「云端有 - 本地无」→ 这一步
    // 静默跳过，附件永久缺失且用户无感知。收口：
    //   - 本地仍有明文 → 置 is_uploaded = 0，下一轮 push 以同一 hash 重传
    //     （内容寻址，云端键不变，其他设备可重新拉到）；
    //   - 账本有行但本地无明文 → 无法自愈，汇总一条 error 让 UI 可见；
    //   - 账本无行（新设备关联行先到、对象后到）→ 本轮差集负责拉取，不处理。
    let cloud_set: HashSet<&str> = cloud_hashes.iter().map(String::as_str).collect();
    let mut pending_reupload = 0u32;
    for hash in &active_refs {
        if cloud_set.contains(hash.as_str()) {
            continue;
        }
        if let Some(row) = local_cached.iter().find(|a| &a.hash == hash) {
            // 已是待传（上轮标过）就不重复写库，防每轮同步写放大
            if row.is_uploaded == 0 {
                continue;
            }
            match attachment_repo::mark_pending_reupload(db_pool, hash).await {
                Ok(_) => pending_reupload += 1,
                Err(e) => result
                    .errors
                    .push(format!("附件 {} 标记待重传失败: {}", hash, e)),
            }
        }
    }
    let missing_without_local: Vec<String> = active_refs
        .iter()
        .filter(|h| !cloud_set.contains(h.as_str()) && !local_set.contains(h.as_str()))
        .cloned()
        .collect();
    let mut unrestorable = 0u32;
    if !missing_without_local.is_empty() {
        let rows = attachment_repo::get_by_hashes(db_pool, &missing_without_local)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("查询缺失附件账本失败: {}", e),
            })?;
        unrestorable = rows.iter().filter(|a| a.is_local_cached == 0).count() as u32;
    }
    if pending_reupload > 0 {
        log::warn!(
            "[attachments_pull] {} 个附件云端缺失但本地有副本，已置待重传（下轮 push 自愈）",
            pending_reupload
        );
    }
    if unrestorable > 0 {
        result.errors.push(format!(
            "{} 个附件云端缺失且本地无副本，无法自动恢复",
            unrestorable
        ));
    }

    // 3. 差集 = 云端有 - 本地有 - 无引用
    //
    // F83：三个集合的规模要落日志。差集被 `active_refs` 收窄是**静默**的
    // （S31 的设计意图），但当收窄把候选清空时，症状是「同步成功、附件一个
    // 都没下」——用户与排障者都无从判断这是「云端真没有」还是「本机引用表
    // 为空」。三个数字（云端总数 / 本地已缓存 / 被引用过滤掉）足以区分：
    // 云端有 N 个但 active_refs 为 0，说明本机的任务-附件关联还没到
    // （模块 pull 失败或本机确实不引用它们），不是传输问题。
    let to_download: Vec<String> = cloud_hashes
        .iter()
        .filter(|h| !local_set.contains(*h) && active_refs.contains(*h))
        .cloned()
        .collect();

    if to_download.is_empty() {
        if cloud_hashes.len() > local_set.len() {
            log::info!(
                "[attachments_pull] 本轮无附件下载：云端 {} 个 / 本地已缓存 {} 个 / \
                 被活跃引用过滤掉 {} 个（云端对象留在云端，等本机出现引用时再拉）",
                cloud_hashes.len(),
                local_set.len(),
                cloud_hashes.len().saturating_sub(local_set.len())
            );
        }
        return Ok(result);
    }

    let total = to_download.len() as u32;

    // 4. 预创建附件目录（并发前一次性完成，避免竞态）
    let dir = Path::new(attachments_dir);
    if let Err(e) = std::fs::create_dir_all(dir) {
        result.errors.push(format!("创建附件目录失败: {}", e));
        return Ok(result);
    }

    // 已完成计数（并发下按完成序报告进度）
    let done_counter = AtomicU32::new(0);
    let gate = TransferGate::new(limits);
    let max_concurrent = limits.max_concurrent.max(1);

    // 5. 并发下载（默认 2 路 + 预算闸门，M3/T1.1）
    // 下载/解密/落盘全流程并行，DB 标记回主流程串行执行；每一步都是分块流式。
    let outcomes: Vec<DownloadOutcome> = stream::iter(to_download)
        .map(|hash| {
            let data_key = &data_key;
            let done_counter = &done_counter;
            let gate = &gate;
            async move {
                // 返回 (本地路径, 实际字节数)——size 供占位行登记（S31 修正）
                let outcome: Result<(String, i64), String> = async {
                    // N51（2026-10-12）纵深防御：hash 将作为本地文件名
                    // （{attachments_dir}/{hash}）与云端对象键使用，格式非法
                    // 即内容寻址假设被破坏或对端数据被篡改。单件失败不阻塞
                    // 本轮其他附件（错误隔离见模块头）；内容正确性仍由末尾的
                    // sha256 背书校验兜底，这里只拦格式。
                    if !crate::crypto::sha256::is_sha256_hex(&hash) {
                        return Err(format!(
                            "附件 {} hash 格式非法（需 64 位小写 sha256 hex），已跳过",
                            hash
                        ));
                    }
                    // 云端列表不含大小：按 1 个单位申请（下载本身已分块流式）
                    let _budget = gate.acquire(0).await;

                    let file_path = Path::new(attachments_dir).join(&hash);
                    let tmp_cipher = crate::fs_util::temp_sibling(&file_path, "download");
                    let tmp_plain = crate::fs_util::temp_sibling(&file_path, "plain");

                    // 5a. 流式下载密文到临时文件（适配器按块写盘）
                    let downloaded = match adapter.download_asset_to_file(&hash, &tmp_cipher).await
                    {
                        Ok(n) => n,
                        Err(e) => {
                            // 适配器可能已写了半截（或空文件），失败路径一并清理
                            let _ = tokio::fs::remove_file(&tmp_cipher).await;
                            return Err(format!("下载附件 {} 失败: {}", hash, e));
                        }
                    };

                    // 5b. 分流解密：
                    //   - OSAC：逐帧 AES-GCM + 末尾整体 sha256 校验（新格式）
                    //   - 其余：存量整包 OSZS（旧对象仍可读；峰值=对象大小）
                    let plain_len: u64 = if asset_container::is_container_file(&tmp_cipher) {
                        match asset_container::decrypt_container_to_file(
                            &tmp_cipher,
                            &tmp_plain,
                            data_key,
                            &hash,
                        ) {
                            Ok(n) => n,
                            Err(e) => {
                                let _ = tokio::fs::remove_file(&tmp_cipher).await;
                                let _ = tokio::fs::remove_file(&tmp_plain).await;
                                return Err(format!("解密附件 {} 失败: {}", hash, e));
                            }
                        }
                    } else {
                        let encrypted = match tokio::fs::read(&tmp_cipher).await {
                            Ok(b) => b,
                            Err(e) => {
                                let _ = tokio::fs::remove_file(&tmp_cipher).await;
                                return Err(format!("读取附件密文 {} 失败: {}", hash, e));
                            }
                        };
                        let decrypted = match decrypt_payload(&encrypted, data_key) {
                            Ok(d) => d,
                            Err(e) => {
                                let _ = tokio::fs::remove_file(&tmp_cipher).await;
                                return Err(format!("解密附件 {} 失败: {}", hash, e));
                            }
                        };
                        // 密文只在解密阶段需要：旧对象整包路径也要尽早释放，
                        // 别让密文与明文同时活在后续 sha256 + 写盘期间
                        drop(encrypted);
                        // 校验内容哈希与文件名（即 sha256）一致：损坏/被篡改的
                        // 内容会被"哈希背书"，后续按 hash 取文件的一切假设都建立在
                        // 内容与名字一致上，落盘前必须校验。
                        let actual = crate::crypto::sha256::sha256_hex(&decrypted);
                        if !crate::crypto::sha256::constant_time_eq(&actual, &hash) {
                            let _ = tokio::fs::remove_file(&tmp_cipher).await;
                            return Err(format!(
                                "附件 {} 内容哈希校验失败（实际 {}），疑似传输损坏，已丢弃",
                                hash, actual
                            ));
                        }
                        if let Err(e) = tokio::fs::write(&tmp_plain, &decrypted).await {
                            let _ = tokio::fs::remove_file(&tmp_cipher).await;
                            let _ = tokio::fs::remove_file(&tmp_plain).await;
                            return Err(format!("保存附件 {} 失败: {}", hash, e));
                        }
                        decrypted.len() as u64
                    };
                    let _ = tokio::fs::remove_file(&tmp_cipher).await;

                    // 5c. 原子落位（P0-8）：tmp+rename 保证要么完整写入、要么不存在。
                    // 下载中途崩溃留半截文件会被后续同步当作"已缓存"（文件名即 hash），
                    // 损坏内容无法自愈。
                    if tokio::fs::rename(&tmp_plain, &file_path).await.is_err() {
                        tokio::fs::remove_file(&file_path).await.ok();
                        if let Err(e) = tokio::fs::rename(&tmp_plain, &file_path).await {
                            let _ = tokio::fs::remove_file(&tmp_plain).await;
                            return Err(format!("附件 {} 原子落盘失败: {}", hash, e));
                        }
                    }

                    log::debug!(
                        "[attachments_pull] {} 下载 {} 字节密文 → 明文 {} 字节",
                        hash,
                        downloaded,
                        plain_len
                    );
                    Ok((file_path.to_string_lossy().to_string(), plain_len as i64))
                }
                .await;

                // 5d. 按完成序发送进度
                let current = done_counter.fetch_add(1, Ordering::SeqCst) + 1;
                progress_sender.send(SyncProgress::Attachments {
                    origin,
                    action: "download".to_string(),
                    current,
                    total,
                });

                let size = outcome.as_ref().map_or(0, |(_, s)| *s);
                (hash, outcome, size)
            }
        })
        .buffer_unordered(max_concurrent)
        .collect()
        .await;

    // 6. 汇总结果 + 更新 sys_attachments 记录（串行落库）
    for (hash, outcome, size) in outcomes {
        match outcome {
            Ok((local_path, _)) => {
                // P0-8：ensure 而非 mark——sys_attachments 不在同步白名单，
                // 新设备/删库后本地无记录，仅 UPDATE 会永远 affected=0，
                // 差集永不为空导致每轮全量重下
                if let Err(e) =
                    attachment_repo::ensure_local_cached(db_pool, &hash, &local_path, size).await
                {
                    // S9 口径：吞错收敛——DB 写入失败必须可观测（此前 let _ =
                    // 静默，每轮重复下载且用户无感知）
                    result
                        .errors
                        .push(format!("登记附件 {} 本地缓存失败: {}", hash, e));
                }
                result.downloaded += 1;
            }
            Err(e) => {
                result.errors.push(e);
            }
        }
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync::crypto_io::encrypt_payload;
    use crate::models::business::Attachment;

    #[test]
    fn attachment_sync_result_default_is_zero() {
        let r = AttachmentSyncResult::default();
        assert_eq!(r.uploaded, 0);
        assert_eq!(r.downloaded, 0);
        assert_eq!(r.skipped, 0);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn to_upload_probe_returns_first_hash() {
        assert_eq!(to_upload_probe(&[]), None);
        let atts = vec![
            Attachment {
                hash: "h1".to_string(),
                original_name: "a".to_string(),
                mime_type: "image/png".to_string(),
                size_bytes: 1,
                local_path: None,
                is_uploaded: 0,
                is_local_cached: 1,
                created_at: 1,
                last_accessed_at: 1,
            },
            Attachment {
                hash: "h2".to_string(),
                original_name: "b".to_string(),
                mime_type: "image/png".to_string(),
                size_bytes: 2,
                local_path: None,
                is_uploaded: 0,
                is_local_cached: 1,
                created_at: 2,
                last_accessed_at: 2,
            },
        ];
        assert_eq!(to_upload_probe(&atts), Some("h1"));
    }

    // ========================================================================
    // 空列表防御三分叉（2026-09-14 修正）：首台设备首传场景不得死锁
    //
    // 历史 bug：S7 防御对「云端列表为空」一律跳过附件上传——首台设备从零
    // 同步时 assets/ 目录不存在（list 404 → 空列表），每轮都被判"疑似探测
    // 异常"，附件永久无法上传（其他设备永远拉不到）。
    // 修正后语义：抽首个未上传附件探测 asset_exists——
    //   云端真实存在 → 列表不可信，防御拦截（原 S7 场景）
    //   404 确认不存在 → 真空云（首传/清空后重传），放行
    //   探测出错 → 无法区分两态，保守跳过待下轮
    // ========================================================================

    /// 附件同步测试 mock：可注入云端文件集合与 asset_exists 探测结果
    struct AttSyncMock {
        /// 云端已存在的 hash（list_assets 返回；空 = 列表为空）
        cloud_hashes: Vec<String>,
        /// asset_exists 探测返回值（None = 探测报错）
        exists_result: Option<Result<bool, String>>,
        /// 上传调用记录
        uploads: std::sync::Mutex<Vec<String>>,
    }

    #[async_trait::async_trait]
    impl SyncAdapter for AttSyncMock {
        async fn list_all_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn download(&self, _: &str) -> Result<bytes::Bytes, crate::sync::error::SyncError> {
            Err(crate::sync::error::SyncError::NotFound {
                message: "无".to_string(),
            })
        }
        async fn upload(&self, _: &str, _: &[u8]) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn delete(&self, _: &str) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn upload_asset(
            &self,
            hash: &str,
            _: Vec<u8>,
        ) -> Result<(), crate::sync::error::SyncError> {
            self.uploads.lock().unwrap().push(hash.to_string());
            Ok(())
        }
        async fn download_asset(
            &self,
            _: &str,
        ) -> Result<bytes::Bytes, crate::sync::error::SyncError> {
            Err(crate::sync::error::SyncError::NotFound {
                message: "无".to_string(),
            })
        }
        async fn asset_exists(&self, _: &str) -> Result<bool, crate::sync::error::SyncError> {
            match &self.exists_result {
                Some(Ok(v)) => Ok(*v),
                Some(Err(m)) => Err(crate::sync::error::SyncError::Network {
                    message: m.clone(),
                    retryable: true,
                }),
                None => Ok(false),
            }
        }
        async fn list_assets(
            &self,
            _assets_dir: &str,
        ) -> Result<Vec<String>, crate::sync::error::SyncError> {
            Ok(self.cloud_hashes.clone())
        }
    }

    /// 构造带迁移内存库 + 两条未上传附件的测试环境
    async fn att_sync_env() -> (
        SqlitePool,
        crate::sync_crypto::SyncCryptoService,
        tempfile::TempDir,
    ) {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        for hash in ["h-first", "h-second"] {
            attachment_repo::upsert(
                &pool,
                &Attachment {
                    hash: hash.to_string(),
                    original_name: hash.to_string(),
                    mime_type: "image/png".to_string(),
                    size_bytes: 4,
                    // 绝对路径指向 tmp 内的缓存文件（生产口径：写入时的绝对路径）
                    local_path: None,
                    is_uploaded: 0,
                    is_local_cached: 1,
                    created_at: 1,
                    last_accessed_at: 1,
                },
            )
            .await
            .unwrap();
        }
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().join("att");
        std::fs::create_dir_all(&dir).unwrap();
        // 本地缓存文件（内容任意，非空即可）
        std::fs::write(dir.join("h-first"), b"data1").unwrap();
        std::fs::write(dir.join("h-second"), b"data2").unwrap();
        let crypto = crate::sync_crypto::SyncCryptoService::new(tmp.path());
        crypto
            .init_with_data_key("pw", &[9u8; 32])
            .expect("注入测试 Data Key");
        (pool, crypto, tmp)
    }

    fn att_dir(tmp: &tempfile::TempDir) -> String {
        tmp.path().join("att").to_string_lossy().to_string()
    }

    /// 场景 ①：云端列表为空 + 探测确认不存在（首台设备首传）→ 必须放行上传
    #[tokio::test]
    async fn empty_cloud_list_allows_first_upload_after_probe_miss() {
        let (pool, crypto, tmp) = att_sync_env().await;
        let adapter = AttSyncMock {
            cloud_hashes: vec![],
            exists_result: Some(Ok(false)),
            uploads: std::sync::Mutex::new(Vec::new()),
        };
        let uploads = &adapter.uploads;

        let r = sync_attachments_push(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir(&tmp),
        )
        .await
        .unwrap();

        assert_eq!(
            r.uploaded, 2,
            "首传场景（探测确认云端无附件）必须放行全部上传，不得死锁"
        );
        assert!(r.errors.is_empty(), "放行路径不应记录错误: {:?}", r.errors);
        assert_eq!(uploads.lock().unwrap().len(), 2, "两个附件都必须实际上传");
    }

    /// 场景 ②：云端列表为空 + 探测发现附件实际存在（列表不可信）→ 防御拦截
    #[tokio::test]
    async fn empty_cloud_list_blocks_when_probe_finds_existing_asset() {
        let (pool, crypto, tmp) = att_sync_env().await;
        let adapter = AttSyncMock {
            cloud_hashes: vec![],
            // h-first 在云端真实存在 → 列表结果不可信
            exists_result: Some(Ok(true)),
            uploads: std::sync::Mutex::new(Vec::new()),
        };
        let uploads = &adapter.uploads;

        let r = sync_attachments_push(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir(&tmp),
        )
        .await
        .unwrap();

        assert_eq!(
            r.uploaded, 0,
            "列表不可信（探测命中）时必须防御性跳过，不得全量风暴"
        );
        assert!(
            !r.errors.is_empty(),
            "拦截路径必须留下可观测错误（S9 口径）"
        );
        assert!(
            uploads.lock().unwrap().is_empty(),
            "拦截时不得有任何上传发生"
        );
    }

    /// 场景 ③：探测本身失败（网络错误）→ 无法区分两态，保守跳过
    #[tokio::test]
    async fn empty_cloud_list_blocks_on_probe_error() {
        let (pool, crypto, tmp) = att_sync_env().await;
        let adapter = AttSyncMock {
            cloud_hashes: vec![],
            exists_result: Some(Err("网络故障".to_string())),
            uploads: std::sync::Mutex::new(Vec::new()),
        };
        let uploads = &adapter.uploads;

        let r = sync_attachments_push(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir(&tmp),
        )
        .await
        .unwrap();

        assert_eq!(r.uploaded, 0, "探测失败时保守跳过本轮");
        assert!(!r.errors.is_empty());
        assert!(uploads.lock().unwrap().is_empty());
    }

    /// 回归：云端列表正常返回且含某 hash → 该附件走修正标记分支不上传
    #[tokio::test]
    async fn cloud_listed_hash_is_marked_without_reupload() {
        let (pool, crypto, tmp) = att_sync_env().await;
        let adapter = AttSyncMock {
            // h-first 已在云端，h-second 待传
            cloud_hashes: vec!["h-first".to_string()],
            exists_result: Some(Ok(true)),
            uploads: std::sync::Mutex::new(Vec::new()),
        };
        let uploads = &adapter.uploads;

        let r = sync_attachments_push(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir(&tmp),
        )
        .await
        .unwrap();

        assert_eq!(r.skipped, 1, "云端已有的 h-first 走修正标记分支");
        assert_eq!(r.uploaded, 1, "仅 h-second 实际上传");
        assert_eq!(uploads.lock().unwrap().as_slice(), ["h-second"]);

        // DB 标记回写：h-first 的 is_uploaded 应已置 1
        let marked = attachment_repo::get_by_hash(&pool, "h-first")
            .await
            .unwrap()
            .expect("行存在");
        assert_eq!(marked.is_uploaded, 1);
    }
    // ========================================================================
    // S31（2026-09-14 审查）：pull 差集的活跃引用过滤 + 占位行真实 size
    //
    // 历史 bug：本端 GC 删除无引用附件后，云端孤儿对象仍在 assets/——
    // pull 朴素差集（云端有 - 本地无）把孤儿拉回 → 插占位行 → 下轮 GC
    // 又删 → 再下轮又拉回，无限循环耗磁盘与流量。
    // 修复后：差集 = 云端有 - 本地无 - 无存活任务引用。
    // ========================================================================

    /// Pull/Push 测试 mock：hash → 密文映射（用真实 encrypt_payload 保证加解密链路）
    ///
    /// `files` 用 `Mutex` 做内部可变：自愈闭环用例要跑一轮真 push，上传结果必须
    /// 写回同一张表（只读 HashMap 会让「重传成功」无从断言）。
    struct PullMockAdapter {
        files: std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>,
    }

    #[async_trait::async_trait]
    impl SyncAdapter for PullMockAdapter {
        async fn list_all_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn download(&self, _: &str) -> Result<bytes::Bytes, crate::sync::error::SyncError> {
            Err(crate::sync::error::SyncError::NotFound {
                message: "无".to_string(),
            })
        }
        async fn upload(&self, _: &str, _: &[u8]) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn delete(&self, _: &str) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn upload_asset(
            &self,
            hash: &str,
            data: Vec<u8>,
        ) -> Result<(), crate::sync::error::SyncError> {
            self.files.lock().unwrap().insert(hash.to_string(), data);
            Ok(())
        }
        async fn download_asset(
            &self,
            hash: &str,
        ) -> Result<bytes::Bytes, crate::sync::error::SyncError> {
            let files = self.files.lock().unwrap();
            match files.get(hash) {
                Some(d) => Ok(bytes::Bytes::from(d.clone())),
                None => Err(crate::sync::error::SyncError::NotFound {
                    message: "无".to_string(),
                }),
            }
        }
        async fn asset_exists(&self, _: &str) -> Result<bool, crate::sync::error::SyncError> {
            Ok(false)
        }
        async fn list_assets(
            &self,
            _assets_dir: &str,
        ) -> Result<Vec<String>, crate::sync::error::SyncError> {
            Ok(self.files.lock().unwrap().keys().cloned().collect())
        }
    }

    /// 构造 pull 环境：空账本（模拟 GC 后/新设备）+ 云端两个附件
    ///（referenced 被任务挂载，orphan 无任何引用）
    ///
    /// 返回 (pool, crypto, tmp, adapter, referenced_hash, orphan_hash)
    async fn pull_env() -> (
        SqlitePool,
        crate::sync_crypto::SyncCryptoService,
        tempfile::TempDir,
        PullMockAdapter,
        String,
        String,
    ) {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        let tmp = tempfile::TempDir::new().unwrap();
        let crypto = crate::sync_crypto::SyncCryptoService::new(tmp.path());
        crypto
            .init_with_data_key("pw", &[9u8; 32])
            .expect("注入测试 Data Key");

        // 云端附件：referenced（8 字节）/ orphan（4 字节），密文走真实加密链路
        let referenced_plain = b"referenced-content".to_vec();
        let orphan_plain = b"orphan".to_vec();
        let hash_r = crate::crypto::sha256::sha256_hex(&referenced_plain);
        let hash_o = crate::crypto::sha256::sha256_hex(&orphan_plain);
        let mut files = std::collections::HashMap::new();
        files.insert(
            hash_r.clone(),
            encrypt_payload(&referenced_plain, &[9u8; 32]).unwrap(),
        );
        files.insert(
            hash_o.clone(),
            encrypt_payload(&orphan_plain, &[9u8; 32]).unwrap(),
        );
        let adapter = PullMockAdapter {
            files: std::sync::Mutex::new(files),
        };

        // 任务 + 关联：仅挂载 referenced
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES ('t1', 'T', 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
             VALUES ('link-1', 1, ?, 0, 1, 1, 1)",
        )
        .bind(&hash_r)
        .execute(&pool)
        .await
        .unwrap();

        (pool, crypto, tmp, adapter, hash_r, hash_o)
    }

    /// 场景 ①：有引用的附件正常拉回，且占位行记录真实 size_bytes
    #[tokio::test]
    async fn pull_downloads_referenced_attachment_with_real_size() {
        let (pool, crypto, tmp, adapter, hash_r, _hash_o) = pull_env().await;
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert_eq!(r.downloaded, 1, "仅被引用的附件被下载");
        let row = attachment_repo::get_by_hash(&pool, &hash_r)
            .await
            .unwrap()
            .expect("占位行必须登记");
        assert_eq!(
            row.size_bytes,
            "referenced-content".len() as i64,
            "占位行 size_bytes 必须是真实字节数（此前恒 0）"
        );
        assert_eq!(row.is_local_cached, 1);
    }

    /// 场景 ②：无引用的云端孤儿不下载（GC ↔ pull 打架循环修复的核心断言）
    #[tokio::test]
    async fn pull_skips_orphan_attachment_without_reference() {
        let (pool, crypto, tmp, adapter, _hash_r, hash_o) = pull_env().await;
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        // 云端另有 orphan：downloaded 只计有引用的 referenced 那一个，
        // orphan 既不下盘也不插占位行（GC ↔ pull 打架循环的回归点）
        assert_eq!(r.downloaded, 1, "下载数只计有引用的附件，孤儿不得计入");
        assert!(!att_dir.join(&hash_o).exists(), "孤儿附件不得落盘");
        assert!(
            attachment_repo::get_by_hash(&pool, &hash_o)
                .await
                .unwrap()
                .is_none(),
            "孤儿附件不得重插占位行（GC 后 pull 不得拉回）"
        );
    }

    /// 场景 ③（回归）：关联行经 pull 合并刚到达时，该轮附件 pull 即可拉回
    ///
    /// 差集过滤依赖的关联表（todo_task_attachments）本身随 todos 模块同步——
    /// 同轮 sync 中模块合并先于附件 pull（sync_now/pull_then_push 顺序），
    /// 新引用先落地再过滤，新设备附件不漏。
    #[tokio::test]
    async fn pull_downloads_attachment_whose_link_arrived_same_round() {
        let (pool, crypto, tmp, adapter, hash_r, _hash_o) = pull_env().await;
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();

        // 再挂一个任务引用到第二个 hash（模拟模块合并刚写入的新关联行）
        sqlx::query(
            "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
             VALUES ('link-2', 1, ?, 0, 1, 1, 1)",
        )
        .bind(&hash_r)
        .execute(&pool)
        .await
        .unwrap();

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert_eq!(r.downloaded, 1);
        assert!(
            attachment_repo::get_by_hash(&pool, &hash_r)
                .await
                .unwrap()
                .is_some()
        );
    }

    /// 场景 ⑤（docs/15 §4.5）：云端对象消失但本地仍有明文 → 置待重传自愈
    ///
    /// 这是云端孤儿清理的必备配套：清理后他端引用复活、或用户误删网盘对象时，
    /// 有明文副本的设备必须能自动把对象传回去，而不是静默缺附件。
    #[tokio::test]
    async fn pull_marks_local_copy_for_reupload_when_cloud_object_missing() {
        let (pool, crypto, tmp, adapter, hash_r, _hash_o) = pull_env().await;
        adapter.files.lock().unwrap().remove(&hash_r); // 云端对象已不存在
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();
        let local_path = att_dir.join(&hash_r);
        std::fs::write(&local_path, b"referenced-content").unwrap();
        sqlx::query(
            "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                          is_uploaded, is_local_cached, created_at, last_accessed_at)
             VALUES (?, 'x', 'application/octet-stream', 18, ?, 1, 1, 1, 1)",
        )
        .bind(&hash_r)
        .bind(local_path.to_string_lossy().to_string())
        .execute(&pool)
        .await
        .unwrap();

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert!(
            r.errors.is_empty(),
            "本地有副本时不应报不可恢复: {:?}",
            r.errors
        );
        let row = attachment_repo::get_by_hash(&pool, &hash_r)
            .await
            .unwrap()
            .expect("账本行仍在");
        assert_eq!(row.is_uploaded, 0, "本地有副本 → 置待重传，下轮 push 自愈");
        assert_eq!(row.is_local_cached, 1);
    }

    /// 场景 ⑥：云端缺失且本地无副本 → 无法自愈，须汇总让 UI 可见
    #[tokio::test]
    async fn pull_reports_unrestorable_when_cloud_and_local_both_missing() {
        let (pool, crypto, tmp, adapter, hash_r, _hash_o) = pull_env().await;
        adapter.files.lock().unwrap().remove(&hash_r);
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();
        sqlx::query(
            "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                          is_uploaded, is_local_cached, created_at, last_accessed_at)
             VALUES (?, 'x', 'application/octet-stream', 18, NULL, 1, 0, 1, 1)",
        )
        .bind(&hash_r)
        .execute(&pool)
        .await
        .unwrap();

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert_eq!(r.errors.len(), 1, "不可恢复场景必须汇总一条错误");
        assert!(
            r.errors[0].contains("无法自动恢复"),
            "错误文案要能让用户定位: {:?}",
            r.errors
        );
        let row = attachment_repo::get_by_hash(&pool, &hash_r)
            .await
            .unwrap()
            .expect("账本行仍在");
        assert_eq!(
            row.is_uploaded, 1,
            "无本地文件不得标待传（push 没有可上传之物，会每轮空转）"
        );
    }

    /// 场景 ⑦（docs/15 §4.5 闭环）：置待传之后，下一轮 push 必须真的把对象传回云端
    ///
    /// 场景 ⑤ 只断言到 `is_uploaded = 0`，那只是「打算重传」；本轮把 push 也跑完，
    /// 断言云端对象回归且键仍是原 hash（内容寻址，其他设备无需改引用）。
    #[tokio::test]
    async fn pull_marked_reupload_restores_cloud_object_on_next_push() {
        let (pool, crypto, tmp, adapter, hash_r, _hash_o) = pull_env().await;
        adapter.files.lock().unwrap().remove(&hash_r);
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();
        let local_path = att_dir.join(&hash_r);
        std::fs::write(&local_path, b"referenced-content").unwrap();
        sqlx::query(
            "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                          is_uploaded, is_local_cached, created_at, last_accessed_at)
             VALUES (?, 'x', 'application/octet-stream', 18, ?, 1, 1, 1, 1)",
        )
        .bind(&hash_r)
        .bind(local_path.to_string_lossy().to_string())
        .execute(&pool)
        .await
        .unwrap();

        // 第一轮 pull：云端缺失 → 置待传
        sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();
        assert_eq!(
            attachment_repo::get_by_hash(&pool, &hash_r)
                .await
                .unwrap()
                .unwrap()
                .is_uploaded,
            0
        );

        // 第二轮 push：真的重传，云端对象回归（hash 不变）
        let pushed = sync_attachments_push_with_limits(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
            AttachmentTransferLimits::default(),
        )
        .await
        .unwrap();
        assert_eq!(pushed.uploaded, 1, "自愈必须真的重传，而不是只改标记");
        assert!(
            adapter.files.lock().unwrap().contains_key(&hash_r),
            "云端对象必须回归，键仍是原 hash（其他设备引用无需改）"
        );
        assert_eq!(
            attachment_repo::get_by_hash(&pool, &hash_r)
                .await
                .unwrap()
                .unwrap()
                .is_uploaded,
            1,
            "上传成功后标记回到已上传"
        );
    }

    /// 场景 ④（N51 回归，2026-10-12）：云端列出格式非法的 hash（内容寻址
    /// 假设被破坏/对端数据被篡改的形态），即便有活跃引用也不得进入下载与
    /// 落盘路径——单件记错不阻塞本轮，正常附件照常拉回。
    #[tokio::test]
    async fn pull_rejects_malformed_hash_before_download() {
        let (pool, crypto, tmp, adapter, _hash_r, _hash_o) = pull_env().await;
        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();

        // 挂一个格式非法 hash 的引用（路径分隔符注入形态），使其通过活跃引用过滤
        sqlx::query(
            "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
             VALUES ('link-bad', 1, ?, 0, 1, 1, 1)",
        )
        .bind("../../etc/passwd")
        .execute(&pool)
        .await
        .unwrap();

        // 云端列表也列出该非法 hash（对端数据被篡改/内容寻址假设被破坏的形态）：
        // 差集过滤只看「云端有 - 本地无 - 有引用」，非法值能走到下载步才有拦截意义
        adapter
            .files
            .lock()
            .unwrap()
            .insert("../../etc/passwd".to_string(), b"whatever".to_vec());

        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert_eq!(r.downloaded, 1, "仅合法 hash 的 referenced 被下载");
        assert!(
            r.errors.iter().any(|e| e.contains("格式非法")),
            "非法 hash 应记错，实际 errors: {:?}",
            r.errors
        );
        assert!(
            attachment_repo::get_by_hash(&pool, "../../etc/passwd")
                .await
                .unwrap()
                .is_none(),
            "非法 hash 不得插占位行"
        );
    }

    // ========================================================================
    // M3/T1.1：流式上传（OSAC 容器）与 OSAC 拉回
    // ========================================================================

    /// 流式上传 mock：从临时文件按块读取容器字节并记录，证明 push 走的是
    /// `upload_asset_file` 而不是「整包 `upload_asset`」。
    struct StreamingPushMock {
        uploaded: std::sync::Mutex<Vec<(String, Vec<u8>)>>,
    }

    #[async_trait::async_trait]
    impl SyncAdapter for StreamingPushMock {
        async fn list_all_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn download(&self, _: &str) -> Result<bytes::Bytes, crate::sync::error::SyncError> {
            Err(crate::sync::error::SyncError::NotFound {
                message: "无".to_string(),
            })
        }
        async fn upload(&self, _: &str, _: &[u8]) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn delete(&self, _: &str) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn upload_asset(
            &self,
            _: &str,
            _: Vec<u8>,
        ) -> Result<(), crate::sync::error::SyncError> {
            panic!("M3 后 push 不得走整包 upload_asset");
        }
        async fn upload_asset_file(
            &self,
            hash: &str,
            local_path: &std::path::Path,
            total_len: u64,
        ) -> Result<(), crate::sync::error::SyncError> {
            let bytes = tokio::fs::read(local_path).await.unwrap();
            assert_eq!(bytes.len() as u64, total_len, "声明长度必须与容器一致");
            self.uploaded
                .lock()
                .unwrap()
                .push((hash.to_string(), bytes));
            Ok(())
        }
        async fn asset_exists(&self, _: &str) -> Result<bool, crate::sync::error::SyncError> {
            Ok(false)
        }
        async fn list_assets(&self, _: &str) -> Result<Vec<String>, crate::sync::error::SyncError> {
            // 非空列表 + 探测 404 → 视为「本机其余附件已上传」，只上传待传项
            Ok(vec!["already-uploaded-other-hash".to_string()])
        }
    }

    #[tokio::test]
    async fn push_uploads_osac_container_via_streaming_entrypoint() {
        let (pool, crypto, tmp) = att_sync_env().await;
        let adapter = StreamingPushMock {
            uploaded: std::sync::Mutex::new(Vec::new()),
        };
        let uploaded = &adapter.uploaded;

        let r = sync_attachments_push(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir(&tmp),
        )
        .await
        .unwrap();
        assert_eq!(r.uploaded, 2);
        assert!(r.errors.is_empty(), "errors: {:?}", r.errors);

        let uploaded = uploaded.lock().unwrap();
        assert_eq!(uploaded.len(), 2);
        for (hash, bytes) in uploaded.iter() {
            assert!(
                asset_container::is_container(bytes),
                "云端对象必须是 OSAC 分块容器（hash={hash}）"
            );
            let plain = if hash == "h-first" {
                b"data1".to_vec()
            } else {
                b"data2".to_vec()
            };
            let dir = tempfile::TempDir::new().unwrap();
            let container = dir.path().join("c.bin");
            let out = dir.path().join("out.bin");
            std::fs::write(&container, bytes).unwrap();
            // 测试账本的 hash 是假值（h-first），但容器内容是真明文——
            // 校验用明文 sha256（生产口径：hash 即明文 hash）
            let expect_hash = crate::crypto::sha256::sha256_hex(&plain);
            let n = asset_container::decrypt_container_to_file(
                &container,
                &out,
                crypto.get_data_key().as_deref().unwrap(),
                &expect_hash,
            )
            .unwrap();
            assert_eq!(n as usize, plain.len());
            assert_eq!(std::fs::read(&out).unwrap(), plain, "容器必须可还原明文");
        }

        // 临时容器文件不得残留
        let leftovers: Vec<_> = std::fs::read_dir(att_dir(&tmp))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "上传临时容器必须清理");
    }

    #[tokio::test]
    async fn pull_decrypts_osac_container_written_by_push() {
        let tmp = tempfile::TempDir::new().unwrap();
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        let crypto = crate::sync_crypto::SyncCryptoService::new(tmp.path());
        crypto.init_with_data_key("pw", &[9u8; 32]).unwrap();

        // 明文跨帧（4MiB + 17B），覆盖多帧解密与末尾哈希校验
        let plain = vec![0xA5u8; asset_container::CHUNK_PLAIN_BYTES + 17];
        let hash = crate::crypto::sha256::sha256_hex(&plain);
        let src = tmp.path().join("src.bin");
        std::fs::write(&src, &plain).unwrap();
        let container = tmp.path().join("container.bin");
        asset_container::encrypt_file_to_container(
            &src,
            &container,
            crypto.get_data_key().as_deref().unwrap(),
            &hash,
        )
        .unwrap();

        let mut files = std::collections::HashMap::new();
        files.insert(hash.clone(), std::fs::read(&container).unwrap());
        let adapter = PullMockAdapter {
            files: std::sync::Mutex::new(files),
        };

        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES ('t1', 'T', 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
             VALUES ('link-1', 1, ?, 0, 1, 1, 1)",
        )
        .bind(&hash)
        .execute(&pool)
        .await
        .unwrap();

        let att_dir = tmp.path().join("att");
        std::fs::create_dir_all(&att_dir).unwrap();
        let r = sync_attachments_pull(
            &pool,
            &crypto,
            &adapter,
            &crate::cloud_sync::progress::NoopProgressSender,
            crate::cloud_sync::progress::SyncOrigin::Manual,
            &att_dir.to_string_lossy(),
        )
        .await
        .unwrap();

        assert_eq!(r.downloaded, 1);
        assert!(r.errors.is_empty(), "errors: {:?}", r.errors);
        assert_eq!(
            std::fs::read(att_dir.join(&hash)).unwrap(),
            plain,
            "OSAC 容器必须流式解密为原始明文"
        );
        let total = attachment_repo::cached_total_bytes(&pool).await.unwrap();
        assert_eq!(total, plain.len() as i64, "账本 size 必须是明文长度");
    }
}
