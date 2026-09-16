//! pull — 模块级增量下载与合并流程
//!
//! 从云端拉取模块数据，按指纹增量下载变化的模块，并交给 merge 模块做 item 级合并。
//! 所有云端文件均用 Data Key AES-256-GCM 解密。
//!
//! ## Pull 流程
//! 1. 加载本地同步状态
//! 2. 获取已解锁的 Data Key
//! 3. 下载并解密 `_meta.orsync`（兼容遗留 `_meta.waitsync`）
//! 4. 遍历远端模块元数据：
//!    - 与本地记录的 remote_fp 比对，相同则跳过
//!    - 变化则下载 `data.orsync` + `meta.orsync`（兼容遗留 `.waitsync`），解密
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
    /// 冲突裁决数合计（S28：merge LWW/复活裁决计数透传，此前恒 0 不可见）
    pub conflicts: u64,
    /// 收集的错误（不阻塞整体流程）
    pub errors: Vec<String>,
    /// 本轮 Pull 失败的模块名集合（P0-6）
    ///
    /// pull 失败的模块本地数据仍是旧快照，若不传给 push 侧跳过，
    /// reconcile 会发现 fp 不一致并用陈旧数据重传覆盖云端新数据
    /// （设备 B 刚推的新数据被设备 A 的旧数据覆盖，B 若不再同步则永久丢失）。
    pub failed_modules: Vec<String>,
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
        /// 该模块 merge 的冲突裁决数（S28 透传）
        conflicts: u64,
    },
    /// 单模块错误（不阻塞整体流程，收集到 errors；module 供 push 侧跳过，P0-6）
    Failed { module: String, message: String },
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

    // 1. 下载并解密 _meta（默认 .orsync，404 回退遗留 .waitsync）
    //    首次同步时远端尚无 _meta（404），降级为空的全局元数据，
    //    允许首次同步继续执行（Push 已上传本地数据，Pull 无远端变更可合并）。
    let meta_bytes_opt = match adapter.download(paths::GLOBAL_META_PATH).await {
        Ok(b) => Some(b),
        Err(e) if paths::is_not_found_error(&e) => {
            match adapter.download(paths::LEGACY_GLOBAL_META_PATH).await {
                Ok(b) => Some(b),
                Err(e2) if paths::is_not_found_error(&e2) => None,
                Err(e2) => {
                    return Err(CloudSyncError::RemoteMissing(format!(
                        "下载 {} 失败: {}",
                        paths::LEGACY_GLOBAL_META_PATH,
                        e2
                    )));
                }
            }
        }
        Err(e) => {
            return Err(CloudSyncError::RemoteMissing(format!(
                "下载 {} 失败: {}",
                paths::GLOBAL_META_PATH,
                e
            )));
        }
    };
    let global_meta = match meta_bytes_opt {
        Some(meta_bytes) => {
            let decrypted_meta = decrypt_payload(&meta_bytes, &data_key)?;
            serde_json::from_slice::<GlobalMeta>(&decrypted_meta)?
        }
        None => GlobalMeta::empty(""),
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
            None => PullModuleOutcome::Failed {
                module: name.clone(),
                message: format!("未知模块: {}", name),
            },
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
                conflicts: module_conflicts,
            } => {
                state.set_module(&name, new_state);
                result.pulled_modules += 1;
                changed_records += module_changed_records;
                result.conflicts += module_conflicts;
            }
            PullModuleOutcome::Failed { module, message } => {
                result.errors.push(message);
                // P0-6：失败模块名随 PullResult 返回，供 sync_now/pull_then_push
                // 跳过对应模块的 push，防止陈旧数据覆盖云端新数据
                result.failed_modules.push(module);
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

    // 1. 比对指纹：远端 fp == 本地记录的 remote_fp → 跳过（委托纯函数，便于单测）
    if local_state
        .as_ref()
        .is_some_and(|s| should_skip_pull(s, remote_fp, remote_updated_at))
    {
        return PullModuleOutcome::Skipped;
    }

    // 2. 下载并解密 data（默认 .orsync，404 回退遗留 .waitsync）
    //    404 降级：远端无此模块数据 → 更新 remote_fp 避免重复尝试，视为跳过
    let (data_path, data_bytes) = match adapter
        .download(&paths::module_data_path(module_name))
        .await
    {
        Ok(bytes) => (paths::module_data_path(module_name), bytes),
        Err(e) if paths::is_not_found_error(&e) => {
            let legacy_path = paths::legacy_module_data_path(module_name);
            match adapter.download(&legacy_path).await {
                Ok(bytes) => (legacy_path, bytes),
                Err(e2) if paths::is_not_found_error(&e2) => {
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
                Err(e2) => {
                    return PullModuleOutcome::Failed {
                        module: module_name.to_string(),
                        message: format!("下载 {} 失败: {}", legacy_path, e2),
                    };
                }
            }
        }
        Err(e) => {
            let data_path = paths::module_data_path(module_name);
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("下载 {} 失败: {}", data_path, e),
            };
        }
    };

    let decrypted_data = match decrypt_payload(&data_bytes, data_key) {
        Ok(d) => d,
        Err(e) => {
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("解密 {} 失败: {}", data_path, e),
            };
        }
    };
    let module_data: ModuleData = match serde_json::from_slice(&decrypted_data) {
        Ok(d) => d,
        Err(e) => {
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("解析 {} 失败: {}", data_path, e),
            };
        }
    };

    // 3. 下载并解密 meta（默认 .orsync，404 回退遗留 .waitsync，获取墓碑集）
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
        match download_and_decrypt_meta_with_fallback(adapter, module_name, data_key).await {
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
                return PullModuleOutcome::Failed {
                    module: module_name.to_string(),
                    message: format!(
                        "获取 {} 失败（解密或网络错误），已跳过该模块合并以防删除丢失: {}",
                        meta_path, e
                    ),
                };
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

    let (changed_records, module_conflicts) = match merge_result {
        Ok(merge) => {
            builder.merging(
                module_name,
                module_def.display_name,
                merge.inserted,
                merge.updated,
                merge.deleted,
            );
            (
                merge.inserted + merge.updated + merge.deleted,
                merge.conflicts,
            )
        }
        Err(e) => {
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("合并 {} 失败: {}", module_name, e),
            };
        }
    };

    // 5. 合并后重新计算本地指纹（反映合并后的数据状态）
    let refreshed_items = match load_module_items(db_pool, module_def).await {
        Ok(items) => items,
        Err(e) => {
            if changed_records > 0 {
                builder.local_data_applied(changed_records);
            }
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("合并后重新加载 {} 失败: {}", module_name, e),
            };
        }
    };
    let local_fp = match crate::cloud_sync::compute_fingerprint(&refreshed_items) {
        Ok(fp) => fp,
        Err(e) => {
            if changed_records > 0 {
                builder.local_data_applied(changed_records);
            }
            return PullModuleOutcome::Failed {
                module: module_name.to_string(),
                message: format!("合并后计算 {} 指纹失败: {}", module_name, e),
            };
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
        conflicts: module_conflicts,
    }
}

