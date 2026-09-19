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

use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::cloud_sync::error::CloudSyncError;

/// 当前云端布局版本（初始版本，未来协议演进判别依据）
pub const LAYOUT_VERSION: u32 = 1;

/// 本机上报的版本串（写入 `DeviceCheckpoint::app_version`）
///
/// 口径复用 `env!("CARGO_PKG_VERSION")`：与全量备份清单的 `app_version` 同源，
/// 且由 `pnpm bump:check` 与 release-consistency 测试守护五处清单一致。
pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// AAD 绑定写入的能力阈值（ADR 0010 决定 2 的「第二拍」版本号）
///
/// 只有当清单内**全部**已登记设备的 `app_version ≥ 此值` 时，push 才允许把
/// 表桶写成 0x02（绑定密文）。当前发布版本 0.1.0 低于此值 → 门禁恒关闭；
/// 具备绑定写入能力的下一版（0.2.0）上线后，门禁自动在「全网升级完成」时打开，
/// 无需再改代码——这正是两拍发布要买的性质。
pub const AAD_MIN_APP_VERSION: &str = "0.2.0";

/// 语义化版本比较：`actual >= min`
///
/// 只比主.次.补丁三段（预发布后缀与 build 号不参与协议能力门禁）；缺段与非数字
/// 段按 0 处理；空串恒 false——存量清单的 `app_version` 反序列化为空，
/// 语义即「版本未知的设备不得触发格式升级」。
fn version_at_least(actual: &str, min: &str) -> bool {
    if actual.is_empty() {
        return false;
    }
    let parse = |s: &str| -> [u64; 3] {
        let mut parts = s.split('.').map(|p| p.trim().parse::<u64>().unwrap_or(0));
        [
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
        ]
    };
    parse(actual) >= parse(min)
}

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

