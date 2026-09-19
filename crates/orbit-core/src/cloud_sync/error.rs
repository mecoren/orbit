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

    /// 认证错误（HTTP 401/403）：凭据不正确或权限不足。
    ///
    /// S6（2026-09-13 探查，基线 P1-5）：此前 SyncError::Auth 被折叠进
    /// `Adapter`（文案保留"认证错误"但丢失类型），with_retry 对网络类
    /// 整体重试——密钥配错时每轮白等 2/4/8s×3 重试后仍失败。保留类型
    /// 让 with_retry 按类型排除认证错误立即返回，UI 也能按 tag 引导。
    #[error("认证错误: {message}")]
    Auth { message: String },

    /// 限流（429 / 坚果云 503 限流响应）：需 30/60/120s 长退避。
    ///
    /// S6：与 SyncError::RateLimited 对应，从适配器类型化透传，
    /// 替代消息 contains("429") 嗅探。
    #[error("请求被限流: {message}")]
    RateLimited { message: String },

    /// 远端资源不存在（HTTP 404 / 坚果云 409 AncestorsNotFound）。
    ///
    /// Fix-09：适配器层已按状态码构造类型化错误，此处保留类型穿透，
    /// 供 push/pull/bundle_io 做「云端无此文件」分支判断，不再字符串嗅探。
    #[error("远端资源不存在: {message}")]
    NotFound { message: String },

    #[error("同步加密未解锁：请先输入同步密码")]
    CryptoLocked,

    #[error(
        "Data Key 与云端密文不匹配：本地已解锁但解密云端数据失败，需走恢复流程（重输密码无效）"
    )]
    KeyMismatch,

    /// 云端载荷/清单版本高于本客户端支持上限（ADR 0010 决定 3）
    ///
    /// 必须独立于 `KeyMismatch`：解密失败统一塌进密钥错误会把用户导向
    /// 密钥恢复页，而真正的处置动作是「升级应用」——云端数据并未损坏。
    /// 同类地也不能落进 `Crypto`（`is_password_error` 为真 → 跳解锁页）。
    #[error("云端数据版本过新: {message}")]
    PayloadVersionMismatch { message: String },

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
            // F32：409 父目录缺失在上层语义等同「云端无此文件」
            // （坚果云对不存在路径回 409）——与 F32 之前 `download_object`
            // 手工改写为 NotFound 的行为一致，避免塌进 Adapter 丢掉分支判据。
            crate::sync::error::SyncError::AncestorsNotFound { message } => {
                CloudSyncError::NotFound { message }
            }
            // S6：认证/限流类型透传——with_retry 按类型排除认证错误、
            // 限流走长退避；不再依赖消息文案判定
            crate::sync::error::SyncError::Auth { message } => CloudSyncError::Auth { message },
            crate::sync::error::SyncError::RateLimited { message } => {
                CloudSyncError::RateLimited { message }
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
    ///
    /// S6：认证（Auth）与限流（RateLimited）不再归入——认证错误重试
    /// 无意义（应引导用户改配置），限流单独走 `is_rate_limited` 长退避
    /// 分支；归入 network 会让 with_retry 对两者都做短退避重试。
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
    /// S6：优先类型判断（`RateLimited` 变体，适配器按状态码构造）；
    /// 兼容 `Adapter` 内嵌历史文案（429/BlockedTemporarily 等非适配器
    /// 构造路径），嗅探加 "HTTP 429" 状态码锚点防巧合子串。
    /// 限流错误需要更长退避（30/60/120 秒），而非默认的 2/4/8 秒。
    /// 识别限流后 `with_retry` 使用专用退避策略，避免加剧限流。
    pub fn is_rate_limited(&self) -> bool {
        if matches!(self, CloudSyncError::RateLimited { .. }) {
            return true;
        }
        let msg = self.to_string();
        msg.contains("HTTP 429")
            || msg.contains("认证失败(429)")
            || msg.contains("BlockedTemporarily")
            || msg.contains("Too many requests")
            || msg.contains("too many requests")
            || msg.contains("rate limit")
            || msg.contains("Rate limit")
    }

    /// 是否为认证错误（凭据/权限问题，重试无意义）
    ///
    /// S6（基线 P1-5）：`with_retry` 对认证错误立即返回不重试——
    /// 密钥配错时每轮同步白等 2/4/8s×3 共 ~14s 才失败，纯属浪费。
    pub fn is_auth_error(&self) -> bool {
        matches!(self, CloudSyncError::Auth { .. })
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
    /// 返回 `password`/`key_mismatch`/`payload_version`/`database`/`network`/`other` 之一——纯 tag
    /// 不带方括号，桥层 `format!("[{}] …")` 统一加括号。曾因 tag 自带括号被
    /// 桥层再包一层产出 `[[key_mismatch]]`，前端 `^\[(\w+)\]` 正则失配导致
    /// KeyMismatch 恢复引导失效（2026-09-10 修复）。前端通过字符串前缀匹配
    /// 解析错误类型，决定重试/跳转/阻塞行为。
    ///
    /// `key_mismatch` 优先级高于 `password`：本地已解锁但解密云端密文失败
    /// 必须走恢复流程，而非引导用户重输密码（重输只会循环回同一错误）。
    pub fn category_tag(&self) -> &'static str {
        if self.is_key_mismatch_error() {
            "key_mismatch"
        } else if matches!(self, CloudSyncError::PayloadVersionMismatch { .. }) {
            // ADR 0010 决定 3：云端版本比本客户端新，处置动作是「升级应用」。
            // 落 "other" 会被读成未知故障，落 password/key_mismatch 会跳错页面
            "payload_version"
        } else if self.is_password_error() {
            "password"
        } else if self.is_database_error() {
            "database"
        } else if self.is_auth_error() {
            // S6：认证错误单独归类——引导用户检查凭据/权限而非泛化网络重试
            "auth"
        } else if self.is_rate_limited() {
            // 限流归类 network（可重试），长退避由 with_retry 的
            // is_rate_limited 分支处理；tag 供 UI 展示具体原因
            "rate_limited"
        } else if self.is_network_error() {
            "network"
        } else {
            "other"
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
        assert_eq!(err.category_tag(), "key_mismatch");
    }

    #[test]
    fn crypto_locked_still_classified_as_password() {
        // 回归测试：CryptoLocked 仍归为 password（无 Data Key，需跳转解锁页）
        let err = CloudSyncError::CryptoLocked;
        assert!(err.is_password_error());
        assert!(!err.is_key_mismatch_error());
        assert_eq!(err.category_tag(), "password");
    }

    #[test]
    fn crypto_with_message_still_classified_as_password() {
        // 回归测试：Crypto { .. } 仍归为 password（保持现有 UI 行为不变）
        let err = CloudSyncError::Crypto {
            message: "zstd 失败".to_string(),
        };
        assert!(err.is_password_error());
        assert_eq!(err.category_tag(), "password");
    }

    #[test]
    fn database_error_tag_is_database() {
        let err = CloudSyncError::Database {
            message: "sqlite".to_string(),
        };
        assert_eq!(err.category_tag(), "database");
    }

    #[test]
    fn adapter_error_tag_is_network() {
        let err = CloudSyncError::Adapter {
            message: "conn".to_string(),
        };
        assert_eq!(err.category_tag(), "network");
    }

    // ========================================================================
    // S6（2026-09-13 探查，基线 P1-5）：Auth/RateLimited 类型透传
    // ========================================================================

    #[test]
    fn sync_error_auth_passes_through_as_auth_variant() {
        let err: CloudSyncError = crate::sync::error::SyncError::Auth {
            message: "认证失败(403): forbidden".to_string(),
        }
        .into();
        assert!(err.is_auth_error());
        assert!(
            !err.is_network_error(),
            "认证错误不得归入网络类（否则 with_retry 白等重试）"
        );
        assert_eq!(err.category_tag(), "auth");
    }

    #[test]
    fn sync_error_rate_limited_passes_through() {
        let err: CloudSyncError = crate::sync::error::SyncError::RateLimited {
            message: "Too Many Requests".to_string(),
        }
        .into();
        assert!(err.is_rate_limited(), "类型化限流必须被识别");
        assert!(
            !err.is_network_error(),
            "限流不得归入普通网络类（长退避分支依赖 is_rate_limited 单独判定）"
        );
        assert_eq!(err.category_tag(), "rate_limited");
    }

    #[test]
    fn adapter_error_with_legacy_429_text_still_detected() {
        // 兼容：非适配器构造的 Adapter 错误内嵌历史限流文案仍可识别
        let err = CloudSyncError::Adapter {
            message: "HTTP 429: Too Many Requests".to_string(),
        };
        assert!(err.is_rate_limited());
    }

    #[test]
    fn adapter_error_with_4291_substring_not_rate_limited() {
        // 回归：巧含 "429" 子串不再误判限流（不再触发 120s 白等）
        let err = CloudSyncError::Adapter {
            message: "object size 4291 bytes".to_string(),
        };
        assert!(!err.is_rate_limited());
    }
}