/// 判断单个模块 Pull 是否应跳过（纯函数，便于真值表单测）
///
/// 主条件（增量跳过）：本地记录的 remote_fp 与远端 fp 一致且非空。
///
/// S17 二级校验（2026-09-14 审查）：push 侧中断窗口可产生「新 data +
/// 旧 _meta」的云端状态——_meta 里的 fp 是旧值，本端 remote_fp 与之
/// 相等即跳过，漏拉新 data。以 `_meta.updated_at` 兜底：全局索引更新
/// 时间晚于本地上次 Pull 记录（pulled_at），说明远端发生过本端未见的
/// 写入（含中断重传、其他设备覆盖 _meta），不跳过、强制走下载分支。
/// `remote_updated_at > 0` 排除旧版本/异常数据写 0 导致的每轮强制拉取。
fn should_skip_pull(local: &ModuleSyncState, remote_fp: &str, remote_updated_at: i64) -> bool {
    local.remote_fp == remote_fp
        && !local.remote_fp.is_empty()
        && !(remote_updated_at > local.pulled_at && remote_updated_at > 0)
}

/// 下载并解密模块 meta（默认 .orsync，404 回退遗留 .waitsync）
async fn download_and_decrypt_meta_with_fallback(
    adapter: &dyn SyncAdapter,
    module_name: &str,
    data_key: &[u8],
) -> Result<ModuleMetaEntry, CloudSyncError> {
    let primary = paths::module_meta_path(module_name);
    let bytes = match adapter.download(&primary).await {
        Ok(b) => b,
        Err(e) if paths::is_not_found_error(&e) => {
            let legacy = paths::legacy_module_meta_path(module_name);
            adapter
                .download(&legacy)
                .await
                .map_err(CloudSyncError::from)?
        }
        Err(e) => return Err(CloudSyncError::from(e)),
    };
    let decrypted = decrypt_payload(&bytes, data_key)?;
    let meta: ModuleMetaEntry = serde_json::from_slice(&decrypted)?;
    Ok(meta)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(remote_fp: &str, pulled_at: i64) -> ModuleSyncState {
        ModuleSyncState {
            fp: "fp-local".to_string(),
            remote_fp: remote_fp.to_string(),
            count: 1,
            pulled_at,
            pushed_at: 0,
        }
    }

    // ========================================================================
    // should_skip_pull 真值表：S17 漏拉窗口二级校验
    //
    // 漏拉场景：对端 push 中断留下「新 data + 旧 _meta」（_meta.fp 是旧值
    // 但 updated_at 已刷新），本端 remote_fp 与旧 fp 相等——无二级校验时
    // 永久跳过，新 data 漏拉。
    // ========================================================================

    #[test]
    fn skip_when_fp_matches_and_no_newer_remote_write() {
        // 常规增量：fp 一致 + 远端 updated_at 不晚于本地拉取时间 → 跳过
        assert!(should_skip_pull(&state("fp-a", 200), "fp-a", 100));
        assert!(should_skip_pull(&state("fp-a", 200), "fp-a", 200));
    }

    #[test]
    fn force_pull_when_meta_updated_after_last_pull() {
        // S17 核心：fp 一致但 _meta.updated_at 晚于本地 pulled_at → 不跳过
        //（对端 push 中断后重传：fp 恰好回到相同值但全局索引更新过）
        assert!(
            !should_skip_pull(&state("fp-a", 100), "fp-a", 300),
            "updated_at 晚于上次拉取时必须强制走下载分支"
        );
    }

    #[test]
    fn zero_remote_updated_at_keeps_legacy_skip() {
        // 旧版本/异常数据 updated_at=0：不能每轮强制拉取（保持原跳过语义）
        assert!(should_skip_pull(&state("fp-a", 100), "fp-a", 0));
    }

    #[test]
    fn fp_mismatch_or_empty_never_skips() {
        // fp 不一致 → 拉取；remote_fp 空（从未拉过）→ 拉取
        assert!(!should_skip_pull(&state("fp-a", 100), "fp-b", 50));
        assert!(!should_skip_pull(&state("", 100), "fp-a", 50));
    }
}
