//! attachments — 附件同步（内容寻址 + 全加密）
//!
//! 附件以 sha256 hash 为云端文件名，用 Data Key AES-256-GCM 加密后上传。
//! Push 上传本地有但云端无的附件，Pull 下载云端有但本地无的附件。
//!
//! ## 同步策略
//! - **Push**：查询 `sys_attachments WHERE is_local_cached = 1 AND is_uploaded = 0`，
//!   读取本地文件 → 加密 → `adapter.upload_asset(hash, encrypted)` → 标记 `is_uploaded = 1`
//! - **Pull**：列出云端附件 → 对比本地 `sys_attachments` → 下载缺失附件 → 解密 →
//!   保存到本地文件 → 更新 `is_local_cached = 1`
//!
//! ## 并发控制
//! 使用 `futures::stream::buffer_unordered(4)` 限制并发上传/下载数为 4，避免压满网络。
//! `SyncAdapter: Send + Sync`，共享引用可跨并发 future 借用，无需 spawn + 'static，
//! 读取/加密/上传（下载/解密/落盘）全流程按附件并行。
//!
//! ## 错误隔离
//! 单个附件上传/下载失败不阻塞其他附件，错误收集到返回值。

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

use futures::stream::{self, StreamExt};
use sqlx::SqlitePool;

use crate::cloud_sync::crypto_io::{decrypt_payload, encrypt_payload};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::progress::{ProgressSender, SyncOrigin, SyncProgress};
use crate::db::repository::attachment_repo;
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

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

/// 常数时间字符串比较（长度不等时按较长串比较，避免提前返回泄露前缀信息）
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let max = a.len().max(b.len());
    let mut diff: u8 = (a.len() ^ b.len()) as u8;
    for i in 0..max {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        diff |= x ^ y;
    }
    diff == 0
}

/// 抽取本地未上传附件中的首个 hash（空列表防御的探针）
///
/// 返回 None 表示列表为空（调用方已提前 return，此分支不可达，防御性处理）。
fn to_upload_probe(unuploaded: &[crate::models::business::Attachment]) -> Option<&str> {
    unuploaded.first().map(|a| a.hash.as_str())
}

