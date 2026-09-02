//! push — 模块级增量上传流程
//!
//! 遍历 15 个同步模块，按指纹增量上传变化的模块数据到云端。
//! 所有云端文件均用 Data Key AES-256-GCM 加密。
//!
//! ## Push 流程
//! 1. 加载本地同步状态
//! 2. 获取已解锁的 Data Key
//! 3. 探测远端 `_meta.waitsync` 修正本地 state（`reconcile_state_with_remote_meta`）：
//!    - 远端 `_meta` 404 → 清空所有模块 `remote_fp`，触发全量 push
//!    - 远端 `_meta` 存在但模块 `fp` 与本地 `remote_fp` 不一致 → 清空该模块 `remote_fp`
//!    - 修正后 `should_skip` 失效，确保远端被外部清空/修改时本地能重新上传
//! 4. 遍历每个模块：
//!    - 加载模块所有未删除记录
//!    - 计算本地指纹
//!    - 与上次 Push 的指纹比对，相同则跳过
//!    - 变化则序列化 → 加密 → 上传 `data.waitsync` + `meta.waitsync`
//!    - 更新本地状态
//! 5. 上传全局 `_meta.waitsync`
//! 6. 附件同步（调用 attachments 模块，M1.11 实现）
//!
//! ## 云端路径
//! - `modules/{name}/data.waitsync`：模块数据（加密）
//! - `modules/{name}/meta.waitsync`：模块元数据（加密）
//! - `_meta.waitsync`：全局索引（加密）
//! - `crypto/config`：加密元数据（无扩展名，由 sync_crypto::bundle_io 管理）

use sqlx::SqlitePool;

use crate::cloud_sync::crypto_io::{decrypt_payload, encrypt_payload};
use crate::cloud_sync::db_loader::{load_all_tombstones, load_module_items, now_ms};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::{GlobalMeta, ModuleData, ModuleMetaEntry, TombstoneEntry};
use crate::cloud_sync::modules::{SYNC_MODULES, SyncModuleDef};
use crate::cloud_sync::paths;
use crate::cloud_sync::progress::{ProgressBuilder, ProgressSender, SyncOrigin};
use crate::cloud_sync::state::{ModuleSyncState, SyncState, SyncStateStore};
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::SyncCryptoService;

/// Push 执行结果
#[derive(Debug, Clone, Default)]
pub struct PushResult {
    /// 实际上传的模块数（指纹变化的模块）
    pub pushed_modules: u32,
    /// 跳过的模块数（指纹未变）
    pub skipped_modules: u32,
}

/// 单个模块 Push 任务的结果（用于并行任务返回，主流程顺序应用 state）
enum PushModuleOutcome {
    /// 指纹未变，跳过
    Skipped,
    /// 成功上传，携带新状态供主流程写入
    Pushed {
        name: String,
        new_state: ModuleSyncState,
    },
}

