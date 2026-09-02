//! pull — 模块级增量下载与合并流程
//!
//! 从云端拉取模块数据，按指纹增量下载变化的模块，并交给 merge 模块做 item 级合并。
//! 所有云端文件均用 Data Key AES-256-GCM 解密。
//!
//! ## Pull 流程
//! 1. 加载本地同步状态
//! 2. 获取已解锁的 Data Key
//! 3. 下载并解密 `_meta.waitsync`
//! 4. 遍历远端模块元数据：
//!    - 与本地记录的 remote_fp 比对，相同则跳过
//!    - 变化则下载 `data.waitsync` + `meta.waitsync`，解密
//!    - 调用 merge_items 做 item 级 LWW 合并
//!    - 更新本地状态
//! 5. 附件同步（调用 attachments 模块，M1.11 实现）
//!
//! ## 错误隔离
//! 单个模块下载/合并失败不阻塞其他模块，错误收集到 `errors` 列表。

use sqlx::SqlitePool;

use crate::cloud_sync::crypto_io::decrypt_payload;
use crate::cloud_sync::db_loader::{load_module_items, now_ms};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::{GlobalMeta, ModuleData, ModuleMetaEntry};
use crate::cloud_sync::modules::{SYNC_MODULES, SyncModuleDef};
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{ProgressBuilder, ProgressSender, SyncOrigin};
use crate::cloud_sync::state::{ModuleSyncState, SyncStateStore};
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

/// Pull 执行结果
#[derive(Debug, Clone, Default)]
pub struct PullResult {
    /// 实际拉取的模块数（远端指纹变化的模块）
    pub pulled_modules: u32,
    /// 跳过的模块数
    pub skipped_modules: u32,
    /// 收集的错误（不阻塞整体流程）
    pub errors: Vec<String>,
}

/// 单个模块 Pull 任务的结果（用于并行任务返回，主流程顺序应用 state）
enum PullModuleOutcome {
    /// 指纹未变，跳过
    Skipped,
    /// 远端无此模块数据（404），更新 remote_fp 避免重复尝试
    RemoteEmpty {
        name: String,
        new_state: ModuleSyncState,
    },
    /// 成功拉取并合并
    Pulled {
        name: String,
        new_state: ModuleSyncState,
        changed_records: u64,
    },
    /// 单模块错误（不阻塞整体流程，收集到 errors）
    Failed(String),
}