/// Push 附件：上传本地有但云端无的附件
///
/// `attachments_dir` 是本地附件文件目录（与 `asset_api::write_local_file` 使用同一目录）。
/// `origin` 标识事件来源（Background/Manual/Exit），用于 UI 层过滤重复显示。
pub async fn sync_attachments_push(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    attachments_dir: &str,
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
    let cloud_hashes: HashSet<String> = match adapter.list_assets().await {
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

    // 4. 并发上传（NFR-5.5：4 路并发）
    //
    // `buffer_unordered(4)` 在当前 task 内并发驱动至多 4 个 future，
    // future 仅借用 `adapter`/`data_key` 等共享引用（SyncAdapter: Send + Sync），
    // 无需 tokio::spawn 的 'static 约束。读取/加密/上传全流程并行。
    let outcomes: Vec<(String, Result<(), String>)> = stream::iter(to_upload)
        .map(|attachment| {
            let data_key = &data_key;
            let done_counter = &done_counter;
            async move {
                let hash = attachment.hash.clone();
                let local_path = attachment.local_path.clone().unwrap_or_default();

                // 4a. 读取本地文件
                let file_data = if local_path.is_empty() {
                    // local_path 为空时从 attachments_dir 读取
                    let path = Path::new(attachments_dir).join(&hash);
                    tokio::fs::read(&path).await.unwrap_or_default()
                } else {
                    tokio::fs::read(&local_path).await.unwrap_or_default()
                };

                if file_data.is_empty() {
                    return (hash, Err(format!("本地文件为空或不存在: {}", local_path)));
                }

                // 4b. 加密
                let encrypted = match encrypt_payload(&file_data, data_key) {
                    Ok(enc) => enc,
                    Err(e) => return (hash, Err(format!("加密失败: {}", e))),
                };

                // 4c. 上传
                let outcome = match adapter.upload_asset(&hash, &encrypted).await {
                    Ok(()) => Ok(()),
                    Err(e) => Err(format!("上传附件 {} 失败: {}", hash, e)),
                };

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
        .buffer_unordered(4)
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

/// Pull 附件：下载云端有但本地无的附件
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
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    let mut result = AttachmentSyncResult::default();

    // 1. 列出云端附件
    // Fix-13：list 失败不得静默视为"云端无附件"（那会静默跳过全部下载且无感知），
    // 记入 errors 让 UI 可见，下次同步重试。
    let cloud_hashes: Vec<String> = match adapter.list_assets().await {
        Ok(list) => list,
        Err(e) => {
            result
                .errors
                .push(format!("列出云端附件失败，本轮跳过附件下载: {}", e));
            return Ok(result);
        }
    };
    if cloud_hashes.is_empty() {
        return Ok(result);
    }

    // 2. 查询本地已缓存的附件 hash 集合
    let local_cached = attachment_repo::get_all_local_cached(db_pool)
        .await
        .map_err(|e| CloudSyncError::Database {
            message: format!("查询本地缓存附件失败: {}", e),
        })?;
    let local_set: HashSet<String> = local_cached.into_iter().map(|a| a.hash).collect();

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

    // 3. 差集 = 云端有 - 本地有 - 无引用
    let to_download: Vec<String> = cloud_hashes
        .iter()
        .filter(|h| !local_set.contains(*h) && active_refs.contains(*h))
        .cloned()
        .collect();

    if to_download.is_empty() {
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

    // 5. 并发下载（NFR-5.5：4 路并发）
    // 下载/解密/落盘全流程并行，DB 标记回主流程串行执行。
    let outcomes: Vec<(String, Result<(String, i64), String>, i64)> = stream::iter(to_download)
        .map(|hash| {
            let data_key = &data_key;
            let done_counter = &done_counter;
            async move {
                // 返回 (本地路径, 实际字节数)——size 供占位行登记（S31 修正）
                let outcome: Result<(String, i64), String> = async {
                    // 5a. 下载
                    let encrypted = adapter
                        .download_asset(&hash)
                        .await
                        .map_err(|e| format!("下载附件 {} 失败: {}", hash, e))?;

                    // 5b. 解密
                    let decrypted = decrypt_payload(&encrypted, data_key)
                        .map_err(|e| format!("解密附件 {} 失败: {}", hash, e))?;

                    // 5c. 校验内容哈希与文件名（即 sha256）一致
                    // 文件名即 hash 是内容寻址约定：损坏/被篡改的内容会被"哈希背书"，
                    // 后续所有按 hash 取文件的场景（含上传去重）都建立在内容与名字
                    // 一致的假设上，这里在落盘前校验，不一致视为损坏直接失败。
                    let actual = crate::crypto::sha256::sha256_hex(&decrypted);
                    if !constant_time_eq(&actual, hash.as_str()) {
                        return Err(format!(
                            "附件 {} 内容哈希校验失败（实际 {}），疑似传输损坏，已丢弃",
                            hash, actual
                        ));
                    }

                    // 5d. 原子落盘（P0-8）
                    // 下载中途崩溃留半截文件会被后续同步当作"已缓存"（文件名即 hash，
                    // 内容寻址天然幂等），损坏内容无法自愈。tmp+rename 保证要么完整
                    // 写入、要么不存在，与 orbit-core 其他落盘路径（fs_util::write_atomic）
                    // 同口径；附件目录无 fs_util 依赖，此处内联实现等价逻辑。
                    let file_path = Path::new(attachments_dir).join(&hash);
                    let tmp_path = Path::new(attachments_dir).join(format!(
                        "{}.tmp-{}",
                        hash,
                        std::process::id()
                    ));
                    tokio::fs::write(&tmp_path, &decrypted)
                        .await
                        .map_err(|e| format!("保存附件 {} 失败: {}", hash, e))?;
                    // Windows 上目标已存在时 rename 失败，先删目标再重命名
                    if tokio::fs::rename(&tmp_path, &file_path).await.is_err() {
                        tokio::fs::remove_file(&file_path).await.ok();
                        tokio::fs::rename(&tmp_path, &file_path)
                            .await
                            .map_err(|e| format!("附件 {} 原子落盘失败: {}", hash, e))?;
                    }

                    Ok((
                        file_path.to_string_lossy().to_string(),
                        decrypted.len() as i64,
                    ))
                }
                .await;

                // 5e. 按完成序发送进度
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
        .buffer_unordered(4)
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
        async fn list_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn list_all_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn download(&self, _: &str) -> Result<Vec<u8>, crate::sync::error::SyncError> {
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
            _: &[u8],
        ) -> Result<(), crate::sync::error::SyncError> {
            self.uploads.lock().unwrap().push(hash.to_string());
            Ok(())
        }
        async fn download_asset(&self, _: &str) -> Result<Vec<u8>, crate::sync::error::SyncError> {
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
        async fn list_assets(&self) -> Result<Vec<String>, crate::sync::error::SyncError> {
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

    /// Pull 测试 mock：hash → 密文映射（用真实 encrypt_payload 保证解密链路）
    struct PullMockAdapter {
        files: std::collections::HashMap<String, Vec<u8>>,
    }

    #[async_trait::async_trait]
    impl SyncAdapter for PullMockAdapter {
        async fn list_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn list_all_files(
            &self,
            _: &str,
        ) -> Result<Vec<crate::sync_adapters::traits::RemoteFile>, crate::sync::error::SyncError>
        {
            Ok(Vec::new())
        }
        async fn download(&self, _: &str) -> Result<Vec<u8>, crate::sync::error::SyncError> {
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
            _: &[u8],
        ) -> Result<(), crate::sync::error::SyncError> {
            Ok(())
        }
        async fn download_asset(
            &self,
            hash: &str,
        ) -> Result<Vec<u8>, crate::sync::error::SyncError> {
            match self.files.get(hash) {
                Some(d) => Ok(d.clone()),
                None => Err(crate::sync::error::SyncError::NotFound {
                    message: "无".to_string(),
                }),
            }
        }
        async fn asset_exists(&self, _: &str) -> Result<bool, crate::sync::error::SyncError> {
            Ok(false)
        }
        async fn list_assets(&self) -> Result<Vec<String>, crate::sync::error::SyncError> {
            Ok(self.files.keys().cloned().collect())
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
        let adapter = PullMockAdapter { files };

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

        // orphan 未被下载（downloaded 只计 referenced），也不产生占位行
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
}
