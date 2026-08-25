//! meta — 云端元数据结构
//!
//! 定义云端 `_meta.json`、`modules/<name>/meta.json`、`modules/<name>/data.json`
//! 三种文件的 JSON 结构。所有文件在传输前经 `crypto_io::encrypt_payload` 加密。
//!
//! ## 云端目录结构
//! ```text
//! {base_path}/
//! ├── _meta.json                      # GlobalMeta（加密）
//! ├── crypto/
//! │   └── config                      # Data Key bundle（不加密，由 sync_crypto 管理）
//! ├── modules/
//! │   ├── movies/
//! │   │   ├── data.json               # ModuleData（加密）
//! │   │   └── meta.json               # ModuleMeta（加密）
//! │   └── ...（15 个模块）
//! └── media/
//!     └── <sha256>                    # 附件（加密）
//! ```

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// 全局元数据（对应云端 `_meta.json`，加密后上传）
///
/// 索引所有模块的指纹、记录数、墓碑集。Pull 时先下载此文件决定哪些模块需要拉取。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalMeta {
    /// 元数据格式版本（当前为 1）
    pub version: u32,
    /// 最后上传设备 ID（用于诊断，不参与合并决策）
    pub device_id: String,
    /// 最后上传时间（Unix 毫秒）
    pub updated_at: i64,
    /// 模块元数据映射（key = 模块名，如 "movies"）
    pub modules: BTreeMap<String, ModuleMetaEntry>,
}

impl GlobalMeta {
    /// 构造空的全局元数据（首次同步场景）
    pub fn empty(device_id: &str) -> Self {
        Self {
            version: 1,
            device_id: device_id.to_string(),
            updated_at: 0,
            modules: BTreeMap::new(),
        }
    }

    /// 获取指定模块的元数据
    pub fn module(&self, name: &str) -> Option<&ModuleMetaEntry> {
        self.modules.get(name)
    }
}

/// 墓碑条目（兼容旧格式 Vec<String> 与新格式 {uuid, deleted_at}）
///
/// 旧格式（无时间戳）：JSON 字符串 `"uuid-abc"`，反序列化为 `deleted_at=0`
/// 新格式（带时间戳）：JSON 对象 `{"uuid":"uuid-abc","deleted_at":1700000000000}`
///
/// `deleted_at=0` 的旧格式墓碑在 pull 时不参与时间戳裁决（直接删除，向后兼容）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TombstoneEntry {
    /// 新格式：uuid + 删除时间戳
    WithTimestamp {
        uuid: String,
        deleted_at: i64,
    },
    /// 旧格式：仅 uuid（向后兼容，deleted_at 视为 0）
    Legacy(String),
}

impl TombstoneEntry {
    /// 获取 uuid
    pub fn uuid(&self) -> &str {
        match self {
            TombstoneEntry::WithTimestamp { uuid, .. } => uuid,
            TombstoneEntry::Legacy(uuid) => uuid,
        }
    }

    /// 获取删除时间戳（旧格式返回 0，不参与时间戳裁决）
    pub fn deleted_at(&self) -> i64 {
        match self {
            TombstoneEntry::WithTimestamp { deleted_at, .. } => *deleted_at,
            TombstoneEntry::Legacy(_) => 0,
        }
    }

    /// 构造带时间戳的新格式墓碑
    pub fn new(uuid: String, deleted_at: i64) -> Self {
        TombstoneEntry::WithTimestamp { uuid, deleted_at }
    }
}

/// 模块元数据条目（GlobalMeta.modules 的 value 类型，也是 modules/<name>/meta.json 的内容）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModuleMetaEntry {
    /// 模块指纹（sha256 hex）
    pub fp: String,
    /// 记录数（不含软删除）
    pub count: u64,
    /// 墓碑集（所有软删除记录，无上限；含 deleted_at 时间戳用于删除vs编辑冲突裁决）
    pub deleted_ids: Vec<TombstoneEntry>,
    /// 最后更新时间（Unix 毫秒）
    pub updated_at: i64,
}

impl ModuleMetaEntry {
    /// 构造空条目（指纹为空字符串，触发首次全量同步）
    pub fn empty() -> Self {
        Self {
            fp: String::new(),
            count: 0,
            deleted_ids: Vec::new(),
            updated_at: 0,
        }
    }
}

/// 模块数据（对应云端 `modules/<name>/data.json`，加密后上传）
///
/// `items` 是该模块所有未删除记录的 JSON 数组，每条记录含 `uuid` 和 `updated_at`
/// 用于 item 级 LWW 合并。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModuleData {
    /// 模块名（如 "movies"）
    pub module: String,
    /// 记录数组（每条是原始 DB 行的 JSON 表示）
    pub items: Vec<serde_json::Value>,
    /// 导出时间（Unix 毫秒）
    pub exported_at: i64,
}

impl ModuleData {
    /// 构造空模块数据
    pub fn empty(module: &str) -> Self {
        Self {
            module: module.to_string(),
            items: Vec::new(),
            exported_at: 0,
        }
    }
}