/// 执行全量 Push：遍历所有模块，上传指纹变化的模块数据
///
/// `device_id` 用于写入 GlobalMeta，便于多设备诊断。
/// `origin` 标识事件来源（Background/Manual/Exit），用于 UI 层过滤重复显示。
///
/// ## 实现说明
/// - 串行 Push：15 个模块顺序执行，避免并发 MKCOL 同一目录触发 WebDAV 503
/// - 批量 state 保存：循环结束后一次性写入 `sync_state.json`，避免每模块都写文件
pub async fn push_all(
    db_pool: &SqlitePool,
    crypto: &SyncCryptoService,
    state_store: &SyncStateStore,
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    device_id: &str,
) -> Result<PushResult, CloudSyncError> {
    let mut state = state_store.load()?;
    let data_key = crypto.get_data_key().ok_or(CloudSyncError::CryptoLocked)?;

    // Push 前探测远端 _meta.waitsync，感知"远端被外部清空或修改"场景：
    // - 远端 _meta 404 → 清空所有模块 remote_fp，触发全量 push（修复"删除云端后不同步"bug）
    // - 远端 _meta 存在但模块 fp 与本地 remote_fp 不一致 → 清空该模块 remote_fp，触发该模块 push
    // - 远端 _meta 存在且 fp 一致 → 保持原 should_skip 跳过逻辑
    // 非 404 错误（网络/认证等）向上传播，中止 push（远端不可达时 upload 也会失败）。
    reconcile_state_with_remote_meta(adapter, &data_key, &mut state).await?;

    let builder = ProgressBuilder::new(progress_sender, origin);
    let total = SYNC_MODULES.len() as u32;
    builder.starting(total);

    // 预捕获所有模块的 prev_state
    let prev_states: Vec<(SyncModuleDef, Option<ModuleSyncState>)> = SYNC_MODULES
        .iter()
        .map(|m| (*m, state.modules.get(m.name).cloned()))
        .collect();

    // 串行 Push：每个模块独立完成 加载→指纹比对→序列化加密→上传 → 返回 outcome。
    // 注：原 buffer_unordered(8) 并行实现在 WebDAV 上触发并发 MKCOL 同一目录，
    // 部分服务器对并发 MKCOL 返回 503（"Service Temporarily Unavailable"），
    // 导致 push_all 整体失败 + with_retry 重试，表现为"不停同步"。
    // 串行避免并发目录创建冲突，且代码更简单。
    let mut outcomes: Vec<Result<PushModuleOutcome, CloudSyncError>> =
        Vec::with_capacity(prev_states.len());
    for (idx, (module_def, prev_state)) in prev_states.into_iter().enumerate() {
        let current = idx as u32 + 1;
        let outcome = push_single_module(
            db_pool,
            &data_key,
            adapter,
            progress_sender,
            origin,
            &module_def,
            prev_state,
            current,
            total,
        )
        .await;
        outcomes.push(outcome);
    }

    // 顺序应用 outcomes 到 state 和 result
    let mut result = PushResult::default();
    for outcome in outcomes {
        match outcome? {
            PushModuleOutcome::Skipped => result.skipped_modules += 1,
            PushModuleOutcome::Pushed { name, new_state } => {
                state.set_module(&name, new_state);
                result.pushed_modules += 1;
            }
        }
    }

    // 上传全局 _meta.waitsync（仅当至少一个模块实际 push 时）
    //    避免所有模块被跳过时仍上传 _meta，产生"说谎的 _meta"（声称模块存在但
    //    实际模块数据文件未上传）。reconcile 的文件存在性校验依赖此不变量。
    if result.pushed_modules > 0 {
        let global_meta = build_global_meta(&state, device_id);
        let global_json = serde_json::to_vec(&global_meta)?;
        let encrypted_global = encrypt_payload(&global_json, &data_key)?;
        adapter
            .upload(paths::GLOBAL_META_PATH, &encrypted_global)
            .await?;
    }

    // 批量保存 state（循环结束后一次性写入，避免每模块都写文件）
    state.last_synced_at = now_ms();
    state_store.save(&state)?;

    Ok(result)
}