/// 设备同步检查点（墓碑安全回收的水位线依据 + 协议能力协商位）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceCheckpoint {
    /// 该设备最后一次成功同步的本地时间（Unix 毫秒）
    pub last_synced_at: i64,
    /// 该设备当时的应用版本（`APP_VERSION` 口径）
    ///
    /// 唯一的能力协商原语：清单是加密 JSON，加字段靠 serde default 兼容，
    /// **无迁移**。存量清单缺此字段 → 空串（版本未知），任何按版本收紧的
    /// 门禁都保守关闭（见 [`Manifest::all_devices_support_aad`]）。
    #[serde(default)]
    pub app_version: String,
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

    /// 登记/更新本机检查点（版本串取 [`APP_VERSION`]）
    pub fn touch_device(&mut self, device_id: &str, last_synced_at: i64) {
        self.devices.insert(
            device_id.to_string(),
            DeviceCheckpoint {
                last_synced_at,
                app_version: APP_VERSION.to_string(),
            },
        );
    }

    /// 布局版本门禁（pull 与 push 共用，ADR 0010 决定 1）
    ///
    /// 按**大小**判定，不是 `!=`：未来版本要报「请升级应用」而不是「数据损坏」，
    /// 上古/损坏密文才留在原口径。两处调用方曾各自复制一段 `!=` 判断，
    /// 复制即漂移——收在这一个方法里。
    pub fn check_layout_version(&self) -> Result<(), CloudSyncError> {
        match self.layout_version.cmp(&LAYOUT_VERSION) {
            Ordering::Equal => Ok(()),
            Ordering::Greater => Err(CloudSyncError::PayloadVersionMismatch {
                message: format!(
                    "云端清单布局版本 {} 高于本客户端支持的 {}，请升级应用后重试（云端数据未损坏）",
                    self.layout_version, LAYOUT_VERSION
                ),
            }),
            Ordering::Less => Err(CloudSyncError::Other {
                message: format!(
                    "云端清单布局版本 {} 不受支持（当前 {}）",
                    self.layout_version, LAYOUT_VERSION
                ),
            }),
        }
    }

    /// AAD 绑定写入门禁：清单内**全部**已登记设备是否都具备 0x02 读取能力
    ///
    /// 空设备表返回 false：首次推送时无法证明「云端没有旧设备」，宁可不绑。
    /// 同理，任一设备未上报版本（存量清单）也判 false——升级前不会有任何
    /// 设备被踢下线（ADR 0010 决定 2）。
    pub fn all_devices_support_aad(&self) -> bool {
        !self.devices.is_empty()
            && self
                .devices
                .values()
                .all(|c| version_at_least(&c.app_version, AAD_MIN_APP_VERSION))
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

    /// F45 兼容红线：存量云端清单里**没有** app_version 字段，必须照常解析
    /// （清单是加密 JSON，serde default 即免迁移；此测试挂了等于「老库读不了」）
    #[test]
    fn legacy_manifest_without_app_version_parses() {
        const LEGACY: &str = r#"{"layout_version":1,"epoch":7,"device_id":"d","updated_at":1,
            "tables":{},"tombstones":{},"devices":{"dev-old":{"last_synced_at":123}}}"#;
        let m: Manifest = serde_json::from_str(LEGACY).unwrap();
        assert_eq!(m.epoch, 7);
        assert_eq!(m.devices["dev-old"].app_version, "", "缺字段即版本未知");
        assert!(!m.all_devices_support_aad(), "版本未知的设备不得触发格式升级");
    }

    /// F46 门禁真值表：只有「全部已登记设备都达标」才允许写绑定密文
    #[test]
    fn aad_gate_requires_every_registered_device_upgraded() {
        let dev = |v: &str| DeviceCheckpoint {
            last_synced_at: 1,
            app_version: v.to_string(),
        };
        let mut m = Manifest::empty("d");
        assert!(!m.all_devices_support_aad(), "空设备表无法证明云端没有旧设备");
        m.devices.insert("a".to_string(), dev("0.2.0"));
        assert!(m.all_devices_support_aad(), "唯一设备已达标 → 可绑定");
        m.devices.insert("b".to_string(), dev("0.1.9"));
        assert!(
            !m.all_devices_support_aad(),
            "任一设备未达标即不得绑定（否则该设备当场被踢下线）"
        );
        m.devices.insert("c".to_string(), dev("1.0.0"));
        assert!(!m.all_devices_support_aad(), "补齐高版本不消掉那台落后设备");
    }

    /// 版本比较走数值而非字典序（0.10 必须大于 0.2）
    #[test]
    fn version_compare_is_numeric_not_lexicographic() {
        assert!(version_at_least("0.2.0", "0.2.0"));
        assert!(version_at_least("0.10.1", "0.2.0"));
        assert!(version_at_least("1", "0.2.0"), "缺段按 0 处理");
        assert!(version_at_least("0.2.0-beta.1", "0.2.0"), "预发布后缀不参与门禁");
        assert!(!version_at_least("0.1.9", "0.2.0"));
        assert!(!version_at_least("abc", "0.2.0"), "非数字段按 0 → 低于阈值");
        assert!(!version_at_least("", "0.0.0"), "空串恒 false（含阈值为 0 的情况）");
    }

    /// F43 布局版本门禁：未来版本 ≠ 上古版本（两处 `!=` 复制曾把两者混为一谈）
    #[test]
    fn layout_version_gate_distinguishes_future_from_ancient() {
        let mut m = Manifest::empty("d");
        assert!(m.check_layout_version().is_ok());

        m.layout_version = LAYOUT_VERSION + 1;
        let err = m.check_layout_version().unwrap_err();
        assert!(
            matches!(err, CloudSyncError::PayloadVersionMismatch { .. }),
            "实际: {err:?}"
        );
        assert_eq!(err.category_tag(), "payload_version");

        m.layout_version = LAYOUT_VERSION - 1;
        let err = m.check_layout_version().unwrap_err();
        assert!(
            matches!(err, CloudSyncError::Other { .. }),
            "上古/损坏仍沿用原「不受支持」口径，不冒充升级问题：实际 {err:?}"
        );
    }

    /// touch_device 必须把本机版本登记进清单——否则协商位永远是空的
    #[test]
    fn touch_device_records_local_app_version() {
        let mut m = Manifest::empty("dev-1");
        m.touch_device("dev-1", 42);
        assert_eq!(m.devices["dev-1"].app_version, APP_VERSION);
        assert_eq!(m.devices["dev-1"].last_synced_at, 42);
    }
}
