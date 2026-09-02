//! backup_prefs — 备份偏好设置持久化（v3 新增，v4 扩展调度字段）
//!
//! 持久化到 `app_data_dir/full_sync_backup_prefs.json`：
//! - `local_path`：本地存储路径（None 时回退到 `app_data_dir/backups/`）
//! - `keep_latest`：仅保留最新备份开关
//! - `schedule_type` / `schedule_time` / `schedule_minute` / ...：v4 调度配置
//! - `last_backup_at` / `next_backup_at`：调度器状态

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};

/// 偏好设置文件名
pub const PREFS_FILENAME: &str = "full_sync_backup_prefs.json";

/// 调度类型（v4 新增）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleType {
    /// 关闭（默认）
    #[default]
    Off,
    /// 每小时
    Hourly,
    /// 每天
    Daily,
    /// 每周
    Weekly,
    /// 每月
    Monthly,
    /// 每年
    Yearly,
}

/// 调度时刻默认值（"03:00"）
fn default_schedule_time() -> String {
    "03:00".to_string()
}

/// 默认值 1（用于 day_of_month / month）
fn one() -> u32 {
    1
}

/// 备份偏好设置
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BackupPrefs {
    /// 本地存储路径（None 时回退到 `app_data_dir/backups/`）
    #[serde(default)]
    pub local_path: Option<String>,

    /// 仅保留最新备份（默认 false）
    #[serde(default)]
    pub keep_latest: bool,

    /// 云端备份开关（默认 false）
    ///
    /// 关闭时即使存在激活的云端同步配置，也不会上传备份文件到云端。
    /// 用户需显式开启才会执行云端上传阶段。
    #[serde(default)]
    pub cloud_backup_enabled: bool,

    /// 本地备份开关（默认 false）
    ///
    /// 关闭时不写入本地 `.waitfullsync` 文件。
    /// 用户需显式开启才会执行本地写入阶段。
    #[serde(default)]
    pub local_backup_enabled: bool,

    /// v4 新增：调度类型
    #[serde(default)]
    pub schedule_type: ScheduleType,

    /// v4 新增：调度时刻（"HH:mm"），用于 daily/weekly/monthly/yearly
    #[serde(default = "default_schedule_time")]
    pub schedule_time: String,

    /// v4 新增：分钟（0-59），用于 hourly
    #[serde(default)]
    pub schedule_minute: u32,

    /// v4 新增：星期几（0-6，0=周日），用于 weekly
    #[serde(default)]
    pub schedule_weekday: u32,

    /// v4 新增：月内日期（1-28），用于 monthly/yearly
    #[serde(default = "one")]
    pub schedule_day_of_month: u32,

    /// v4 新增：月份（1-12），用于 yearly
    #[serde(default = "one")]
    pub schedule_month: u32,

    /// v4 新增：上次成功执行时间戳（Unix 秒）
    #[serde(default)]
    pub last_backup_at: i64,

    /// v4 新增：下次计划执行时间戳（Unix 秒）
    #[serde(default)]
    pub next_backup_at: i64,
}

impl Default for BackupPrefs {
    fn default() -> Self {
        Self {
            local_path: None,
            keep_latest: false,
            cloud_backup_enabled: false,
            local_backup_enabled: false,
            schedule_type: ScheduleType::Off,
            schedule_time: default_schedule_time(),
            schedule_minute: 0,
            schedule_weekday: 0,
            schedule_day_of_month: one(),
            schedule_month: one(),
            last_backup_at: 0,
            next_backup_at: 0,
        }
    }
}

impl BackupPrefs {
    /// 解析 "HH:mm" 字符串为 (hour, minute)
    pub fn parse_schedule_time(time: &str) -> Option<(u32, u32)> {
        let parts: Vec<&str> = time.split(':').collect();
        if parts.len() != 2 {
            return None;
        }
        let h: u32 = parts[0].parse().ok()?;
        let m: u32 = parts[1].parse().ok()?;
        if h > 23 || m > 59 {
            return None;
        }
        Some((h, m))
    }

