//! full_sync_backup — 全量同步备份模块（v3 新增，v4 扩展调度）
//!
//! 提供 `.orfullsync` 全量备份格式的核心实现（遗留 `.waitfullsync` / `.orsync` 读侧兼容）：
//! - 二进制容器读写（`container`）
//! - 备份命名规范（`backup_naming`）
//! - 备份清单（`manifest`）
//! - 偏好设置持久化 + 调度配置（`backup_prefs`）
//! - 调度时间计算纯函数（`scheduler`，v4 新增）
//! - ZIP 打包 + AES-GCM 加密（`encoder`）
//! - AES-GCM 解密 + ZIP 解压 + 全量覆盖恢复（`decoder`）
//! - 备份目录扫描/列表/删除/仅保留最新（`backup_repository`）
//! - 错误类型（`error`）
//!
//! 加密体系与 `sync_crypto_meta` / `master_auth` 完全一致：
//! PBKDF2-HMAC-SHA256（200000 迭代，16B salt） + AES-256-GCM

pub mod backup_naming;
pub mod backup_prefs;
pub mod backup_repository;
pub mod container;
pub mod decoder;
pub mod encoder;
pub mod error;
pub mod manifest;
pub mod scheduler;

pub use backup_naming::{
    FILE_EXTENSION, FILE_PREFIX, LEGACY_FILE_EXTENSIONS, generate_backup_filename,
    is_backup_filename, sanitize_device_id,
};
pub use backup_prefs::{
    BackupPrefs, PREFS_FILENAME, ScheduleType, load_prefs, prefs_path, save_prefs,
};
pub use backup_repository::{
    BackupEntry, DEFAULT_BACKUP_DIR_NAME, delete_backup, keep_latest_backup, list_backups,
};
pub use container::{
    FullSyncHeader, HEADER_SIZE as CONTAINER_HEADER_SIZE, ITERATIONS as CONTAINER_ITERATIONS,
    LEGACY_MAGIC as CONTAINER_LEGACY_MAGIC, MAGIC as CONTAINER_MAGIC, NONCE_LEN, SALT_LEN,
    build_container, parse_container,
};
pub use decoder::{DecodedBackup, decode_backup};
pub use encoder::{EncodeParams, EncodeResult, encode_backup};
pub use error::{FullSyncBackupError, FullSyncBackupResult};
pub use manifest::{BackupManifest, CURRENT_FORMAT_VERSION};
pub use scheduler::calculate_next_backup_at;
