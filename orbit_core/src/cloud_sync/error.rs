//! error — 云端增量同步引擎错误类型
//!
//! 涵盖加密、数据库、适配器、模块、状态、合并、附件等同步流程中的错误场景。
//! 实现 `From` 转换以便 `?` 运算符跨层传播。

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// 云端同步错误类型
#[derive(Debug, Error, Clone, Serialize, Deserialize)]
pub enum CloudSyncError {
    #[error("加密错误: {message}")]
    Crypto { message: String },

    #[error("数据库错误: {message}")]
    Database { message: String },

    #[error("适配器错误: {message}")]
    Adapter { message: String },

    /// 远端资源不存在（HTTP 404 / 坚果云 409 AncestorsNotFound）。
    ///
    /// Fix-09：适配器层已按状态码构造类型化错误，此处保留类型穿透，
    /// 供 push/pull/bundle_io 做「云端无此文件」分支判断，不再字符串嗅探。
    #[error("远端资源不存在: {message}")]
    NotFound { message: String },

    #[error("同步加密未解锁：请先输入同步密码")]
    CryptoLocked,

    #[error("Data Key 与云端密文不匹配：本地已解锁但解密云端数据失败，需走恢复流程（重输密码无效）")]
    KeyMismatch,

    #[error("未知模块: {0}")]
    UnknownModule(String),

    #[error("远端元数据缺失: {0}")]
    RemoteMissing(String),

    #[error("本地状态文件错误: {message}")]
    State { message: String },

    #[error("合并失败: {message}")]
    Merge { message: String },

    #[error("附件错误: {message}")]
    Attachment { message: String },

    #[error("payload 过短，无法解密")]
    PayloadTooShort,

    #[error("同步互斥锁占用：已有同步任务在运行")]
    AlreadyRunning,

    #[error("序列化错误: {message}")]
    Serialize { message: String },

    #[error("其他错误: {message}")]
    Other { message: String },
}

impl From<crate::crypto::CryptoError> for CloudSyncError {
    fn from(err: crate::crypto::CryptoError) -> Self {
        CloudSyncError::Crypto {
            message: err.message,
        }
    }
}

impl From<crate::sync::error::SyncError> for CloudSyncError {
    fn from(err: crate::sync::error::SyncError) -> Self {
        match err {
            // Fix-09：保留「资源不存在」类型，供上层 404 分支判断
            crate::sync::error::SyncError::NotFound { message } => {
                CloudSyncError::NotFound { message }
            }
            other => CloudSyncError::Adapter {
                message: other.to_string(),
            },
        }
    }
}

impl From<crate::sync_crypto::SyncCryptoError> for CloudSyncError {
    fn from(err: crate::sync_crypto::SyncCryptoError) -> Self {
        match err {
            crate::sync_crypto::SyncCryptoError::NotUnlocked => CloudSyncError::CryptoLocked,
            other => CloudSyncError::Crypto {
                message: other.to_string(),
            },
        }
    }
}

impl From<sqlx::Error> for CloudSyncError {
    fn from(err: sqlx::Error) -> Self {
        CloudSyncError::Database {
            message: err.to_string(),
        }
    }
}

impl From<serde_json::Error> for CloudSyncError {
    fn from(err: serde_json::Error) -> Self {
        CloudSyncError::Serialize {
            message: err.to_string(),
        }
    }
}

impl From<std::io::Error> for CloudSyncError {
    fn from(err: std::io::Error) -> Self {
        CloudSyncError::State {
            message: err.to_string(),
        }
    }
}

impl From<crate::full_sync_backup::error::FullSyncBackupError> for CloudSyncError {
    /// 将全量同步备份错误转换为云端同步错误
    ///
    /// 用于同步前自动备份场景（功能⑤）。当前 `backup_before_sync` 采用宽松模式
    /// （手动 match 错误，不使用 `?`），此转换供未来需要传播备份错误时使用。
    fn from(err: crate::full_sync_backup::error::FullSyncBackupError) -> Self {
        use crate::full_sync_backup::error::FullSyncBackupError;
        match err {
            FullSyncBackupError::WrongSyncPassword => CloudSyncError::CryptoLocked,
            FullSyncBackupError::Crypto(e) => CloudSyncError::Crypto {
                message: e.to_string(),
            },
            FullSyncBackupError::Db(e) => CloudSyncError::Database {
                message: e.to_string(),
            },
            FullSyncBackupError::Io(e) => CloudSyncError::State {
                message: e.to_string(),
            },
            other => CloudSyncError::Other {
                message: other.to_string(),
            },
        }
    }
}

impl CloudSyncError {
    /// 是否为密码/加密错误（应跳转解锁页）
    ///
    /// 包括：同步加密未解锁、加密运算失败、密钥不匹配等。
    /// UI 层应跳转到密码解锁页，重试无意义（密码不会自动变对）。
    pub fn is_password_error(&self) -> bool {
        matches!(
            self,
            CloudSyncError::CryptoLocked | CloudSyncError::Crypto { .. }
        )
    }

