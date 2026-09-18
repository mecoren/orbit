//! chunk — 表级行分桶（差量同步的最小传输单元）
//!
//! ## 为什么不是「按 uuid 排序切片」
//! 顺序切片（第 1~N 行一片、N+1~2N 行一片）在中间插入/删除一行后，**后续所有
//! 分片的边界整体漂移**，分片指纹几乎全部变化，差量退化为全量重传。
//!
//! 采用**稳定哈希分桶**：`bucket = sha256(uuid) 前 4 字节 BE % TABLE_BUCKET_COUNT`。
//! 行的归属只取决于自身 uuid，与库内位置和其他行的增删无关——单行编辑只会让
//! 它所在的那一个桶变化，其余桶指纹保持稳定，差量上传才真正成立。
//!
//! ## 权衡
//! - 桶数固定（[`TABLE_BUCKET_COUNT`]）：对象数与「桶内平均行数」成反比。
//!   取 64 是 11 张表 × 数十对象的量级，对 S3/WebDAV（坚果云约 1 req/s 限流）
//!   属低压力；桶内平均行数 = 表行数 / 64，万行表约 156 行/桶（数十字节 KB）。
//! - 稳定哈希的代价：桶内行数不保证绝对均匀，但差量收益与均匀性无关，
//!   只与「改动影响的分片数」有关。
//!
//! ## 指纹口径
//! 每个桶的指纹复用 [`crate::cloud_sync::fingerprint::compute_fingerprint`]
//! （canonical JSON + sha256，排除 `updated_at` / `id`），因此「仅时间戳变化」
//! 不会触发对象重传；桶内行按 uuid 排序后序列化，保证字节级确定性。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::fingerprint::compute_fingerprint;

/// 每张表的分桶数量（固定值：桶号参与云端对象路径，改变它等于全量重传一次）
pub const TABLE_BUCKET_COUNT: u32 = 64;

/// 计算 uuid 归属的桶号（稳定哈希）
///
/// 空 uuid（异常数据，merge 侧会拒绝）统一归入 0 号桶，保证不丢行。
pub fn bucket_of_uuid(uuid: &str) -> u32 {
    if uuid.is_empty() {
        return 0;
    }
    let hex = crate::crypto::sha256::sha256_hex(uuid.as_bytes());
    // 取前 8 个 hex 字符（4 字节）解析为 u32；sha256_hex 输出恒为 64 字符
    u32::from_str_radix(&hex[..8], 16).unwrap_or(0) % TABLE_BUCKET_COUNT
}

/// 单张表的一个分桶（内存态，尚未序列化）
#[derive(Debug, Clone)]
pub struct TableChunk {
    /// 表名
    pub table: String,
    /// 桶号（0..TABLE_BUCKET_COUNT）
    pub bucket: u32,
    /// 桶内记录（已按 uuid 升序，保证序列化确定性）
    pub items: Vec<Value>,
}

impl TableChunk {
    /// 分桶指纹（canonical JSON + sha256）
    pub fn fingerprint(&self) -> Result<String, CloudSyncError> {
        compute_fingerprint(&self.items)
    }

    /// 序列化为云端载荷字节（明文，调用方负责加密）
    pub fn to_payload_bytes(&self) -> Result<Vec<u8>, CloudSyncError> {
        let payload = ChunkPayload {
            table: self.table.clone(),
            bucket: self.bucket,
            items: self.items.clone(),
        };
        Ok(serde_json::to_vec(&payload)?)
    }
}

/// 分桶载荷结构（加密后写入 `tables/{table}/{bucket:02}.orsync`）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkPayload {
    /// 表名（下载侧路由依据；与路径同源，冗余一份以便对象自描述）
    pub table: String,
    /// 桶号
    pub bucket: u32,
    /// 记录数组（每条含 uuid / updated_at / version 等原始列）
    pub items: Vec<Value>,
}

/// 将单表记录切分为稳定分桶
///
/// 返回按桶号升序排列的分桶列表；空输入返回空列表。
/// 桶内按 uuid 升序（canonical 序列化前提）。
pub fn split_table_items(table: &str, items: Vec<Value>) -> Vec<TableChunk> {
    let mut grouped: BTreeMap<u32, Vec<Value>> = BTreeMap::new();
    for item in items {
        let uuid = item.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
        grouped.entry(bucket_of_uuid(uuid)).or_default().push(item);
    }

    grouped
        .into_iter()
        .map(|(bucket, mut items)| {
            items.sort_by(|a, b| {
                let ua = a.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
                let ub = b.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
                ua.cmp(ub)
            });
            TableChunk {
                table: table.to_string(),
                bucket,
                items,
            }
        })
        .collect()
}

