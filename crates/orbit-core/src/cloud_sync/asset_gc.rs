//! asset_gc — 云端孤儿附件的只读扫描与物理删除（docs/15）
//!
//! ## 判据
//! `云端孤儿 = 云端附件对象集 − 云端引用集`，其中引用集是清单索引的
//! `tables/todo_task_attachments/` 数据桶里 `is_deleted = 0` 行的 DISTINCT hash。
//!
//! **不看本机账本**:本机「无引用」只是本机视角(离线设备的行可能还没 push),
//! 云端桶是各设备 push 合并后的并集，行还在 = 有设备引用，不清。[[docs/15 §4.1]]
//!
//! ## 安全兜底(误删代价是数据丢失，比数据桶孤儿更重)
//! 1. **年龄窗口**:对象 mtime 必须早于 `min_age_secs`(默认 30 天)——附件没有
//!    清单兜底，删了就没了，窗口比数据桶孤儿(24h)宽一个量级；
//! 2. **mtime 不可得一律跳过**(`last_modified <= 0`):宁可漏收，不误删；
//! 3. **删除前复核清单 `epoch`**:扫描后他端 push 过即拒绝执行，要求重扫——
//!    push 改任何桶内容都会改清单指纹，epoch 变化即引用集可能已变。
//!
//! ## 删除顺序
//! 分片形态**先删 `head.json`**(清单消失即目录立刻不可读，对齐
//! `webdav_adapter` 的分片写序)，再逐 `{index:06}.bin`；整包形态直接删对象。
//! 单个对象失败只记 `errors` 不中断(与 [`crate::cloud_sync::gc`] 同口径)。
//!
//! ## 为什么不删云端引用集里的 hash
//! 那是「有设备还在用」的附件。本端视角看起来无引用，只说明本端没挂载它，
//! 删掉会让其他设备下次 pull 时拉不到内容(自愈见 `attachments.rs` 的
//! 重传对账，但那只覆盖本地仍有明文的设备)。

use std::collections::HashSet;

use crate::cloud_sync::chunk::ChunkPayload;
use crate::cloud_sync::crypto_io::{decrypt_bucket_payload, decrypt_payload};
use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::meta::Manifest;
use crate::cloud_sync::paths;
use crate::sync_adapters::traits::{RemoteAssetKind, RemoteAssetObject, SyncAdapter};

/// 附件引用表：随 todos 模块同步，云端分桶是跨设备并集的唯一真相源
const ATTACHMENT_LINK_TABLE: &str = "todo_task_attachments";

/// 默认年龄窗口：30 天
///
/// 覆盖三件事的叠加：墓碑传播窗口（链行删除传遍所有设备）+ 用户后悔窗口 +
/// 长假离线窗口。归 0 会让「刚上传、其他设备引用尚未 push」的对象被误删。
pub const DEFAULT_CLOUD_ASSET_MIN_AGE_SECS: i64 = 30 * 24 * 3600;

/// 云端附件删除结果
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct CloudAssetDeleteResult {
    /// 实际处理（对象已被清空）的附件数
    pub deleted_assets: u32,
    /// 成功删除的云端对象数（含原本已不存在；分片按片计数）
    pub deleted_objects: u32,
    /// 复核阶段发现仍被云端引用而跳过的 hash 数
    pub skipped_referenced: u32,
    /// 清单 epoch 与扫描时不一致：未做任何删除，调用方须要求重扫
    pub stale_manifest: bool,
    /// 单对象删除失败明细（不中断）
    pub errors: Vec<String>,
}

/// 读取并解密云端清单
///
/// 与 `pull_all` 同口径；云端无清单返回 `None`（从未同步过）。
pub async fn read_cloud_manifest(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
) -> Result<Option<Manifest>, CloudSyncError> {
    match adapter.download_with_token(paths::MANIFEST_PATH).await? {
        None => Ok(None),
        Some((bytes, _)) => {
            let plain = decrypt_payload(&bytes, data_key)?;
            let manifest: Manifest = serde_json::from_slice(&plain)?;
            Ok(Some(manifest))
        }
    }
}