/// 处理单个模块的 Push（并行任务单元）
///
/// 独立完成：加载模块数据 → 计算指纹 → 比对跳过 → 序列化加密上传 → 返回新状态。
/// 不修改全局 state，将新状态通过 outcome 返回由主流程顺序应用。
#[allow(clippy::too_many_arguments)] // 单模块推送管道参数，聚合进结构体收益低
async fn push_single_module(
    db_pool: &SqlitePool,
    data_key: &[u8],
    adapter: &dyn SyncAdapter,
    progress_sender: &dyn ProgressSender,
    origin: SyncOrigin,
    module_def: &SyncModuleDef,
    prev_state: Option<ModuleSyncState>,
    current: u32,
    total: u32,
) -> Result<PushModuleOutcome, CloudSyncError> {
    let builder = ProgressBuilder::new(progress_sender, origin);
    builder.pushing(module_def.name, module_def.display_name, current, total);

    // 1. 加载模块数据
    let items = load_module_items(db_pool, module_def).await?;

    // 2. 计算本地指纹
    let local_fp = crate::cloud_sync::compute_fingerprint(&items)?;

    // 3. 比对指纹决定是否跳过（委托纯函数，便于单元测试）
    let should_skip = should_skip_push(prev_state.as_ref(), &local_fp, items.is_empty());
    if should_skip {
        return Ok(PushModuleOutcome::Skipped);
    }

    // 4. 序列化 + 加密 + 上传 data.waitsync
    let module_data = ModuleData {
        module: module_def.name.to_string(),
        items,
        exported_at: now_ms(),
    };
    let data_json = serde_json::to_vec(&module_data)?;
    let encrypted_data = encrypt_payload(&data_json, data_key)?;
    let data_path = paths::module_data_path(module_def.name);
    adapter.upload(&data_path, &encrypted_data).await?;

    // 5. 构造墓碑集（FR-2.4：无上限，含 deleted_at 时间戳）
    let tombstone_pairs = load_all_tombstones(db_pool, module_def).await?;
    let deleted_ids: Vec<TombstoneEntry> = tombstone_pairs
        .into_iter()
        .map(|(uuid, deleted_at)| TombstoneEntry::new(uuid, deleted_at))
        .collect();

    // 6. 序列化 + 加密 + 上传 meta.waitsync
    let module_meta = ModuleMetaEntry {
        fp: local_fp.clone(),
        count: module_data.items.len() as u64,
        deleted_ids,
        updated_at: now_ms(),
    };
    let meta_json = serde_json::to_vec(&module_meta)?;
    let encrypted_meta = encrypt_payload(&meta_json, data_key)?;
    let meta_path = paths::module_meta_path(module_def.name);
    adapter.upload(&meta_path, &encrypted_meta).await?;

    // 7. 构造新状态（委托纯函数，便于单元测试）
    let new_state = build_pushed_state(
        &local_fp,
        prev_state.as_ref(),
        module_data.items.len() as u64,
    );

    Ok(PushModuleOutcome::Pushed {
        name: module_def.name.to_string(),
        new_state,
    })
}

/// 判断单个模块 Push 是否应跳过
///
/// 提取为纯函数便于单元测试覆盖各种同步场景。
///
/// ## 跳过条件
/// ### 条件 A：首次同步 + 本地空数据 → 跳过（Fix Issue 2）
/// 场景：移动端首次同步，Pull 失败（网络/解密错误），本地 DB 为空。
/// 若不跳过，会上传空数据覆盖云端已有数据。
///
/// ### 条件 B：增量跳过（全部满足才跳过）
/// 1. 有上一次同步状态 `prev_state`（非首次同步）
/// 2. 本地指纹未变：`prev_state.fp == local_fp`
/// 3. 本地指纹非空：`!prev_state.fp.is_empty()`
/// 4. 远端指纹非空：`!prev_state.remote_fp.is_empty()`（已成功 Pull 过）
/// 5. 本地指纹 == 远端指纹（Fix Issue 3）：`prev_state.fp == prev_state.remote_fp`
///    确保本地数据与上次记录的远端数据一致才跳过。
///    若不一致，说明远端被其他设备覆盖（如移动端上传空数据），
///    本设备需 Push 恢复云端数据。
fn should_skip_push(
    prev_state: Option<&ModuleSyncState>,
    local_fp: &str,
    local_items_empty: bool,
) -> bool {
    // Fix Issue 2：首次同步 + 本地空数据 → 跳过，避免上传空数据覆盖远端
    if prev_state.is_none() && local_items_empty {
        return true;
    }
    // Fix Issue 3：增加 `s.fp == s.remote_fp` 条件
    // 确保本地数据与上次记录的远端数据一致才跳过，
    // 远端被其他设备覆盖时本设备能重新 Push 恢复
    prev_state.is_some_and(|s| {
        s.fp == local_fp && !s.fp.is_empty() && !s.remote_fp.is_empty() && s.fp == s.remote_fp
    })
}

