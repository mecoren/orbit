//! gc — 墓碑水位线回收与孤儿分桶清理
//!
//! ## 为什么需要回收
//! 删除语义靠墓碑传播：一条记录删除后，只要还有设备没看到该墓碑，它就不能
//! 被丢弃（否则该设备会把删除当"本地有、远端无"而复活记录）。墓碑因此不能
//! 无限期保留，也不能随意删除——需要一个**安全水位线**。
//!
//! ## 水位线口径
//! [`Manifest::tombstone_watermark`] = 所有登记设备检查点
//! （`last_synced_at`）的最小值，且**设备数 < 2 时返回 0（不回收）**。
//! 早于该时刻删除的墓碑，可以确定已被全部设备同步过，删除不会导致复活。
//!
//! ## 顺序约束（重要）
//! 必须先「上传剔除过期条目的新清单」，再「删除云端墓碑对象」：
//! 反过来会出现「对象已删但清单仍引用」→ 其他设备 pull 时 404 失败。
//! 中途失败只会留下孤儿对象（无清单引用，不影响正确性），由下一轮回收。
//!
//! ## 孤儿分桶
//! 数据分桶对象不随行删除而消失（push 只增不删索引条目）。孤儿对象不参与
//! 清单索引 → 不会被 pull 读到，仅占存储；其清理需要「桶内所有 uuid 都有
//! 墓碑」的判据，属后续增强项，当前不在本模块范围内。

use crate::cloud_sync::meta::Manifest;
use crate::cloud_sync::paths;
use crate::sync_adapters::traits::SyncAdapter;

/// 回收结果
#[derive(Debug, Clone, Default)]
pub struct GcResult {
    /// 本机水箱线（0 = 未满足回收条件，未做任何删除）
    pub watermark: i64,
    /// 从清单剔除并尝试删除的墓碑分桶数
    pub deleted_buckets: u32,
    /// 删除失败的对象（已从清单剔除，留孤儿的可容忍失败）
    pub errors: Vec<String>,
}

/// 剔除清单中早于水位线的墓碑分桶（纯函数 + 就地修改）
///
/// 返回被剔除的 `(表名, 桶键)` 列表；水位线为 0（设备数不足）时不改动清单。
/// **只修改内存中的清单**，不影响云端对象——调用方须在上传新清单成功后再调用
/// [`delete_expired_buckets`] 删除对象。
pub fn prune_expired_tombstones(manifest: &mut Manifest) -> Vec<(String, String)> {
    let watermark = manifest.tombstone_watermark();
    if watermark <= 0 {
        return Vec::new();
    }
    let watermark_month = crate::cloud_sync::db_loader::local_month_key(watermark);
    let expired = collect_expired_from_original(manifest, &watermark_month);
    for index in manifest.tombstones.values_mut() {
        index
            .buckets
            .retain(|bucket, _| bucket.as_str() >= watermark_month.as_str());
    }
    expired
}

/// 收集水位线之前的墓碑分桶（在 prune 之前调用语义更清晰）
fn collect_expired_from_original(
    manifest: &Manifest,
    watermark_month: &str,
) -> Vec<(String, String)> {
    manifest
        .tombstones
        .iter()
        .flat_map(|(table, index)| {
            index
                .buckets
                .keys()
                .filter(|b| b.as_str() < watermark_month)
                .map(|b| (table.clone(), b.clone()))
        })
        .collect()
}

/// 删除云端墓碑分桶对象（尽力而为：单个失败只记 errors，不中断）
///
/// 调用时机：**新清单上传成功之后**（见模块级顺序约束）。
pub async fn delete_expired_buckets(
    adapter: &dyn SyncAdapter,
    buckets: &[(String, String)],
) -> GcResult {
    let mut result = GcResult::default();
    for (table, bucket) in buckets {
        let path = paths::tombstone_bucket_path(table, bucket);
        match adapter.delete(&path).await {
            Ok(()) => result.deleted_buckets += 1,
            Err(e) if e.is_not_found() => result.deleted_buckets += 1,
            Err(e) => result.errors.push(format!("删除 {path} 失败: {e}")),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync::meta::{TombstoneBucketRef, TombstoneIndex};
    use std::collections::BTreeMap;

    fn manifest_with_tombstones(buckets: &[&str], devices: &[(&str, i64)]) -> Manifest {
        let mut m = Manifest::empty("dev-1");
        for (id, ts) in devices {
            m.touch_device(id, *ts);
        }
        m.tombstones.insert(
            "todo_tasks".to_string(),
            TombstoneIndex {
                buckets: buckets
                    .iter()
                    .map(|b| {
                        (
                            b.to_string(),
                            TombstoneBucketRef {
                                fp: format!("fp-{b}"),
                                count: 1,
                                max_deleted_at: 0,
                            },
                        )
                    })
                    .collect::<BTreeMap<_, _>>(),
            },
        );
        m
    }

    #[test]
    fn no_prune_when_single_device() {
        let mut m =
            manifest_with_tombstones(&["2020-01", "2026-09"], &[("dev-1", 1_700_000_000_000)]);
        let expired = prune_expired_tombstones(&mut m);
        assert!(expired.is_empty(), "单设备不得回收墓碑");
        assert_eq!(m.tombstones["todo_tasks"].buckets.len(), 2);
    }

    #[test]
    fn prune_removes_buckets_before_watermark_month() {
        // 设备水位线 = 2026-06（最小值），则 2026-05 及更早可回收
        let mut m = manifest_with_tombstones(
            &["2020-01", "2026-05", "2026-06", "2026-09"],
            &[("dev-1", 1_800_000_000_000), ("dev-2", 1_750_000_000_000)],
        );
        let watermark = m.tombstone_watermark();
        let expected_month = crate::cloud_sync::db_loader::local_month_key(watermark);

        let expired = prune_expired_tombstones(&mut m);
        assert!(!expired.is_empty(), "水位线前应有可回收分桶");
        assert!(
            expired
                .iter()
                .all(|(_, b)| b.as_str() < expected_month.as_str())
        );
        assert!(
            m.tombstones["todo_tasks"]
                .buckets
                .keys()
                .all(|b| b.as_str() >= expected_month.as_str())
        );
    }

    #[test]
    fn same_month_bucket_is_not_pruned() {
        // 同月墓碑保守不删（水位线为月初无法区分月内先后）
        let ts = 1_789_473_600_000i64; // 2026-09
        let month = crate::cloud_sync::db_loader::local_month_key(ts);
        let mut m = manifest_with_tombstones(&[month.as_str()], &[("d1", ts), ("d2", ts)]);
        let expired = prune_expired_tombstones(&mut m);
        assert!(expired.is_empty(), "同月分桶必须保留");
    }
}