/// 收集云端引用集：`tables/todo_task_attachments/` 数据桶中 `is_deleted = 0` 的 hash
///
/// 任何桶读取/解密/解析失败都**中止扫描**——漏掉一个桶的引用就可能把仍在
/// 使用的附件判成孤儿，这是数据丢失级风险，宁可这一轮什么都不做。
pub async fn collect_cloud_referenced_hashes(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    manifest: &Manifest,
) -> Result<HashSet<String>, CloudSyncError> {
    let mut referenced = HashSet::new();
    let Some(index) = manifest.tables.get(ATTACHMENT_LINK_TABLE) else {
        // 从未同步过关联表（新库/仅本机）→ 云端没有引用记录
        log::info!("[asset_gc] 云端清单无 {ATTACHMENT_LINK_TABLE} 索引，引用集为空");
        return Ok(referenced);
    };

    for bucket in index.chunks.keys() {
        let path = paths::table_bucket_path(ATTACHMENT_LINK_TABLE, *bucket);
        let bytes = adapter
            .download(&path)
            .await
            .map_err(|e| CloudSyncError::Adapter {
                message: format!("下载引用桶 {path} 失败，中止扫描（防误删）: {e}"),
            })?;
        let plain = decrypt_bucket_payload(&bytes, data_key, &path)?;
        let payload: ChunkPayload = serde_json::from_slice(&plain)?;
        for item in &payload.items {
            // 墓碑/软删行不构成引用（与本地 GC 的 is_deleted = 0 同口径）
            if item.get("is_deleted").and_then(|v| v.as_i64()).unwrap_or(0) != 0 {
                continue;
            }
            if let Some(hash) = item.get("hash").and_then(|v| v.as_str())
                && !hash.is_empty()
            {
                referenced.insert(hash.to_string());
            }
        }
    }
    Ok(referenced)
}

/// 只读扫描云端孤儿附件（按密文体积降序）
///
/// `now_secs` 由调用方传入（便于测试固定时钟）；`min_age_secs` 建议
/// [`DEFAULT_CLOUD_ASSET_MIN_AGE_SECS`]。
pub async fn scan_cloud_orphan_assets(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    manifest: &Manifest,
    min_age_secs: i64,
    now_secs: i64,
) -> Result<Vec<RemoteAssetObject>, CloudSyncError> {
    let referenced = collect_cloud_referenced_hashes(adapter, data_key, manifest).await?;
    let objects = adapter.list_assets_with_meta(paths::ASSETS_DIR).await?;

    let mut orphans: Vec<RemoteAssetObject> = objects
        .into_iter()
        .filter(|o| !referenced.contains(&o.hash))
        .filter(|o| {
            // mtime 不可信(服务端未回)或对象太新：留给下一轮
            o.last_modified > 0 && now_secs.saturating_sub(o.last_modified) >= min_age_secs
        })
        .collect();

    // 体积降序（分片形态 mtime/体积来自目录条目，UI 侧用本地账本补足展示）
    orphans.sort_by(|a, b| {
        b.cipher_bytes
            .cmp(&a.cipher_bytes)
            .then_with(|| a.hash.cmp(&b.hash))
    });
    Ok(orphans)
}

