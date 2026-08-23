//! config_enc 模块统一错误类型

use thiserror::Error;

/// 配置加密错误
#[derive(Debug, Error)]
pub enum ConfigEncError {
    /// OS 安全存储不可用（keyring 损坏或权限被撤销）
    #[error("CEK 不可用: {0}")]
    CekUnavailable(String),

    /// 文件 I/O 错误
    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),

    /// 加密原语错误
    #[error("加密错误: {0}")]
    Crypto(#[from] crate::crypto::error::CryptoError),

    /// JSON 序列化/反序列化错误
    #[error("序列化错误: {0}")]
    Serde(#[from] serde_json::Error),

    /// 文件格式损坏（长度不足、nonce 缺失等）
    #[error("文件损坏: {0}")]
    Corrupted(String),
}

/// 便捷 Result 别名
pub type ConfigEncResult<T> = Result<T, ConfigEncError>;