/// 分桶归属的可读桶键（两位零填充，与云端路径一致）
pub fn bucket_key(bucket: u32) -> String {
    format!("{bucket:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn bucket_of_uuid_is_stable_and_in_range() {
        for uuid in ["a", "b", "abc123", "0f8c1e2d-0000-4000-8000-000000000001"] {
            let b = bucket_of_uuid(uuid);
            assert!(b < TABLE_BUCKET_COUNT, "{uuid} 桶号越界: {b}");
            assert_eq!(b, bucket_of_uuid(uuid), "同 uuid 桶号必须稳定");
        }
    }

    #[test]
    fn empty_uuid_falls_back_to_zero_bucket() {
        assert_eq!(bucket_of_uuid(""), 0);
    }

    #[test]
    fn bucket_of_uuid_spreads_across_buckets() {
        // 1000 个不同 uuid 至少覆盖 30 个桶（防哈希退化为常量）
        let mut seen = std::collections::HashSet::new();
        for i in 0..1000 {
            seen.insert(bucket_of_uuid(&format!("uuid-{i}")));
        }
        assert!(seen.len() >= 30, "分桶过于集中: {} 个", seen.len());
    }

    #[test]
    fn split_groups_by_uuid_and_sorts_within_bucket() {
        // 构造同桶行（桶号由 uuid 决定，用实际计算值反推）
        let u1 = "stable-uuid-1";
        let u2 = "stable-uuid-1-x";
        let b1 = bucket_of_uuid(u1);
        let b2 = bucket_of_uuid(u2);
        let items = vec![
            json!({"uuid": u1, "title": "A"}),
            json!({"uuid": u2, "title": "B"}),
        ];
        let chunks = split_table_items("todo_tasks", items);
        // 两个 uuid 落在不同桶时得到两个分桶；同桶时得到 1 个
        let total: usize = chunks.iter().map(|c| c.items.len()).sum();
        assert_eq!(total, 2, "切分不得丢行");
        if b1 != b2 {
            assert_eq!(chunks.len(), 2);
        } else {
            assert_eq!(chunks.len(), 1);
        }
        // 桶号升序
        for pair in chunks.windows(2) {
            assert!(pair[0].bucket < pair[1].bucket);
        }
    }

    #[test]
    fn split_is_order_independent() {
        // 输入顺序不同 → 同一分桶的内容与指纹必须一致（差量前提）
        let items_a = vec![
            json!({"uuid": "u-a", "title": "A", "updated_at": 1}),
            json!({"uuid": "u-b", "title": "B", "updated_at": 2}),
            json!({"uuid": "u-c", "title": "C", "updated_at": 3}),
        ];
        let items_b = vec![
            json!({"uuid": "u-c", "title": "C", "updated_at": 3}),
            json!({"uuid": "u-a", "title": "A", "updated_at": 1}),
            json!({"uuid": "u-b", "title": "B", "updated_at": 2}),
        ];
        let ca = split_table_items("todo_tasks", items_a);
        let cb = split_table_items("todo_tasks", items_b);
        assert_eq!(ca.len(), cb.len());
        for (a, b) in ca.iter().zip(cb.iter()) {
            assert_eq!(a.bucket, b.bucket);
            assert_eq!(a.fingerprint().unwrap(), b.fingerprint().unwrap());
        }
    }

    #[test]
    fn single_row_edit_only_changes_its_own_bucket() {
        // 核心收益：改一行 → 只有一个桶的指纹变化
        let mut items: Vec<Value> = (0..200)
            .map(|i| json!({"uuid": format!("uuid-{i}"), "title": format!("T{i}")}))
            .collect();
        let before = split_table_items("todo_tasks", items.clone());

        // 修改其中一行的业务字段（并推进 updated_at，其不参与指纹）
        items[5]["title"] = json!("changed");
        items[5]["updated_at"] = json!(9_999);
        let after = split_table_items("todo_tasks", items);

        let changed = before
            .iter()
            .zip(after.iter())
            .filter(|(a, b)| a.fingerprint().unwrap() != b.fingerprint().unwrap())
            .count();
        assert_eq!(changed, 1, "单行编辑必须只影响一个分桶（差异上传前提）");
    }

    #[test]
    fn chunk_payload_roundtrip() {
        let chunk = TableChunk {
            table: "todo_tasks".to_string(),
            bucket: 3,
            items: vec![json!({"uuid": "u1", "title": "A"})],
        };
        let bytes = chunk.to_payload_bytes().unwrap();
        let parsed: ChunkPayload = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.table, "todo_tasks");
        assert_eq!(parsed.bucket, 3);
        assert_eq!(parsed.items.len(), 1);
    }

    #[test]
    fn bucket_key_is_zero_padded() {
        assert_eq!(bucket_key(0), "00");
        assert_eq!(bucket_key(63), "63");
    }
}
