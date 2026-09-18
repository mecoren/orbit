//! meta — 云端清单（唯一真相源）与墓碑结构
//!
//! ## 为什么是「单一清单」
//! 云端只有一份 [`Manifest`]（`manifest.orsync`），承载：
//! - `epoch`：乐观并发版本号（写入前置条件，见 push 的 CAS）
//! - `tables`：表名 → 分桶索引（桶号 → 指纹/行数/字节数）
//! - `tombstones`：表名 → 墓碑分桶索引（月份键 → 指纹/条数/最大删除时间）
//! - `devices`：设备 → 同步检查点（墓碑回收水位线依据）
//!
//! ## 载荷加密
//! 所有云端文件（manifest 与各分桶）在传输前经
//! [`crate::cloud_sync::crypto_io::encrypt_payload`] 用 Data Key 加密。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// 当前云端布局版本（初始版本，未来协议演进判别依据）
pub const LAYOUT_VERSION: u32 = 1;

/// 单个数据分桶的索引条目
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChunkRef {
    /// 分桶 canonical JSON 的 sha256（排除 updated_at/id）
    pub fp: String,
    /// 桶内记录数（未软删）
    pub count: u64,
    /// 桶明文序列化字节数（供大小策略与预估）
    pub size: u64,
}

/// 单张表的分桶索引（桶号 → 分桶条目）
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct TableIndex {
    pub chunks: BTreeMap<u32, ChunkRef>,
}

impl TableIndex {
    /// 该表是否无任何数据分桶
    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }
}

/// 单个墓碑分桶的索引条目
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TombstoneBucketRef {
    /// 分桶 canonical JSON 的 sha256
    pub fp: String,
    /// 桶内墓碑条数
    pub count: u64,
    /// 桶内最大删除时间（Unix 毫秒；回收判据）
    pub max_deleted_at: i64,
}

/// 单张表的墓碑分桶索引（月份键 → 分桶条目）
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct TombstoneIndex {
    pub buckets: BTreeMap<String, TombstoneBucketRef>,
}

impl TombstoneIndex {
    /// 该表是否无墓碑分桶
    pub fn is_empty(&self) -> bool {
        self.buckets.is_empty()
    }
}

/// 设备同步检查点（墓碑安全回收的水位线依据）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceCheckpoint {
    /// 该设备最后一次成功同步的本地时间（Unix 毫秒）
    pub last_synced_at: i64,
}

/// 云端唯一真相源清单
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    /// 布局版本（当前 [`LAYOUT_VERSION`]）
    pub layout_version: u32,
    /// 乐观并发版本号：每次成功写入 +1，写入前须匹配读到的值
    pub epoch: u64,
    /// 最后写入设备（诊断用，不参与裁决）
    pub device_id: String,
    /// 最后写入时间（Unix 毫秒）
    pub updated_at: i64,
    /// 表名 → 数据分桶索引
    pub tables: BTreeMap<String, TableIndex>,
    /// 表名 → 墓碑分桶索引
    pub tombstones: BTreeMap<String, TombstoneIndex>,
    /// 设备 → 同步检查点
    pub devices: BTreeMap<String, DeviceCheckpoint>,
}

impl Manifest {
    /// 构造空清单（首次同步场景）
    pub fn empty(device_id: &str) -> Self {
        Self {
            layout_version: LAYOUT_VERSION,
            epoch: 0,
            device_id: device_id.to_string(),
            updated_at: 0,
            tables: BTreeMap::new(),
            tombstones: BTreeMap::new(),
            devices: BTreeMap::new(),
        }
    }

    /// 取某表的分桶索引（缺失视为空）
    pub fn table(&self, name: &str) -> Option<&TableIndex> {
        self.tables.get(name)
    }

    /// 取某表的墓碑分桶索引（缺失视为空）
    pub fn tombstone_index(&self, name: &str) -> Option<&TombstoneIndex> {
        self.tombstones.get(name)
    }

    /// 墓碑回收水位线（Unix 毫秒）
    ///
    /// 取所有设备检查点的**最小值**：只有早于「最落后设备上次成功同步时间」
    /// 的墓碑才确定已被所有设备看到，可以安全回收。
    ///
    /// 保守策略：设备数 < 2（单设备或尚未登记）返回 0，即**不回收**——
    /// 单设备场景没有"其他设备需要看到墓碑"的约束，但新设备加入时仍需要
    /// 完整墓碑来判断删除；宁可不回收也不冒复活风险。
    pub fn tombstone_watermark(&self) -> i64 {
        if self.devices.len() < 2 {
            return 0;
        }
        self.devices
            .values()
            .map(|c| c.last_synced_at)
            .min()
            .unwrap_or(0)
    }

