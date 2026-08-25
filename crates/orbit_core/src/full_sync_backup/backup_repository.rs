//! backup_repository — 备份目录扫描/列表/删除/仅保留最新（v3 新增）
//!
//! 参考 legado `AppConfig.backupPath` + `AppConfig.onlyLatestBackup` 实现：
//! - 扫描备份目录下的 `backup*.waitfullsync` 文件
//! - 按文件名倒序排列（最新在前）
//! - 提供"仅保留最新"策略实现

use std::path::{Path, PathBuf};

use crate::full_sync_backup::backup_naming::is_backup_filename;
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};

/// 默认备份目录名（相对于 app_data_dir）
pub const DEFAULT_BACKUP_DIR_NAME: &str = "backups";

/// 备份条目
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct BackupEntry {
    /// 文件名（不含目录）
    pub filename: String,
    /// 完整路径
    pub file_path: PathBuf,
    /// 文件大小（字节）
    pub file_size: u64,
    /// 最后修改时间（Unix 秒）
    pub modified_at: i64,
}

/// 获取备份目录路径
///
/// - 若 prefs.local_path 已设置且非空，使用该路径
/// - 否则回退到 `app_data_dir/backups/`
pub fn resolve_backup_dir(app_data_dir: &Path, local_path: Option<&str>) -> PathBuf {
    if let Some(p) = local_path {
        let trimmed = p.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    app_data_dir.join(DEFAULT_BACKUP_DIR_NAME)
}

/// 列出备份目录下的所有 `backup*.waitfullsync` 文件
///
/// 按文件名倒序排列（最新日期在前，参考 legado AlphanumComparator + reversed）
pub fn list_backups(backup_dir: &Path) -> FullSyncBackupResult<Vec<BackupEntry>> {
    if !backup_dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries: Vec<BackupEntry> = Vec::new();

    for entry in std::fs::read_dir(backup_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let filename = match path.file_name().and_then(|n| n.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        if !is_backup_filename(&filename) {
            continue;
        }

        let metadata = entry.metadata()?;
        let file_size = metadata.len();
        let modified_at = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        entries.push(BackupEntry {
            filename,
            file_path: path,
            file_size,
            modified_at,
        });
    }

    // 按文件名倒序排列（最新日期在前）
    entries.sort_by(|a, b| b.filename.cmp(&a.filename));

    Ok(entries)
}

/// 删除指定备份文件
pub fn delete_backup(file_path: &Path) -> FullSyncBackupResult<()> {
    if !file_path.exists() {
        return Err(FullSyncBackupError::Other(format!(
            "文件不存在: {}",
            file_path.display()
        )));
    }
    std::fs::remove_file(file_path)?;
    Ok(())
}

/// 仅保留最新备份：删除 `keep_file` 之外的所有 `backup*.waitfullsync` 文件
///
/// 返回被删除的文件路径列表
pub fn keep_latest_backup(
    backup_dir: &Path,
    keep_file: &Path,
) -> FullSyncBackupResult<Vec<PathBuf>> {
    let entries = list_backups(backup_dir)?;
    let mut deleted: Vec<PathBuf> = Vec::new();

    for entry in entries {
        if entry.file_path == keep_file {
            continue;
        }
        // 仅删除符合 backup*.waitfullsync 命名规范的文件（双重检查）
        if !is_backup_filename(&entry.filename) {
            continue;
        }
        match std::fs::remove_file(&entry.file_path) {
            Ok(()) => deleted.push(entry.file_path),
            Err(e) => {
                // 单个删除失败不阻塞整体流程，记录到错误日志
                log::info!(
                    "[keep_latest_backup] 删除失败: {} - {}",
                    entry.file_path.display(),
                    e
                );
            }
        }
    }

    Ok(deleted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_backup_file(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"dummy content").unwrap();
        path
    }

    #[test]
    fn resolve_backup_dir_uses_local_path_when_set() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolve_backup_dir(tmp.path(), Some("/custom/path"));
        assert_eq!(resolved, PathBuf::from("/custom/path"));
    }

    #[test]
    fn resolve_backup_dir_uses_default_when_local_path_empty() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolve_backup_dir(tmp.path(), Some(""));
        assert_eq!(resolved, tmp.path().join(DEFAULT_BACKUP_DIR_NAME));
    }

    #[test]
    fn resolve_backup_dir_uses_default_when_local_path_none() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolve_backup_dir(tmp.path(), None);
        assert_eq!(resolved, tmp.path().join(DEFAULT_BACKUP_DIR_NAME));
    }

    #[test]
    fn list_backups_empty_dir_returns_empty() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        let entries = list_backups(&dir).unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn list_backups_nonexistent_dir_returns_empty() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("nonexistent");

        let entries = list_backups(&dir).unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn list_backups_returns_only_backup_files() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        create_backup_file(&dir, "backup2026-07-20-abc.waitfullsync");
        create_backup_file(&dir, "backup2026-07-19-abc.waitfullsync");
        create_backup_file(&dir, "backup2026-07-18.waitfullsync");
        // 非 backup 前缀
        create_backup_file(&dir, "data.zip");
        create_backup_file(&dir, "readme.txt");
        // 错误扩展名
        create_backup_file(&dir, "backup2026-07-17.zip");

        let entries = list_backups(&dir).unwrap();
        assert_eq!(entries.len(), 3);
        // 倒序：最新日期在前
        assert_eq!(entries[0].filename, "backup2026-07-20-abc.waitfullsync");
        assert_eq!(entries[1].filename, "backup2026-07-19-abc.waitfullsync");
        assert_eq!(entries[2].filename, "backup2026-07-18.waitfullsync");
    }

    #[test]
    fn list_backups_sorted_descending_by_filename() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        // 故意乱序创建
        create_backup_file(&dir, "backup2026-07-15.waitfullsync");
        create_backup_file(&dir, "backup2026-07-20.waitfullsync");
        create_backup_file(&dir, "backup2026-07-10.waitfullsync");

        let entries = list_backups(&dir).unwrap();
        assert_eq!(entries[0].filename, "backup2026-07-20.waitfullsync");
        assert_eq!(entries[1].filename, "backup2026-07-15.waitfullsync");
        assert_eq!(entries[2].filename, "backup2026-07-10.waitfullsync");
    }

    #[test]
    fn delete_backup_removes_file() {
        let tmp = TempDir::new().unwrap();
        let path = create_backup_file(tmp.path(), "backup2026-07-20.waitfullsync");

        assert!(path.exists());
        delete_backup(&path).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn delete_backup_nonexistent_fails() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("nonexistent.waitfullsync");

        let result = delete_backup(&path);
        assert!(result.is_err());
    }

    #[test]
    fn keep_latest_deletes_others_but_keeps_target() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        let keep = create_backup_file(&dir, "backup2026-07-20.waitfullsync");
        let _old1 = create_backup_file(&dir, "backup2026-07-19.waitfullsync");
        let _old2 = create_backup_file(&dir, "backup2026-07-18.waitfullsync");
        // 非 backup 前缀，不应被删除
        let _other = create_backup_file(&dir, "data.zip");

        let deleted = keep_latest_backup(&dir, &keep).unwrap();

        assert_eq!(deleted.len(), 2);
        assert!(keep.exists());
        assert!(_other.exists(), "非 backup 前缀文件不应被删除");
    }

    #[test]
    fn keep_latest_with_only_target_deletes_nothing() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        let keep = create_backup_file(&dir, "backup2026-07-20.waitfullsync");

        let deleted = keep_latest_backup(&dir, &keep).unwrap();
        assert!(deleted.is_empty());
        assert!(keep.exists());
    }

    #[test]
    fn backup_entry_has_file_size_and_modified_time() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("backups");
        fs::create_dir_all(&dir).unwrap();

        let path = create_backup_file(&dir, "backup2026-07-20.waitfullsync");
        let expected_size = fs::metadata(&path).unwrap().len();

        let entries = list_backups(&dir).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].file_size, expected_size);
        assert!(entries[0].modified_at > 0, "modified_at 应大于 0");
    }
}