/// 执行全量 Pull：从云端拉取模块数据并合并
///
/// `origin` 标识事件来源（Background/Manual/Exit），用于 UI 层过滤重复显示。
///
/// ## 性能优化（2026-07-25 P0）
/// - 模块级并行：15 个模块通过 `buffer_unordered(8)` 并发下载与合并
/// - 批量 state 保存：循环结束后一次性写入 `sync_state.json`
/// - 错误隔离：单模块失败返回 `Failed` outcome，不阻塞其他模块
pub async fn pull_all(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
) -> Result<PullResult, CloudSyncError> {
    let mut state = state_store.load()?;
    let data_key = crypto.get_data_key().ok_or_else(|| {
        // 诊断日志：Data Key 为 None，说明 crypto 实例未 unlock
        // 这通常意味着 sync_crypto_unlock 未被调用，或 unlock 后 Data Key 被清除
        log::info!("[pull_all] Data Key 为 None：crypto 实例未解锁，返回 CryptoLocked");
        CloudSyncError::CryptoLocked
    })?;
    log::info!(
        "[pull_all] 获取 Data Key 成功，指纹: {}",
        crate::cloud_sync::engine::data_key_fingerprint(&data_key)
    );

    // 1. 下载并解密 _meta.waitsync
    //    首次同步时远端尚无 _meta.waitsync（404），降级为空的全局元数据，
    //    允许首次同步继续执行（Push 已上传本地数据，Pull 无远端变更可合并）。
    let global_meta = match adapter.download(paths::GLOBAL_META_PATH).await {
        Ok(meta_bytes) => {
            let decrypted_meta = decrypt_payload(&meta_bytes, &data_key)?;
            serde_json::from_slice::<GlobalMeta>(&decrypted_meta)?
        }
        Err(e) => {
            // 404 视为空远端（首次同步），其他错误向上传播
            if paths::is_not_found_error(&e) {
                // device_id 此处仅用于诊断，空串即可
                GlobalMeta::empty("")
            } else {
                return Err(CloudSyncError::RemoteMissing(format!(
                    "下载 {} 失败: {}",
                    paths::GLOBAL_META_PATH,
                    e
                )));
            }
        }
    };

    let builder = ProgressBuilder::new(progress_sender, origin);
    let total = global_meta.modules.len() as u32;
    builder.starting(total);

    // 预捕获所有模块的 local_state，避免并行任务借用 state
    // 元组：(模块名, 远端指纹, 远端 updated_at, 本地 state, 模块定义)
    // 使用 owned String 避免引用 global_meta 的生命周期问题
    type ModuleEntry = (
        String,
        String,
        i64,
        Option<ModuleSyncState>,
        Option<&'static SyncModuleDef>,
    );
    let module_entries: Vec<ModuleEntry> = global_meta
        .modules
        .iter()
        .map(|(name, remote_meta)| {
            let module_def = SYNC_MODULES.iter().find(|m| m.name == name.as_str());
            let local_state = state.modules.get(name).cloned();
            (
                name.clone(),
                remote_meta.fp.clone(),
                remote_meta.updated_at,
                local_state,
                module_def,
            )
        })
        .collect();

    // 串行 Pull：每个模块独立完成 下载→解密→合并→返回新状态，
    // 不修改全局 state，由主流程在所有任务完成后顺序应用。
    // 注：原 buffer_unordered 并行实现在 Tauri 命令上下文中触发
    // `&dyn ProgressSender` 的 Send 约束 HRTB 推断失败，回退为串行。
    let mut outcomes: Vec<PullModuleOutcome> = Vec::with_capacity(module_entries.len());
    for (idx, (name, remote_fp, remote_updated_at, local_state, module_def)) in
        module_entries.into_iter().enumerate()
    {
        let current = idx as u32 + 1;
        // 未知模块：直接返回 Failed（不阻塞其他模块）
        let outcome = match module_def {
            None => PullModuleOutcome::Failed(format!("未知模块: {}", name)),
            Some(module_def) => {
                pull_single_module(
                    db_pool,
                    &data_key,
                    adapter,
                    progress_sender,
                    origin,
                    module_def,
                    &name,
                    &remote_fp,
                    remote_updated_at,
                    local_state,
                    current,
                    total,
                )
                .await
            }
        };
        outcomes.push(outcome);
    }

    // 顺序应用 outcomes 到 state 和 result
    let mut result = PullResult::default();
    let mut changed_records = 0;
    for outcome in outcomes {
        match outcome {
            PullModuleOutcome::Skipped => result.skipped_modules += 1,
            PullModuleOutcome::RemoteEmpty { name, new_state } => {
                state.set_module(&name, new_state);
                result.skipped_modules += 1;
            }
            PullModuleOutcome::Pulled {
                name,
                new_state,
                changed_records: module_changed_records,
            } => {
                state.set_module(&name, new_state);
                result.pulled_modules += 1;
                changed_records += module_changed_records;
            }
            PullModuleOutcome::Failed(msg) => {
                result.errors.push(msg);
            }
        }
    }

    if changed_records > 0 {
        builder.local_data_applied(changed_records);
    }

    // 批量保存 state（循环结束后一次性写入，避免每模块都写文件）
    state.last_synced_at = now_ms();
    state_store.save(&state)?;

    Ok(result)
}

