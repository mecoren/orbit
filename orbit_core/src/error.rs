//! error — 统一错误类型
//!
//! 全 crate 统一 CoreError，各子模块错误通过 #[from] 转换。
//! 双端映射：
//! - Tauri：command 返回 Result<T, CoreError>，前端 catch 接收序列化错误
//! - FRB：Result<T, CoreError> → Dart 自动生成 CoreError 异常类

use thiserror::Error;

/// 核心库统一错误
#[derive(Debug, Error)]
pub enum CoreError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),

    #[error("数据库迁移错误: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),

    #[error("加密错误: {0}")]
    Crypto(#[from] crate::crypto::error::CryptoError),

    #[error("同步错误: {0}")]
    Sync(String),

    #[error("序列化错误: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("未认证或主密码未解锁")]
    Unauthenticated,

    #[error("未找到: {0}")]
    NotFound(String),

    #[error("配置错误: {field}: {message}")]
    Config { field: String, message: String },

    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),

    #[error("{0}")]
    Other(String),
}

/// SyncError → CoreError::Sync(String) 自动转换
///
/// 允许在 sync_diag_api / asset_api 等编排层用 `?` 直接传播 create_adapter / validate_config
/// 返回的 SyncError，无需每处手写 map_err。
impl From<crate::sync::error::SyncError> for CoreError {
    fn from(e: crate::sync::error::SyncError) -> Self {
        CoreError::Sync(e.to_string())
    }
}

/// 便捷 Result 别名
pub type CoreResult<T> = Result<T, CoreError>;