/// 构造 Push 成功后的新模块状态
///
/// 提取为纯函数便于单元测试验证状态更新正确性。
///
/// ## 字段语义
/// - `fp`：本次 Push 时的本地指纹
/// - `remote_fp`：Fix Issue 3 — 更新为 `local_fp`（而非保留旧值）
///   Push 成功后远端数据已与本地一致，remote_fp 应反映这一事实。
///   旧逻辑保留 prev_state.remote_fp 导致下次 should_skip 误判
///   （state.fp != state.remote_fp，触发不必要的重传或跳过）。
/// - `count`：本次 Push 的记录数
/// - `pushed_at`：当前时间戳
/// - `pulled_at`：保留上一次的 Pull 时间
fn build_pushed_state(
    local_fp: &str,
    prev_state: Option<&ModuleSyncState>,
    count: u64,
) -> ModuleSyncState {
    ModuleSyncState {
        fp: local_fp.to_string(),
        // Fix Issue 3：Push 后远端数据已与本地一致，remote_fp 应 = local_fp
        remote_fp: local_fp.to_string(),
        count,
        pushed_at: now_ms(),
        pulled_at: prev_state.as_ref().map_or(0, |s| s.pulled_at),
    }
}

/// Push 前根据远端 `_meta.waitsync` 探测结果修正本地 state
///
/// 用于感知"远端被外部清空或修改"场景，避免本地数据未变时跳过上传导致云端持续为空：
/// - 远端 `_meta.waitsync` 404 → 远端被清空，
///   清空所有模块的 `remote_fp`，触发全量 push。
/// - 远端 `_meta` 存在 → 对每个本地记录的模块，比对远端 `_meta` 中对应模块的 `fp`
///   与本地 `state.remote_fp`：
///   - 不一致或远端无此模块 → 清空该模块 `remote_fp`，触发该模块 push。
///   - 一致 → 进入步骤 3 文件存在性校验。
/// - 步骤 3：fp 全部一致时，下载首个有数据模块的 `data.waitsync` 验证存在性。
///   - 404 → 远端存在"说谎的 _meta"（旧版本 broken push 仅上传 _meta 未上传模块数据），
///     清空所有模块 `remote_fp`，触发全量 push。
///   - 存在 → 远端数据完整，保持原 `should_skip` 跳过逻辑生效。
///
/// 非 404 错误（网络/认证等）直接向上传播，不触发修正。
///
/// 返回 `true` 表示触发了任何 state 修正（用于诊断日志）。
async fn reconcile_state_with_remote_meta(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    state: &mut SyncState,
) -> Result<bool, CloudSyncError> {
    // 1. 下载远端 _meta.waitsync
    let remote_meta = match adapter.download(paths::GLOBAL_META_PATH).await {
        Ok(meta_bytes) => {
            let decrypted = decrypt_payload(&meta_bytes, data_key)?;
            serde_json::from_slice::<GlobalMeta>(&decrypted)?
        }
        Err(e) if paths::is_not_found_error(&e) => {
            // 远端被外部清空：清空所有模块的 remote_fp，触发全量 push。
            // 保留 fp（本地指纹）不变，仅清空 remote_fp 让 should_skip 失效。
            let changed = state.modules.values().any(|m| !m.remote_fp.is_empty());
            if changed {
                for (_, m) in state.modules.iter_mut() {
                    m.remote_fp.clear();
                }
            }
            return Ok(changed);
        }
        Err(e) => return Err(CloudSyncError::from(e)),
    };

    // 2. 远端 _meta 存在：逐模块比对远端 fp 与本地 state.remote_fp
    let mut changed = false;
    for (name, local_state) in state.modules.iter_mut() {
        let remote_fp = remote_meta
            .modules
            .get(name)
            .map(|m| m.fp.as_str())
            .unwrap_or("");
        if local_state.remote_fp != remote_fp {
            // 远端 fp 与本地记录不一致（含远端无此模块），清空以触发 push
            local_state.remote_fp.clear();
            changed = true;
        }
    }
    // fp 有不一致 → 已触发修正，无需进一步校验
    if changed {
        return Ok(true);
    }

    // 3. fp 全部一致 → 下载首个有数据模块的 data 文件验证存在性
    //    检测"说谎的 _meta"场景：旧版本 broken push 仅上传 _meta 未上传模块数据，
    //    导致 _meta 声称模块存在但实际文件缺失。下载首个模块验证，404 则全量重传。
    let verify_module = SYNC_MODULES
        .iter()
        .find(|m| state.modules.get(m.name).is_some_and(|s| !s.fp.is_empty()));
    if let Some(module_def) = verify_module {
        let data_path = paths::module_data_path(module_def.name);
        match adapter.download(&data_path).await {
            Ok(_bytes) => {
                // 模块数据文件存在 → 远端完整，信任 _meta（丢弃下载内容）
            }
            Err(e) if paths::is_not_found_error(&e) => {
                // 模块数据文件缺失 → 远端破损（说谎的 _meta）→ 清空所有 remote_fp 触发全量 push
                for (_, m) in state.modules.iter_mut() {
                    if !m.remote_fp.is_empty() {
                        m.remote_fp.clear();
                        changed = true;
                    }
                }
            }
            Err(e) => return Err(CloudSyncError::from(e)),
        }
    }
    Ok(changed)
}

