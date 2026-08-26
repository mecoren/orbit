use serde::{Deserialize, Serialize};
use thiserror::Error;

/// 同步加密错误类型
#[derive(Debug, Error, Clone, Serialize, Deserialize)]
pub enum SyncCryptoError {
    #[error("同步密码错误")]
    WrongPassword,

    #[error("加密错误: {message}")]
    Crypto { message: String },

    #[error("元数据文件错误: {message}")]
    Meta { message: String },

    #[error("未初始化：请先设置同步密码")]
    NotInitialized,

    #[error("未解锁：请先输入同步密码")]
    NotUnlocked,

    #[error("云端 crypto bundle 错误: {message}")]
    Bundle { message: String },

    /// 云端资源不存在（crypto/config 等路径 404 / 409 AncestorsNotFound）。
    ///
    /// 历史问题：适配器 404 曾被扁平化为 `Adapter` 字符串错误，
    /// 调用方（cloud_sync::engine）只能对消息做 `contains("404")` 嗅探。
    /// 现在 `From<SyncError>` 保留类型，调用方用 `matches!` 判断。
    #[error("云端资源不存在: {path}")]
    NotFound { path: String },

    /// 本地已存在不同的同步加密元数据，拒绝静默覆盖（Fix-10）。
    ///
    /// 调用方确认要替换本地 Data Key 后，以 `force = true` 重试。
    #[error("本地已设置同步密码且与云端不一致：覆盖将切换本机 Data Key，需用户确认")]
    LocalMetaExists,

    #[error("适配器错误: {message}")]
    Adapter { message: String },
}

impl From<crate::crypto::CryptoError> for SyncCryptoError {
    fn from(err: crate::crypto::CryptoError) -> Self {
        // AES-GCM 解密失败通常意味着密码错误
        match err.kind {
            crate::crypto::CryptoErrorKind::DecryptionFailed => SyncCryptoError::WrongPassword,
            _ => SyncCryptoError::Crypto {
                message: err.message,
            },
        }
    }
}

impl From<crate::sync_bundle::SyncBundleError> for SyncCryptoError {
    fn from(err: crate::sync_bundle::SyncBundleError) -> Self {
        SyncCryptoError::Bundle {
            message: err.message,
        }
    }
}

impl From<crate::sync::error::SyncError> for SyncCryptoError {
    fn from(err: crate::sync::error::SyncError) -> Self {
        match err {
            // 保留「资源不存在」类型，供上层做 404 分支判断（不再字符串嗅探）
            crate::sync::error::SyncError::NotFound { message } => {
                SyncCryptoError::NotFound { path: message }
            }
            other => SyncCryptoError::Adapter {
                message: other.to_string(),
            },
        }
    }
}