    /// 校验调度配置有效性
    pub fn validate_schedule(&self) -> FullSyncBackupResult<()> {
        use ScheduleType::*;
        match self.schedule_type {
            Off => Ok(()),
            Hourly => {
                if self.schedule_minute > 59 {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_minute 超出范围：{}（应为 0-59）",
                        self.schedule_minute
                    )));
                }
                Ok(())
            }
            Daily | Weekly | Monthly | Yearly => {
                // 校验 HH:mm 格式
                let (h, m) = Self::parse_schedule_time(&self.schedule_time).ok_or_else(|| {
                    FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_time 格式错误：{}（应为 HH:mm）",
                        self.schedule_time
                    ))
                })?;
                if h > 23 {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_time 小时超出范围：{}（应为 0-23）",
                        h
                    )));
                }
                if m > 59 {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_time 分钟超出范围：{}（应为 0-59）",
                        m
                    )));
                }

                // weekly 校验 weekday
                if matches!(self.schedule_type, Weekly) && self.schedule_weekday > 6 {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_weekday 超出范围：{}（应为 0-6，0=周日）",
                        self.schedule_weekday
                    )));
                }

                // monthly/yearly 校验 day_of_month
                if matches!(self.schedule_type, Monthly | Yearly)
                    && (self.schedule_day_of_month < 1 || self.schedule_day_of_month > 28)
                {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_day_of_month 超出范围：{}（应为 1-28，避免月末歧义）",
                        self.schedule_day_of_month
                    )));
                }

                // yearly 校验 month
                if matches!(self.schedule_type, Yearly)
                    && (self.schedule_month < 1 || self.schedule_month > 12)
                {
                    return Err(FullSyncBackupError::InvalidSchedule(format!(
                        "schedule_month 超出范围：{}（应为 1-12）",
                        self.schedule_month
                    )));
                }

                Ok(())
            }
        }
    }
}

/// 偏好设置文件路径
pub fn prefs_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(PREFS_FILENAME)
}

/// 加密存储中使用的配置名（不含扩展名）
pub const PREFS_ENC_NAME: &str = "full_sync_backup_prefs";

/// 加载偏好设置；文件不存在时返回默认值
///
/// 加密优先：若全局 `EncryptedConfigStorage` 已注册，从 `.enc` 文件读取；
/// 否则降级到明文 `.json`。
pub fn load_prefs(app_data_dir: &Path) -> FullSyncBackupResult<BackupPrefs> {
    // 加密存储优先
    if let Some(storage) = crate::config_enc::get_global_storage() {
        match storage.load::<BackupPrefs>(PREFS_ENC_NAME) {
            Ok(Some(prefs)) => return Ok(prefs),
            Ok(None) => return Ok(BackupPrefs::default()),
            Err(e) => {
                // 加密读取失败，降级到明文
                log::info!("[backup_prefs] 加密存储读取失败，降级明文: {}", e);
            }
        }
    }
    // 降级：明文 .json
    let path = prefs_path(app_data_dir);
    if !path.exists() {
        return Ok(BackupPrefs::default());
    }
    let content = std::fs::read_to_string(&path)?;
    let prefs: BackupPrefs = serde_json::from_str(&content)?;
    Ok(prefs)
}

