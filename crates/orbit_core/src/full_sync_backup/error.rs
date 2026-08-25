//! error — 全量同步备份错误类型

use thiserror::Error;

/// 全量同步备份错误
#[derive(Debug, Error)]
pub enum FullSyncBackupError {
    #[error("同步密码错误")]
    WrongSyncPassword,

    #[error("文件格式错误: {0}")]
    InvalidFormat(String),

    #[error("文件头过短：期望 {expected} 字节，实际 {actual} 字节")]
    HeaderTooShort { expected: usize, actual: usize },

    #[error("magic 不匹配：期望 {expected:?}，实际 {got:?}")]
    MagicMismatch { expected: [u8; 4], got: [u8; 4] },

    #[error("schema 版本不匹配：备份={backup}，当前={current}")]
    SchemaVersionMismatch { backup: i64, current: i64 },

    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),

    #[error("加密错误: {0}")]
    Crypto(#[from] crate::crypto::CryptoError),

    #[error("序列化错误: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("ZIP 错误: {0}")]
    Zip(String),

    #[error("调度配置无效: {0}")]
    InvalidSchedule(String),

    /// 备份状态无效（如云端/本地开关均关闭）
    #[error("状态无效: {0}")]
    InvalidState(String),

    #[error("同步加密服务错误: {0}")]
    SyncCrypto(String),

    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),

    #[error("{0}")]
    Other(String),
}

impl From<crate::sync_crypto::SyncCryptoError> for FullSyncBackupError {
    fn from(err: crate::sync_crypto::SyncCryptoError) -> Self {
        match err {
            crate::sync_crypto::SyncCryptoError::WrongPassword => {
                FullSyncBackupError::WrongSyncPassword
            }
            other => FullSyncBackupError::SyncCrypto(other.to_string()),
        }
    }
}

impl From<zip::result::ZipError> for FullSyncBackupError {
    fn from(err: zip::result::ZipError) -> Self {
        FullSyncBackupError::Zip(err.to_string())
    }
}

/// 便捷 Result 别名
pub type FullSyncBackupResult<T> = Result<T, FullSyncBackupError>;
