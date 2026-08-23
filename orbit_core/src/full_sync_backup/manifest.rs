//! manifest — 备份清单结构与校验
//!
//! ZIP 归档内 `manifest.json` 文件的结构定义，包含备份元数据与各表记录数统计。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};

/// 当前 manifest 格式版本
pub const CURRENT_FORMAT_VERSION: u32 = 1;

/// 备份清单
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BackupManifest {
    /// manifest 格式版本（当前为 1）
    pub format_version: u32,
    /// 备份生成时间（RFC3339 字符串）
    pub created_at: String,
    /// 备份生成时间（Unix 秒）
    pub created_at_ts: i64,
    /// 应用版本（来自 Cargo.toml）
    pub app_version: String,
    /// 源设备 ID
    pub device_id: String,
    /// 源设备名称（可选）
    pub device_name: Option<String>,
    /// 数据库 schema 版本号
    pub schema_version: i64,
    /// 各业务表记录数（key=表名，value=未删除记录数）
    pub table_counts: BTreeMap<String, usize>,
}

impl BackupManifest {
    /// 创建新 manifest
    pub fn new(
        device_id: String,
        device_name: Option<String>,
        schema_version: i64,
        table_counts: BTreeMap<String, usize>,
        created_at_ts: i64,
        app_version: String,
    ) -> Self {
        let created_at = chrono::DateTime::<chrono::Utc>::from_timestamp(created_at_ts, 0)
            .map(|dt| dt.to_rfc3339())
            .unwrap_or_default();
        Self {
            format_version: CURRENT_FORMAT_VERSION,
            created_at,
            created_at_ts,
            app_version,
            device_id,
            device_name,
            schema_version,
            table_counts,
        }
    }

    /// 序列化为 JSON 字符串
    pub fn to_json(&self) -> FullSyncBackupResult<String> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// 从 JSON 字符串反序列化
    pub fn from_json(json: &str) -> FullSyncBackupResult<Self> {
        let manifest: Self = serde_json::from_str(json)?;
        Ok(manifest)
    }

    /// 校验 format_version 是否为当前支持的版本
    pub fn validate_format_version(&self) -> FullSyncBackupResult<()> {
        if self.format_version != CURRENT_FORMAT_VERSION {
            return Err(FullSyncBackupError::InvalidFormat(format!(
                "不支持的 manifest format_version: {}（当前仅支持 {}）",
                self.format_version, CURRENT_FORMAT_VERSION
            )));
        }
        Ok(())
    }

    /// 总记录数
    pub fn total_records(&self) -> usize {
        self.table_counts.values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_manifest() -> BackupManifest {
        let mut counts = BTreeMap::new();
        counts.insert("rec_books".to_string(), 10);
        counts.insert("todo_tasks".to_string(), 5);
        BackupManifest::new(
            "dev-001".to_string(),
            Some("My Device".to_string()),
            1,
            counts,
            1_700_000_000,
            "0.3.7".to_string(),
        )
    }

    #[test]
    fn manifest_json_roundtrip() {
        let original = sample_manifest();
        let json = original.to_json().unwrap();
        let parsed = BackupManifest::from_json(&json).unwrap();
        assert_eq!(parsed, original);
    }

    #[test]
    fn manifest_format_version_defaults_to_1() {
        let m = sample_manifest();
        assert_eq!(m.format_version, CURRENT_FORMAT_VERSION);
        assert_eq!(m.format_version, 1);
    }

    #[test]
    fn validate_format_version_accepts_current() {
        let m = sample_manifest();
        assert!(m.validate_format_version().is_ok());
    }

    #[test]
    fn validate_format_version_rejects_future() {
        let mut m = sample_manifest();
        m.format_version = 99;
        assert!(m.validate_format_version().is_err());
    }

    #[test]
    fn total_records_sums_counts() {
        let m = sample_manifest();
        assert_eq!(m.total_records(), 15);
    }

    #[test]
    fn manifest_with_empty_device_id_serializes() {
        let m = BackupManifest::new(
            "".to_string(),
            None,
            1,
            BTreeMap::new(),
            1_700_000_000,
            "0.3.7".to_string(),
        );
        let json = m.to_json().unwrap();
        let parsed = BackupManifest::from_json(&json).unwrap();
        assert_eq!(parsed, m);
        assert!(parsed.device_id.is_empty());
        assert!(parsed.device_name.is_none());
    }

    #[test]
    fn manifest_created_at_is_rfc3339() {
        let m = BackupManifest::new(
            "dev".to_string(),
            None,
            1,
            BTreeMap::new(),
            1_700_000_000,
            "0.3.7".to_string(),
        );
        // RFC3339 包含 'T' 分隔符
        assert!(m.created_at.contains('T'));
    }
}