/// 从本地状态构建全局元数据
fn build_global_meta(state: &SyncState, device_id: &str) -> GlobalMeta {
    let mut meta = GlobalMeta::empty(device_id);
    meta.updated_at = now_ms();
    for module_def in SYNC_MODULES {
        let module_state = state.module(module_def.name);
        meta.modules.insert(
            module_def.name.to_string(),
            ModuleMetaEntry {
                fp: module_state.fp,
                count: module_state.count,
                deleted_ids: Vec::new(), // 墓碑集在模块级 meta.json 中
                updated_at: module_state.pushed_at,
            },
        );
    }
    meta
}

/// 上传单个附件（供 attachments 模块调用）
///
/// 附件用同一 Data Key 加密后上传到 `assets/<hash>.waitsync`（由 adapter 内部构造路径）。
pub async fn upload_attachment(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    hash: &str,
    data: &[u8],
) -> Result<(), CloudSyncError> {
    let encrypted = encrypt_payload(data, data_key)?;
    adapter.upload_asset(hash, &encrypted).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造测试用 ModuleSyncState
    fn make_state(fp: &str, remote_fp: &str) -> ModuleSyncState {
        ModuleSyncState {
            fp: fp.to_string(),
            remote_fp: remote_fp.to_string(),
            count: 0,
            pulled_at: 0,
            pushed_at: 0,
        }
    }

    // ========================================================================
    // should_skip_push 测试：覆盖 Issue 2 和 Issue 3 场景
    // ========================================================================

    #[test]
    fn skip_first_sync_with_data_should_push() {
        // 场景：首次同步，本地有数据 → 不跳过（正常推送）
        let local_fp = "fp_local_with_data";
        let prev_state: Option<&ModuleSyncState> = None;
        assert!(!should_skip_push(prev_state, local_fp, false));
    }

    #[test]
    fn skip_first_sync_empty_local_should_skip_to_avoid_overwriting_remote() {
        // Issue 2 核心场景：首次同步 + 本地空数据 → 必须跳过
        //
        // 移动端首次同步，Pull 失败（网络/解密错误），本地 DB 为空。
        // 若不跳过 Push，会上传空数据覆盖云端已有数据。
        // local_fp 是 sha256("[]")（非空字符串），但 local_items_empty=true 触发跳过
        let local_fp = "4f5e1d6a3c2b8a9f0e7d6c5b4a392817f6e5d4c3b2a1908f7e6d5c4b3a29187f";
        let prev_state: Option<&ModuleSyncState> = None;
        assert!(
            should_skip_push(prev_state, local_fp, true),
            "首次同步且本地为空时必须跳过 Push，避免覆盖云端数据"
        );
    }

    #[test]
    fn skip_local_unchanged_and_matches_remote_should_skip() {
        // 场景：本地未变 + 本地==远端 → 跳过（正常增量同步）
        let local_fp = "fp_abc";
        let prev_state = make_state("fp_abc", "fp_abc");
        assert!(should_skip_push(Some(&prev_state), local_fp, false));
    }

    #[test]
    fn skip_local_unchanged_but_differs_from_remote_should_push() {
        // Issue 3 核心场景：本地未变 + 本地!=远端 → 不跳过，需重传
        //
        // 移动端覆盖云端后，桌面端 Pull 更新 state.remote_fp = fp_empty，
        // 但 state.fp = fp_D1 不变（本地数据未变）。
        // 此时 should_skip 应返回 false，让桌面端 Push 恢复云端数据。
        let local_fp = "fp_D1";
        let prev_state = make_state("fp_D1", "fp_empty_after_mobile_overwrite");
        assert!(
            !should_skip_push(Some(&prev_state), local_fp, false),
            "本地未变但与远端不一致时必须 Push，恢复云端数据"
        );
    }

    #[test]
    fn skip_local_changed_should_push() {
        // 场景：本地数据变化 → 不跳过
        let local_fp = "fp_new";
        let prev_state = make_state("fp_old", "fp_old");
        assert!(!should_skip_push(Some(&prev_state), local_fp, false));
    }

    #[test]
    fn skip_empty_remote_fp_should_push() {
        // 场景：prev_state 有但 remote_fp 空（从未成功 Pull）→ 不跳过
        let local_fp = "fp_abc";
        let prev_state = make_state("fp_abc", "");
        assert!(!should_skip_push(Some(&prev_state), local_fp, false));
    }

    #[test]
    fn skip_empty_local_fp_should_push() {
        // 场景：prev_state.fp 为空 → 不跳过（防御性）
        let local_fp = "fp_abc";
        let prev_state = make_state("", "fp_abc");
        assert!(!should_skip_push(Some(&prev_state), local_fp, false));
    }

    // ========================================================================
    // build_pushed_state 测试：验证 Push 后状态更新正确性
    // ========================================================================

    #[test]
    fn build_pushed_state_updates_remote_fp_to_local_fp() {
        // Issue 3 修复：Push 后 new_state.remote_fp 应 = local_fp
        //
        // 旧逻辑保留 prev_state.remote_fp（旧值），导致下次 should_skip 误判：
        // - state.fp = local_fp（刚推送）
        // - state.remote_fp = old_remote_fp（未更新）
        // - 下次 reconcile 发现 state.remote_fp != 远端 fp → 清空 remote_fp
        // - should_skip = false（remote_fp 为空）→ 每次都重传（"不停同步"）
        //
        // 修复：Push 后 remote_fp = local_fp，表示远端现在有我们的本地数据。
        let local_fp = "fp_just_pushed";
        let prev_state = make_state("fp_old", "fp_old_remote");
        let new_state = build_pushed_state(local_fp, Some(&prev_state), 10);
        assert_eq!(
            new_state.remote_fp, local_fp,
            "Push 后 remote_fp 必须更新为 local_fp，表示远端现在有本地数据"
        );
    }

    #[test]
    fn build_pushed_state_first_push_sets_remote_fp_to_local_fp() {
        // 场景：首次 Push（prev_state 为 None）
        // 修复后 remote_fp 也应 = local_fp
        let local_fp = "fp_first_push";
        let new_state = build_pushed_state(local_fp, None, 5);
        assert_eq!(new_state.remote_fp, local_fp);
        assert_eq!(new_state.fp, local_fp);
        assert_eq!(new_state.count, 5);
    }

    #[test]
    fn build_pushed_state_preserves_pulled_at() {
        // 场景：Push 后应保留上一次的 pulled_at
        let prev_state = ModuleSyncState {
            fp: "old".to_string(),
            remote_fp: "old_remote".to_string(),
            count: 0,
            pulled_at: 12345,
            pushed_at: 67890,
        };
        let new_state = build_pushed_state("new_fp", Some(&prev_state), 10);
        assert_eq!(new_state.pulled_at, 12345, "pulled_at 应保留");
    }
}