/// 墓碑集最大容量（已废弃：墓碑不再有上限，所有软删除记录均上传）
/// 保留常量名供迁移参考，实际不再使用。
// pub const MAX_DELETED_IDS: usize = 500;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn global_meta_empty_has_no_modules() {
        let meta = GlobalMeta::empty("device-001");
        assert_eq!(meta.version, 1);
        assert_eq!(meta.device_id, "device-001");
        assert!(meta.modules.is_empty());
        assert_eq!(meta.updated_at, 0);
    }

    #[test]
    fn global_meta_module_lookup() {
        let mut meta = GlobalMeta::empty("device-001");
        meta.modules.insert(
            "movies".to_string(),
            ModuleMetaEntry {
                fp: "abc123".to_string(),
                count: 10,
                deleted_ids: vec![TombstoneEntry::Legacy("uuid-old".to_string())],
                updated_at: 1000,
            },
        );

        let m = meta.module("movies").unwrap();
        assert_eq!(m.fp, "abc123");
        assert_eq!(m.count, 10);
        assert_eq!(m.deleted_ids.len(), 1);
    }

    #[test]
    fn global_meta_module_lookup_missing() {
        let meta = GlobalMeta::empty("device-001");
        assert!(meta.module("nonexistent").is_none());
    }

    #[test]
    fn module_meta_empty_has_empty_fp() {
        let m = ModuleMetaEntry::empty();
        assert!(m.fp.is_empty());
        assert_eq!(m.count, 0);
        assert!(m.deleted_ids.is_empty());
    }

    #[test]
    fn module_data_empty_has_no_items() {
        let d = ModuleData::empty("books");
        assert_eq!(d.module, "books");
        assert!(d.items.is_empty());
    }

    #[test]
    fn global_meta_serializes_to_json() {
        let mut meta = GlobalMeta::empty("device-001");
        meta.modules.insert(
            "todos".to_string(),
            ModuleMetaEntry {
                fp: "fp123".to_string(),
                count: 5,
                deleted_ids: vec![
                    TombstoneEntry::new("u1".to_string(), 100),
                    TombstoneEntry::new("u2".to_string(), 200),
                ],
                updated_at: 12345,
            },
        );

        let json = serde_json::to_string(&meta).unwrap();
        let parsed: GlobalMeta = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.device_id, "device-001");
        assert_eq!(parsed.module("todos").unwrap().count, 5);
    }

    #[test]
    fn module_data_serializes_with_items() {
        let data = ModuleData {
            module: "movies".to_string(),
            items: vec![
                json!({"uuid": "m1", "title": "Movie 1", "updated_at": 100}),
                json!({"uuid": "m2", "title": "Movie 2", "updated_at": 200}),
            ],
            exported_at: 12345,
        };

        let json = serde_json::to_string(&data).unwrap();
        let parsed: ModuleData = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.items.len(), 2);
        assert_eq!(
            parsed.items[0].get("uuid").and_then(|v| v.as_str()),
            Some("m1")
        );
    }

    #[test]
    fn btreemap_keys_are_sorted_in_json() {
        // BTreeMap 保证序列化时 key 按字典序，确保指纹一致性
        let mut meta = GlobalMeta::empty("d");
        meta.modules.insert("zebra".to_string(), ModuleMetaEntry::empty());
        meta.modules.insert("apple".to_string(), ModuleMetaEntry::empty());
        meta.modules.insert("mango".to_string(), ModuleMetaEntry::empty());

        let json = serde_json::to_string(&meta).unwrap();
        let apple_pos = json.find("apple").unwrap();
        let mango_pos = json.find("mango").unwrap();
        let zebra_pos = json.find("zebra").unwrap();
        assert!(apple_pos < mango_pos);
        assert!(mango_pos < zebra_pos);
    }

    #[test]
    fn tombstone_entry_serializes_new_format_with_timestamp() {
        let entry = TombstoneEntry::new("uuid-abc".to_string(), 1_700_000_000_000);
        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("uuid"));
        assert!(json.contains("deleted_at"));
        assert!(json.contains("1700000000000"));
    }

    #[test]
    fn tombstone_entry_deserializes_legacy_string_format() {
        // 旧格式：纯字符串 "uuid-abc"
        let json = serde_json::json!("uuid-abc").to_string();
        let entry: TombstoneEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(entry.uuid(), "uuid-abc");
        assert_eq!(entry.deleted_at(), 0, "旧格式 deleted_at 应为 0");
        assert!(matches!(entry, TombstoneEntry::Legacy(_)));
    }

    #[test]
    fn tombstone_entry_deserializes_new_object_format() {
        let json = r#"{"uuid":"uuid-xyz","deleted_at":1700000000000}"#;
        let entry: TombstoneEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.uuid(), "uuid-xyz");
        assert_eq!(entry.deleted_at(), 1_700_000_000_000);
        assert!(matches!(entry, TombstoneEntry::WithTimestamp { .. }));
    }

    #[test]
    fn tombstone_entry_roundtrip_preserves_timestamp() {
        let entry = TombstoneEntry::new("uuid-roundtrip".to_string(), 1_234_567_890_000);
        let json = serde_json::to_string(&entry).unwrap();
        let parsed: TombstoneEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.uuid(), entry.uuid());
        assert_eq!(parsed.deleted_at(), entry.deleted_at());
    }
}