    /// 登记/更新本机检查点
    pub fn touch_device(&mut self, device_id: &str, last_synced_at: i64) {
        self.devices.insert(
            device_id.to_string(),
            DeviceCheckpoint { last_synced_at },
        );
    }
}

/// 墓碑条目（uuid + 原始删除时间）
///
/// 删除时间参与「删除 vs 编辑」裁决（`merge::apply_tombstones`），
/// 必须保留删除发生时的原始时间戳，不能写成同步时刻。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TombstoneEntry {
    /// 记录 uuid
    pub uuid: String,
    /// 软删除时间（Unix 毫秒）
    pub deleted_at: i64,
}

impl TombstoneEntry {
    pub fn new(uuid: String, deleted_at: i64) -> Self {
        Self { uuid, deleted_at }
    }

    pub fn uuid(&self) -> &str {
        &self.uuid
    }

    pub fn deleted_at(&self) -> i64 {
        self.deleted_at
    }
}

/// 墓碑分桶载荷（加密后写入 `tombstones/{table}/{YYYY-MM}.orsync`）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TombstoneBucketPayload {
    /// 表名
    pub table: String,
    /// 分桶键（本地时区 `YYYY-MM`）
    pub bucket: String,
    /// 墓碑条目
    pub tombstones: Vec<TombstoneEntry>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_manifest_has_layout_version_and_zero_epoch() {
        let m = Manifest::empty("dev-1");
        assert_eq!(m.layout_version, LAYOUT_VERSION);
        assert_eq!(m.epoch, 0);
        assert!(m.tables.is_empty());
        assert!(m.tombstones.is_empty());
        assert!(m.devices.is_empty());
    }

    #[test]
    fn watermark_requires_two_devices() {
        let mut m = Manifest::empty("dev-1");
        m.touch_device("dev-1", 100);
        assert_eq!(m.tombstone_watermark(), 0, "单设备不得回收墓碑");
    }

    #[test]
    fn watermark_is_min_of_devices() {
        let mut m = Manifest::empty("dev-1");
        m.touch_device("dev-1", 900);
        m.touch_device("dev-2", 300);
        m.touch_device("dev-3", 600);
        assert_eq!(m.tombstone_watermark(), 300);
    }

    #[test]
    fn table_index_lookup_defaults_missing() {
        let m = Manifest::empty("d");
        assert!(m.table("todo_tasks").is_none());
        assert!(m.tombstone_index("todo_tasks").is_none());
    }

    #[test]
    fn manifest_serializes_with_stable_btreemap_order() {
        let mut m = Manifest::empty("d");
        m.tables.insert(
            "todo_tasks".to_string(),
            TableIndex {
                chunks: BTreeMap::from([(
                    3,
                    ChunkRef {
                        fp: "fp3".to_string(),
                        count: 1,
                        size: 10,
                    },
                )]),
            },
        );
        m.tables.insert("todo_projects".to_string(), TableIndex::default());
        let json = serde_json::to_string(&m).unwrap();
        let p1 = json.find("todo_projects").unwrap();
        let p2 = json.find("todo_tasks").unwrap();
        assert!(p1 < p2, "BTreeMap 保证 key 字典序，序列化须确定性");
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.tables.len(), 2);
    }

    #[test]
    fn tombstone_entry_roundtrip_preserves_timestamp() {
        let e = TombstoneEntry::new("u1".to_string(), 1_700_000_000_000);
        let json = serde_json::to_string(&e).unwrap();
        assert!(json.contains("deleted_at"));
        let parsed: TombstoneEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.uuid(), "u1");
        assert_eq!(parsed.deleted_at(), 1_700_000_000_000);
    }

    #[test]
    fn tombstone_bucket_payload_roundtrip() {
        let p = TombstoneBucketPayload {
            table: "todo_tasks".to_string(),
            bucket: "2026-09".to_string(),
            tombstones: vec![TombstoneEntry::new("u1".to_string(), 10)],
        };
        let bytes = serde_json::to_vec(&p).unwrap();
        let parsed: TombstoneBucketPayload = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.bucket, "2026-09");
        assert_eq!(parsed.tombstones.len(), 1);
    }
}