/// 处理单个模块的 Pull（并行任务单元）
///
/// 独立完成：指纹比对 → 下载数据与墓碑 → 解密 → 合并 → 返回新状态。
/// 单模块失败返回 `Failed` outcome，不阻塞其他模块。
#[allow(clippy::too_many_arguments)] // 单模块拉取管道参数，聚合进结构体收益低
async fn pull_single_module(
    db_pool: &SqlitePool,
    data_key: &[u8],
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    module_def: &SyncModuleDef,
    module_name: &str,
    remote_fp: &str,
    remote_updated_at: i64,
    local_state: Option<ModuleSyncState>,
    current: u32,
    total: u32,
) -> PullModuleOutcome {
    let builder = ProgressBuilder::new(progress_sender, origin);
    builder.pulling(module_name, module_def.display_name, current, total);

    // 1. 比对指纹：远端 fp == 本地记录的 remote_fp → 跳过
    if local_state
        .as_ref()
        .is_some_and(|s| s.remote_fp == remote_fp && !s.remote_fp.is_empty())
    {
        return PullModuleOutcome::Skipped;
    }

    // 2. 下载并解密 data.waitsync
    //    404 降级：远端无此模块数据 → 更新 remote_fp 避免重复尝试，视为跳过
    let data_path = paths::module_data_path(module_name);
    let data_bytes = match adapter.download(&data_path).await {
        Ok(bytes) => bytes,
        Err(e) => {
            if paths::is_not_found_error(&e) {
                // 远端无此模块数据，更新 remote_fp 避免重复尝试
                let fp = local_state.as_ref().map_or(String::new(), |s| s.fp.clone());
                let new_state = ModuleSyncState {
                    fp,
                    remote_fp: remote_fp.to_string(),
                    count: local_state.as_ref().map_or(0, |s| s.count),
                    pulled_at: now_ms(),
                    pushed_at: local_state.as_ref().map_or(0, |s| s.pushed_at),
                };
                return PullModuleOutcome::RemoteEmpty {
                    name: module_name.to_string(),
                    new_state,
                };
            }
            return PullModuleOutcome::Failed(format!("下载 {} 失败: {}", data_path, e));
        }
    };

    let decrypted_data = match decrypt_payload(&data_bytes, data_key) {
        Ok(d) => d,
        Err(e) => {
            return PullModuleOutcome::Failed(format!("解密 {} 失败: {}", data_path, e));
        }
    };
    let module_data: ModuleData = match serde_json::from_slice(&decrypted_data) {
        Ok(d) => d,
        Err(e) => {
            return PullModuleOutcome::Failed(format!("解析 {} 失败: {}", data_path, e));
        }
    };

    // 3. 下载并解密 meta.waitsync（获取墓碑集）
    //
    // Fix-05 区分三种情况：
    // - 成功：正常携带墓碑集合并；
    // - 404（NotFound）：旧版本数据可能没有 meta 文件 → 以空墓碑降级继续（兼容），
    //   记录 info 日志便于诊断"远端删除未传播"类问题；
    // - 其他错误（解密失败 = Data Key 不一致 / 网络故障）：**整体跳过该模块合并**
    //   并返回 Failed。历史问题：旧实现一律静默降级为空墓碑继续合并，
    //   导致远端删除永远无法传播到本地、本地已删记录被复活后又随 push 回传覆盖云端，
    //   且用户全程无感知。在 merge 之前返回 Failed 可避免"半合并"状态
    //   （数据更新了但删除丢失）。上层 with_retry 会对网络类错误自动重试。
    let meta_path = paths::module_meta_path(module_name);
    let module_meta: ModuleMetaEntry =
        match download_and_decrypt_meta(adapter, &meta_path, data_key).await {
            Ok(m) => m,
            Err(e @ CloudSyncError::NotFound { .. }) => {
                log::info!(
                    "[pull] {} 不存在（404，旧格式数据），以空墓碑集继续合并",
                    meta_path
                );
                let _ = e;
                ModuleMetaEntry {
                    fp: remote_fp.to_string(),
                    count: module_data.items.len() as u64,
                    deleted_ids: Vec::new(),
                    updated_at: remote_updated_at,
                }
            }
            Err(e) => {
                return PullModuleOutcome::Failed(format!(
                    "获取 {} 失败（解密或网络错误），已跳过该模块合并以防删除丢失: {}",
                    meta_path, e
                ));
            }
        };

    // 4. item 级合并（调用 merge 模块）
    let merge_result = crate::cloud_sync::merge::merge_items(
        db_pool,
        module_def,
        &module_data.items,
        &module_meta.deleted_ids,
    )
    .await;

    let changed_records = match merge_result {
        Ok(merge) => {
            builder.merging(
                module_name,
                module_def.display_name,
                merge.inserted,
                merge.updated,
                merge.deleted,
            );
            merge.inserted + merge.updated + merge.deleted
        }
        Err(e) => {
            return PullModuleOutcome::Failed(format!("合并 {} 失败: {}", module_name, e));
        }
    };

    // 5. 合并后重新计算本地指纹（反映合并后的数据状态）
    let refreshed_items = match load_module_items(db_pool, module_def).await {
        Ok(items) => items,
        Err(e) => {
            if changed_records > 0 {
                builder.local_data_applied(changed_records);
            }
            return PullModuleOutcome::Failed(format!(
                "合并后重新加载 {} 失败: {}",
                module_name, e
            ));
        }
    };
    let local_fp = match crate::cloud_sync::compute_fingerprint(&refreshed_items) {
        Ok(fp) => fp,
        Err(e) => {
            if changed_records > 0 {
                builder.local_data_applied(changed_records);
            }
            return PullModuleOutcome::Failed(format!(
                "合并后计算 {} 指纹失败: {}",
                module_name, e
            ));
        }
    };

    let new_state = ModuleSyncState {
        fp: local_fp,
        remote_fp: remote_fp.to_string(),
        count: refreshed_items.len() as u64,
        pulled_at: now_ms(),
        pushed_at: local_state.as_ref().map_or(0, |s| s.pushed_at),
    };

    PullModuleOutcome::Pulled {
        name: module_name.to_string(),
        new_state,
        changed_records,
    }
}

/// 下载并解密模块 meta.waitsync
async fn download_and_decrypt_meta(
    adapter: &dyn SyncAdapter,
    path: &str,
    data_key: &[u8],
) -> Result<ModuleMetaEntry, CloudSyncError> {
    let bytes = adapter.download(path).await.map_err(CloudSyncError::from)?;
    let decrypted = decrypt_payload(&bytes, data_key)?;
    let meta: ModuleMetaEntry = serde_json::from_slice(&decrypted)?;
    Ok(meta)
}

/// 下载单个附件（供 attachments 模块调用）
///
/// 下载后用 Data Key 解密返回明文。
pub async fn download_attachment(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    hash: &str,
) -> Result<Vec<u8>, CloudSyncError> {
    let encrypted = adapter.download_asset(hash).await?;
    let decrypted = decrypt_payload(&encrypted, data_key)?;
    Ok(decrypted)
}
