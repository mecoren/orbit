//! Manifest 合并算法：LWW + device_id tiebreaker
//!
//! 与 Dart 侧 `lib/services/sync/manifest.dart` 的 `mergeManifests` 行为完全一致。

use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Manifest 条目：单条记录的同步状态
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManifestEntry {
    /// 该记录的 lamport_version
    pub version: i64,
    /// 软删除标记
    pub deleted: bool,
    /// 最后修改时间（显示用，不参与 LWW）
    #[serde(rename = "updated_at")]
    pub updated_at: String,
}

/// 表级 Manifest：记录该表所有 UUID 的同步状态
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Manifest {
    pub table: String,
    /// manifest 自身的 Lamport 版本号
    pub version: i64,
    #[serde(rename = "generated_at")]
    pub generated_at: String,
    #[serde(rename = "device_id")]
    pub device_id: String,
    pub entries: BTreeMap<String, ManifestEntry>,
}

/// 合并两端 manifest：LWW + device_id tiebreaker
///
/// 策略：
/// 1. 以 theirs 为基准（merged = theirs.entries 的拷贝）
/// 2. 遍历 mine.entries，逐条比较：
///    - theirs 无此条目 → 加入 mine 的
///    - mine.version > theirs.version → 用 mine 的
///    - mine.version < theirs.version → 保留 theirs 的（已存在）
///    - 版本相同 → device_id 字符串比较，大者胜
/// 3. 返回的 manifest 使用 mine.device_id，Lamport 版本号为 max + 1
pub fn merge_manifests(mine: &Manifest, theirs: &Manifest) -> Manifest {
    let mut merged: BTreeMap<String, ManifestEntry> = theirs.entries.clone();

    for (uuid, my_entry) in &mine.entries {
        let Some(their_entry) = merged.get(uuid).cloned() else {
            merged.insert(uuid.clone(), my_entry.clone());
            continue;
        };

        if my_entry.version > their_entry.version {
            merged.insert(uuid.clone(), my_entry.clone());
        } else if my_entry.version < their_entry.version {
            continue;
        } else {
            if mine.device_id > theirs.device_id {
                merged.insert(uuid.clone(), my_entry.clone());
            }
        }
    }

    Manifest {
        table: mine.table.clone(),
        version: std::cmp::max(mine.version, theirs.version) + 1,
        generated_at: Utc::now().to_rfc3339(),
        device_id: mine.device_id.clone(),
        entries: merged,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn entry(version: i64, deleted: bool) -> ManifestEntry {
        ManifestEntry {
            version,
            deleted,
            updated_at: "2026-07-07T00:00:00Z".to_string(),
        }
    }

    fn manifest(device_id: &str, entries: Vec<(&str, ManifestEntry)>, version: i64) -> Manifest {
        let mut map = BTreeMap::new();
        for (k, v) in entries {
            map.insert(k.to_string(), v);
        }
        Manifest {
            table: "rec_movies".to_string(),
            version,
            generated_at: "2026-07-07T00:00:00Z".to_string(),
            device_id: device_id.to_string(),
            entries: map,
        }
    }

    #[test]
    fn merges_mine_only_entries() {
        let mine = manifest("deviceA", vec![("u1", entry(5, false))], 1);
        let theirs = manifest("deviceB", vec![], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries.len(), 1);
        assert_eq!(merged.entries["u1"].version, 5);
    }

    #[test]
    fn merges_theirs_only_entries() {
        let mine = manifest("deviceA", vec![], 1);
        let theirs = manifest("deviceB", vec![("u2", entry(7, false))], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries.len(), 1);
        assert_eq!(merged.entries["u2"].version, 7);
    }

    #[test]
    fn mine_newer_wins() {
        let mine = manifest("deviceA", vec![("u1", entry(10, false))], 1);
        let theirs = manifest("deviceB", vec![("u1", entry(3, false))], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries["u1"].version, 10);
    }

    #[test]
    fn theirs_newer_wins() {
        let mine = manifest("deviceA", vec![("u1", entry(3, false))], 1);
        let theirs = manifest("deviceB", vec![("u1", entry(10, false))], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries["u1"].version, 10);
    }

    #[test]
    fn equal_version_device_id_tiebreaker_theirs_wins() {
        let mine = manifest("deviceA", vec![("u1", entry(5, false))], 1);
        let theirs = manifest("deviceB", vec![("u1", entry(5, true))], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries["u1"].deleted, true);
    }

    #[test]
    fn equal_version_device_id_tiebreaker_mine_wins_when_lex_greater() {
        let mine = manifest("deviceZ", vec![("u1", entry(5, true))], 1);
        let theirs = manifest("deviceA", vec![("u1", entry(5, false))], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.entries["u1"].deleted, true);
    }

    #[test]
    fn merged_version_is_max_plus_one() {
        let mine = manifest("deviceA", vec![], 5);
        let theirs = manifest("deviceB", vec![], 8);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.version, 9);
    }

    #[test]
    fn merged_uses_mine_device_id_and_table() {
        let mine = manifest("deviceA", vec![], 1);
        let theirs = manifest("deviceB", vec![], 1);
        let merged = merge_manifests(&mine, &theirs);
        assert_eq!(merged.device_id, "deviceA");
        assert_eq!(merged.table, "rec_movies");
    }
}