/// 删除指定 hash 的云端附件对象（整包 + 分片两形态，docs/15 §4.4）
///
/// 执行前重新读清单并比对 `expected_epoch`：不一致说明扫描后他端 push 过，
/// 引用集可能已变——直接返回 `stale_manifest = true`，**一个对象都不删**。
/// 复核通过后还会重算引用集，把复核期间仍被引用的 hash 跳过。
pub async fn delete_cloud_assets(
    adapter: &dyn SyncAdapter,
    data_key: &[u8],
    expected_epoch: u64,
    hashes: &[String],
    min_age_secs: i64,
    now_secs: i64,
) -> Result<CloudAssetDeleteResult, CloudSyncError> {
    let mut result = CloudAssetDeleteResult::default();
    let Some(manifest) = read_cloud_manifest(adapter, data_key).await? else {
        // 清单消失（他端清空/从未同步）：拒绝执行，让调用方重扫
        result.stale_manifest = true;
        return Ok(result);
    };
    if manifest.epoch != expected_epoch {
        log::warn!(
            "[asset_gc] 清单 epoch 已变（扫描 {} → 现在 {}），拒绝删除并要求重扫",
            expected_epoch,
            manifest.epoch
        );
        result.stale_manifest = true;
        return Ok(result);
    }

    // 删除前重算引用集：复核窗口内刚被挂载的 hash 不得删
    let referenced = collect_cloud_referenced_hashes(adapter, data_key, &manifest).await?;

    // 当前云端对象表（体积/mtime/形态）；窗口内新出现的对象同样跳过
    let objects = adapter.list_assets_with_meta(paths::ASSETS_DIR).await?;
    let by_hash: std::collections::HashMap<&str, &RemoteAssetObject> =
        objects.iter().map(|o| (o.hash.as_str(), o)).collect();

    for hash in hashes {
        if referenced.contains(hash) {
            result.skipped_referenced += 1;
            continue;
        }
        let Some(obj) = by_hash.get(hash.as_str()) else {
            // 已被删除/扫描后消失：幂等跳过
            result.deleted_assets += 1;
            continue;
        };
        if obj.last_modified <= 0 || now_secs.saturating_sub(obj.last_modified) < min_age_secs {
            // 复核时对象已变新（他端刚写）→ 留给下一轮
            continue;
        }

        let mut failed = false;
        // 整包形态：直接删单对象
        if matches!(obj.kind, RemoteAssetKind::Whole | RemoteAssetKind::Both) {
            let path = paths::asset_path(hash);
            match adapter.delete(&path).await {
                Ok(()) => result.deleted_objects += 1,
                Err(e) => {
                    failed = true;
                    result.errors.push(format!("删除 {path} 失败: {e}"));
                }
            }
        }

        // 分片形态：先 head.json 再逐片（清单消失即目录不可读）
        if matches!(obj.kind, RemoteAssetKind::Chunked | RemoteAssetKind::Both) {
            let dir = format!("{}/{}", parts_root_for_assets_dir(paths::ASSETS_DIR), hash);
            match adapter.list_all_files(&dir).await {
                Ok(files) => {
                    let mut names: Vec<String> = files.into_iter().map(|f| f.name).collect();
                    // head.json 排最前：先让目录不可读，再清数据片
                    names.sort_by_key(|n| n != "head.json");
                    for name in names {
                        let path = format!("{dir}/{name}");
                        match adapter.delete(&path).await {
                            Ok(()) => result.deleted_objects += 1,
                            Err(e) => {
                                failed = true;
                                result.errors.push(format!("删除 {path} 失败: {e}"));
                            }
                        }
                    }
                }
                Err(e) => {
                    failed = true;
                    result.errors.push(format!("列举分片目录 {dir} 失败: {e}"));
                }
            }
        }

        if !failed {
            result.deleted_assets += 1;
        }
    }

    Ok(result)
}

/// 由附件目录推导分片根目录：末段 `assets` → `assets_parts`
///
/// 与 `webdav_adapter` 的同名函数同口径（F23：前缀必须随路径一起走）。
fn parts_root_for_assets_dir(assets_dir: &str) -> String {
    assets_dir.strip_suffix("/assets").map_or_else(
        || "assets_parts".to_string(),
        |head| format!("{head}/assets_parts"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parts_root_replaces_last_segment() {
        assert_eq!(parts_root_for_assets_dir("assets"), "assets_parts");
        assert_eq!(
            parts_root_for_assets_dir("wait-sync/user1/assets"),
            "wait-sync/user1/assets_parts"
        );
    }
}