    /// 是否为数据库错误（应阻塞进入）
    ///
    /// 包括：SQLite 读写失败、表结构异常等。
    /// UI 层应阻塞进入主页（本地数据问题），提示用户联系支持。
    pub fn is_database_error(&self) -> bool {
        matches!(self, CloudSyncError::Database { .. })
    }

    /// 是否为网络错误（可重试 / 离线进入）
    ///
    /// 包括：适配器连接失败、远端文件缺失等。
    /// UI 层应重试（指数退避），重试耗尽后提供"离线进入"选项。
    pub fn is_network_error(&self) -> bool {
        matches!(
            self,
            CloudSyncError::Adapter { .. }
                | CloudSyncError::NotFound { .. }
                | CloudSyncError::RemoteMissing(..)
        )
    }

    /// 是否为限流错误（429 或坚果云等服务的 503 限流）
    ///
    /// 限流错误需要更长退避（30/60/120 秒），而非默认的 2/4/8 秒。
    /// 识别限流后 `with_retry` 使用专用退避策略，避免加剧限流。
    pub fn is_rate_limited(&self) -> bool {
        let msg = self.to_string();
        // 429 Too Many Requests 是标准限流状态码
        if msg.contains("429") {
            return true;
        }
        // 坚果云等服务的 503 限流标识
        msg.contains("BlockedTemporarily")
            || msg.contains("Too many requests")
            || msg.contains("too many requests")
            || msg.contains("rate limit")
            || msg.contains("Rate limit")
    }

    /// 是否为 Data Key 不匹配错误（应跳转恢复页，而非解锁页）
    ///
    /// 与 `CryptoLocked`（无 Data Key，需要解锁）语义不同：
    /// `KeyMismatch` 表示本地已解锁持有 Data Key，但与云端加密数据用的 Key 不一致。
    /// 重输同步密码无意义（密码本身正确），需要走"以本机为准重加密重传"或
    /// "以云端为准放弃本地"的恢复流程。
    pub fn is_key_mismatch_error(&self) -> bool {
        matches!(self, CloudSyncError::KeyMismatch)
    }

    /// 错误分类标签（用于桥接层向前端传递分类信息）
    ///
    /// 返回 `[password]`/`[key_mismatch]`/`[database]`/`[network]`/`[other]` 之一，
    /// 前端通过字符串前缀匹配解析错误类型，决定重试/跳转/阻塞行为。
    ///
    /// `[key_mismatch]` 优先级高于 `[password]`：本地已解锁但解密云端密文失败
    /// 必须走恢复流程，而非引导用户重输密码（重输只会循环回同一错误）。
    pub fn category_tag(&self) -> &'static str {
        if self.is_key_mismatch_error() {
            "[key_mismatch]"
        } else if self.is_password_error() {
            "[password]"
        } else if self.is_database_error() {
            "[database]"
        } else if self.is_network_error() {
            "[network]"
        } else {
            "[other]"
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_mismatch_is_not_password_error() {
        // KeyMismatch 表示本地有 Data Key 但与云端密文不匹配，
        // 与 CryptoLocked（无 Data Key，需解锁）语义不同，不应跳转解锁页
        let err = CloudSyncError::KeyMismatch;
        assert!(
            !err.is_password_error(),
            "KeyMismatch 不应归类为 password 错误（否则 UI 会跳解锁页，重输密码无效）"
        );
        assert!(err.is_key_mismatch_error());
    }

    #[test]
    fn key_mismatch_category_tag_is_key_mismatch() {
        let err = CloudSyncError::KeyMismatch;
        assert_eq!(err.category_tag(), "[key_mismatch]");
    }

    #[test]
    fn crypto_locked_still_classified_as_password() {
        // 回归测试：CryptoLocked 仍归为 password（无 Data Key，需跳转解锁页）
        let err = CloudSyncError::CryptoLocked;
        assert!(err.is_password_error());
        assert!(!err.is_key_mismatch_error());
        assert_eq!(err.category_tag(), "[password]");
    }

    #[test]
    fn crypto_with_message_still_classified_as_password() {
        // 回归测试：Crypto { .. } 仍归为 password（保持现有 UI 行为不变）
        let err = CloudSyncError::Crypto {
            message: "zstd 失败".to_string(),
        };
        assert!(err.is_password_error());
        assert_eq!(err.category_tag(), "[password]");
    }

    #[test]
    fn database_error_tag_is_database() {
        let err = CloudSyncError::Database {
            message: "sqlite".to_string(),
        };
        assert_eq!(err.category_tag(), "[database]");
    }

    #[test]
    fn adapter_error_tag_is_network() {
        let err = CloudSyncError::Adapter {
            message: "conn".to_string(),
        };
        assert_eq!(err.category_tag(), "[network]");
    }
}