/// 保存偏好设置
///
/// 加密优先：若全局 `EncryptedConfigStorage` 已注册，写入 `.enc` 文件；
/// 否则降级到明文 `.json`。
pub fn save_prefs(app_data_dir: &Path, prefs: &BackupPrefs) -> FullSyncBackupResult<()> {
    // 加密存储优先
    if let Some(storage) = crate::config_enc::get_global_storage() {
        match storage.save(PREFS_ENC_NAME, prefs) {
            Ok(()) => return Ok(()),
            Err(e) => {
                log::info!("[backup_prefs] 加密存储写入失败，降级明文: {}", e);
            }
        }
    }
    // 降级：明文 .json
    let path = prefs_path(app_data_dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let content = serde_json::to_string_pretty(prefs)?;
    std::fs::write(&path, content)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn default_prefs_has_off_schedule() {
        let prefs = BackupPrefs::default();
        assert_eq!(prefs.schedule_type, ScheduleType::Off);
        assert!(!prefs.keep_latest);
        assert!(prefs.local_path.is_none());
        assert_eq!(prefs.schedule_time, "03:00");
        assert_eq!(prefs.schedule_day_of_month, 1);
        assert_eq!(prefs.schedule_month, 1);
    }

    #[test]
    fn parse_schedule_time_valid() {
        assert_eq!(BackupPrefs::parse_schedule_time("03:00"), Some((3, 0)));
        assert_eq!(BackupPrefs::parse_schedule_time("23:59"), Some((23, 59)));
        assert_eq!(BackupPrefs::parse_schedule_time("00:00"), Some((0, 0)));
    }

    #[test]
    fn parse_schedule_time_invalid() {
        assert_eq!(BackupPrefs::parse_schedule_time("25:00"), None);
        assert_eq!(BackupPrefs::parse_schedule_time("12:60"), None);
        assert_eq!(BackupPrefs::parse_schedule_time("12"), None);
        assert_eq!(BackupPrefs::parse_schedule_time(""), None);
        assert_eq!(BackupPrefs::parse_schedule_time("abc:def"), None);
    }

    #[test]
    fn validate_schedule_off_always_ok() {
        let prefs = BackupPrefs::default();
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_hourly_valid() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Hourly,
            schedule_minute: 30,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_hourly_invalid_minute() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Hourly,
            schedule_minute: 60,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn validate_schedule_daily_valid() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Daily,
            schedule_time: "12:30".to_string(),
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_daily_invalid_time_format() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Daily,
            schedule_time: "25:00".to_string(),
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn validate_schedule_weekly_valid() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Weekly,
            schedule_time: "10:00".to_string(),
            schedule_weekday: 3,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_weekly_invalid_weekday() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Weekly,
            schedule_time: "10:00".to_string(),
            schedule_weekday: 7,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn validate_schedule_monthly_valid() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Monthly,
            schedule_time: "10:00".to_string(),
            schedule_day_of_month: 15,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_monthly_invalid_day() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Monthly,
            schedule_time: "10:00".to_string(),
            schedule_day_of_month: 29, // 超出 1-28
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn validate_schedule_monthly_invalid_day_zero() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Monthly,
            schedule_time: "10:00".to_string(),
            schedule_day_of_month: 0,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn validate_schedule_yearly_valid() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Yearly,
            schedule_time: "10:00".to_string(),
            schedule_month: 6,
            schedule_day_of_month: 15,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_ok());
    }

    #[test]
    fn validate_schedule_yearly_invalid_month() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Yearly,
            schedule_time: "10:00".to_string(),
            schedule_month: 13,
            schedule_day_of_month: 15,
            ..Default::default()
        };
        assert!(prefs.validate_schedule().is_err());
    }

    #[test]
    fn save_then_load_prefs_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let prefs = BackupPrefs {
            local_path: Some("/tmp/backups".to_string()),
            keep_latest: true,
            schedule_type: ScheduleType::Daily,
            schedule_time: "12:30".to_string(),
            ..Default::default()
        };

        save_prefs(tmp.path(), &prefs).unwrap();
        let loaded = load_prefs(tmp.path()).unwrap();
        assert_eq!(loaded, prefs);
    }

    #[test]
    fn load_prefs_missing_file_returns_default() {
        let tmp = TempDir::new().unwrap();
        let loaded = load_prefs(tmp.path()).unwrap();
        assert_eq!(loaded, BackupPrefs::default());
    }

    #[test]
    fn save_prefs_creates_parent_dir() {
        let tmp = TempDir::new().unwrap();
        // tmp 路径存在但 prefs 文件不存在；save 应创建父目录（已存在则不报错）
        let prefs = BackupPrefs::default();
        save_prefs(tmp.path(), &prefs).unwrap();
        assert!(prefs_path(tmp.path()).exists());
    }

    #[test]
    fn schedule_type_serde_lowercase() {
        let prefs = BackupPrefs {
            schedule_type: ScheduleType::Hourly,
            ..Default::default()
        };
        let json = serde_json::to_string(&prefs).unwrap();
        assert!(json.contains("\"hourly\""));
    }
}
