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
    if cloud_hashes.is_empty() {
        result.errors.push(
            "云端附件列表为空但本地存在未上传附件，疑似探测异常，本轮跳过附件上传".to_string(),
        );
        return Ok(result);
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

    // 3. 差集 = 云端有 - 本地有
    let to_download: Vec<String> = cloud_hashes
        .iter()
        .filter(|h| !local_set.contains(*h))
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
    let outcomes: Vec<(String, Result<String, String>)> = stream::iter(to_download)
        .map(|hash| {
            let data_key = &data_key;
            let done_counter = &done_counter;
            async move {
                let outcome: Result<String, String> = async {
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

                    Ok(file_path.to_string_lossy().to_string())
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

                (hash, outcome)
            }
        })
        .buffer_unordered(4)
        .collect()
        .await;

    // 6. 汇总结果 + 更新 sys_attachments 记录（串行落库）
    for (hash, outcome) in outcomes {
        match outcome {
            Ok(local_path) => {
                // P0-8：ensure 而非 mark——sys_attachments 不在同步白名单，
                // 新设备/删库后本地无记录，仅 UPDATE 会永远 affected=0，
                // 差集永不为空导致每轮全量重下
                let _ = attachment_repo::ensure_local_cached(db_pool, &hash, &local_path).await;
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

    #[test]
    fn attachment_sync_result_default_is_zero() {
        let r = AttachmentSyncResult::default();
        assert_eq!(r.uploaded, 0);
        assert_eq!(r.downloaded, 0);
        assert_eq!(r.skipped, 0);
        assert!(r.errors.is_empty());
    }
}
