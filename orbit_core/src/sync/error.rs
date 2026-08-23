use serde::{Deserialize, Serialize};
use thiserror::Error;

/// 同步引擎错误类型（v1，全量同步）
#[derive(Debug, Error, Clone, Serialize, Deserialize)]
pub enum SyncError {
    #[error("网络错误: {message}")]
    Network { message: String, retryable: bool },

    #[error("认证错误: {message}")]
    Auth { message: String },

    #[error("加密错误: {message}")]
    Crypto { message: String },

    #[error("冲突解决失败: {table}/{record_id}")]
    Conflict { table: String, record_id: String },

    #[error("数据库错误: {message}")]
    Database { message: String },

    #[error("配置错误: {field} - {message}")]
    Config { field: String, message: String },

    #[error("并发错误: {message}")]
    Concurrent { message: String },

    #[error("同步包格式错误: {message}")]
    Bundle { message: String },

    #[error("同步已取消: {message}")]
    Cancelled { message: String },

    /// 资源不存在（HTTP 404，或坚果云 WebDAV 对父目录缺失的 409 AncestorsNotFound）。
    ///
    /// 历史问题：404 曾被映射为 `SyncError::Network` 并在消息中携带 "404"，
    /// 调用方靠字符串匹配判定资源不存在——响应体偶然包含 "404" 子串会误判。
    /// 现由适配器按状态码构造本变体，`is_not_found()` 基于类型判断。
    #[error("资源不存在(404): {message}")]
    NotFound { message: String },
}

impl SyncError {
    /// 是否可重试
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            SyncError::Network {
                retryable: true,
                ..
            }
        )
    }

    /// 是否为限流错误（429 或包含限流标识的 503）
    ///
    /// 坚果云等 WebDAV 服务在请求过频时返回 503 + "BlockedTemporarily" /
    /// "Too many requests"。此类错误需要更长退避（30/60/120 秒），
    /// 而非默认的 2/4/8 秒，否则会加剧限流。
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

    /// 是否为「资源不存在」（404）错误
    ///
    /// 基于 `SyncError::NotFound` 变体的类型判断，不再做字符串匹配。
    /// 适配器层（`from_http_status` / WebDAV 409 AncestorsNotFound 翻译）负责构造该变体。
    pub fn is_not_found(&self) -> bool {
        matches!(self, SyncError::NotFound { .. })
    }

    /// 根据HTTP状态码构造对应错误
    pub fn from_http_status(status: u16, body: &str) -> Self {
        match status {
            401 | 403 => SyncError::Auth {
                message: format!("认证失败({status}): {body}"),
            },
            404 => SyncError::NotFound {
                message: body.to_string(),
            },
            500..=599 => SyncError::Network {
                message: format!("服务器错误({status}): {body}"),
                retryable: true,
            },
            _ => SyncError::Network {
                message: format!("HTTP {status}: {body}"),
                retryable: false,
            },
        }
    }

    /// DELETE 响应状态码判定（Fix-03，供 S3/WebDAV 适配器共用）
    ///
    /// 历史问题：两适配器的 `delete()` 完全不检查响应状态码——服务器返回
    /// 403/500 也返回 Ok(())。导致 KeyMismatch「覆盖云端」恢复流程中
    /// `sync_clear_cloud_global_meta` 删除失败却报成功（探针再次 KeyMismatch
    /// 死循环），且 crypto/config 路径迁移日志谎报删除成功。
    ///
    /// 判定规则：
    /// - 2xx：成功
    /// - 404：幂等成功（资源本就不存在，语义等价）
    /// - 5xx：可重试网络错误
    /// - 其他（401/403 等）：不可重试错误
    pub fn check_delete_status(status: u16) -> Result<(), Self> {
        match status {
            200..=299 | 404 => Ok(()),
            s if (500..=599).contains(&s) => Err(SyncError::Network {
                message: format!("DELETE 失败: HTTP {s}"),
                retryable: true,
            }),
            s => Err(SyncError::Network {
                message: format!("DELETE 失败: HTTP {s}（请检查账号权限）"),
                retryable: false,
            }),
        }
    }
}

impl From<crate::sync_bundle::SyncBundleError> for SyncError {
    fn from(err: crate::sync_bundle::SyncBundleError) -> Self {
        SyncError::Bundle {
            message: err.message,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_404_maps_to_not_found_variant() {
        let err = SyncError::from_http_status(404, "no such key");
        assert!(
            matches!(err, SyncError::NotFound { .. }),
            "404 必须映射为 NotFound 变体"
        );
        assert!(err.is_not_found());
        assert!(!err.is_retryable());
    }

    #[test]
    fn not_found_message_does_not_affect_other_statuses() {
        // 响应体含 "404" 子串但状态码非 404 → 不应误判为 NotFound
        let err = SyncError::from_http_status(500, "object size 4041 bytes");
        assert!(!err.is_not_found(), "500 + 体含 404 子串不得判为 NotFound");

        // 字符串本身包含 "not found" 但类型是 Network → 同样不得误判
        let err2 = SyncError::Network {
            message: "weird gateway said: not found anywhere".to_string(),
            retryable: false,
        };
        assert!(!err2.is_not_found());
    }

    #[test]
    fn auth_and_server_error_mapping_preserved() {
        assert!(matches!(
            SyncError::from_http_status(401, "x"),
            SyncError::Auth { .. }
        ));
        let e = SyncError::from_http_status(503, "blocked");
        assert!(e.is_retryable(), "5xx 应可重试");
    }

    // ========================================================================
    // Fix-03: DELETE 状态码判定
    // ========================================================================

    #[test]
    fn delete_status_success_and_idempotent_404() {
        assert!(SyncError::check_delete_status(204).is_ok());
        assert!(SyncError::check_delete_status(200).is_ok());
        assert!(
            SyncError::check_delete_status(404).is_ok(),
            "404 必须幂等视为成功"
        );
    }

    #[test]
    fn delete_status_failures_are_reported() {
        let forbidden = SyncError::check_delete_status(403).unwrap_err();
        assert!(!forbidden.is_retryable(), "403 不可重试");

        let server = SyncError::check_delete_status(500).unwrap_err();
        assert!(server.is_retryable(), "5xx 应标记可重试");
    }
}
