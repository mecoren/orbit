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

    /// 限流（HTTP 429，或坚果云等服务的 503 限流响应）。
    ///
    /// S6（2026-09-13 探查，基线 P1-5）：历史实现靠消息 contains("429") /
    /// "BlockedTemporarily" 字符串嗅探判定限流——任何错误消息含 "429" 子串
    /// （如 "size 4291 bytes"）都会触发 30/60/120s 长退避。现由适配器按
    /// 状态码 + 限流标识构造本变体，`is_rate_limited()` 基于类型判断；
    /// `from_http_status` 内联判定 429 与「503 + 限流体」两种形态。
    #[error("请求被限流(429): {message}")]
    RateLimited { message: String },
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

    /// 是否为限流错误（S6：类型判断，替代 contains("429") 字符串嗅探）
    ///
    /// 限流需要更长退避（30/60/120 秒）而非默认 2/4/8 秒，否则加剧限流。
    /// 现判定 = `RateLimited` 变体（由适配器按状态码构造）；
    /// 兼容期保留对历史 `Network` 错误消息的嗅探（旧调用方手工构造的
    /// 限流错误未经过适配器），但嗅探仅在状态码标识后进行。
    pub fn is_rate_limited(&self) -> bool {
        if matches!(self, SyncError::RateLimited { .. }) {
            return true;
        }
        // 兼容：适配器之外手工构造的历史限流错误（无类型信息）——
        // 用与之前一致的标识匹配，但加上 "HTTP 429" 前缀锚点，
        // "size 4291 bytes" 这类巧合子串不再误判
        let msg = self.to_string();
        msg.contains("认证失败(429)")
            || msg.contains("HTTP 429")
            || msg.contains("BlockedTemporarily")
            || msg.contains("Too many requests")
            || msg.contains("too many requests")
            || msg.contains("rate limit")
            || msg.contains("Rate limit")
    }

    /// 是否为认证类错误（401/403）——重试无意义（凭据不会自动变对）
    ///
    /// S6：`with_retry` 对认证错误立即返回，不再白等 2/4/8s×3 重试
    /// （密钥配错的用户每轮同步白等 ~14s）。
    pub fn is_auth_error(&self) -> bool {
        matches!(self, SyncError::Auth { .. })
    }

    /// 是否为「资源不存在」（404）错误
    ///
    /// 基于 `SyncError::NotFound` 变体的类型判断，不再做字符串匹配。
    /// 适配器层（`from_http_status` / WebDAV 409 AncestorsNotFound 翻译）负责构造该变体。
    pub fn is_not_found(&self) -> bool {
        matches!(self, SyncError::NotFound { .. })
    }

    /// 根据HTTP状态码构造对应错误
    ///
    /// S6/S19：429 与「503 + 限流体」构造类型化 `RateLimited` 变体
    /// （替代调用方 contains 嗅探）；其余分类不变。
    pub fn from_http_status(status: u16, body: &str) -> Self {
        match status {
            401 | 403 => SyncError::Auth {
                message: format!("认证失败({status}): {body}"),
            },
            404 => SyncError::NotFound {
                message: body.to_string(),
            },
            429 => SyncError::RateLimited {
                message: body.to_string(),
            },
            500..=599 => {
                // 坚果云等 WebDAV 服务限流时返回 503 + "BlockedTemporarily" /
                // "Too many requests" 体——与过载的 503 同码不同因，
                // 限流形态需要长退避、过载形态短退避即可
                let limited = body.contains("BlockedTemporarily")
                    || body.to_lowercase().contains("too many requests")
                    || body.to_lowercase().contains("rate limit");
                if status == 503 && limited {
                    SyncError::RateLimited {
                        message: format!("服务器限流({status}): {body}"),
                    }
                } else {
                    SyncError::Network {
                        message: format!("服务器错误({status}): {body}"),
                        retryable: true,
                    }
                }
            }
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

    /// HEAD 存在性探测的状态码判定（P1-2，供 S3/WebDAV `asset_exists` 共用）
    ///
    /// 历史问题：适配器对 HEAD 非 2xx 一律返回 `Ok(false)`——403/429/500
    /// 与 404 不区分，权限错被当「附件不存在」触发重复上传，限流被掩盖。
    ///
    /// 判定规则：
    /// - 2xx：存在
    /// - 404：不存在（幂等语义；WebDAV 坚果云 409 同为「路径不存在」）
    /// - 409：不存在（WebDAV 语义；S3 场景不会出现）
    /// - 5xx：可重试网络错误
    /// - 401/403/429 等：透传分类错误（Auth / 其他），**不得静默当不存在**
    pub fn classify_head_status(status: u16) -> Result<bool, Self> {
        match status {
            200..=299 => Ok(true),
            404 | 409 => Ok(false),
            429 => Err(SyncError::RateLimited {
                message: "HEAD 探测被限流".to_string(),
            }),
            s if (500..=599).contains(&s) => Err(SyncError::Network {
                message: format!("HEAD 探测失败: HTTP {s}"),
                retryable: true,
            }),
            s => Err(SyncError::from_http_status(s, "")),
        }
    }
}

/// HTTP 状态码是否成功（2xx）——multipart 协议各步的状态检查用
///
/// 独立函数而非 `SyncError` 方法：调用点只有状态码没有错误体分类需求，
/// 与 reqwest `StatusCode::is_success` 语义一致。
pub fn is_success_status(status: u16) -> bool {
    (200..=299).contains(&status)
}

// 注：旧 `sync_bundle` 模块（52 字节 `OSYN` 容器）已随存储结构重构删除，
// 其到本错误类型的 `From` 转换一并移除。

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

    // ========================================================================
    // P1-2: HEAD 存在性探测状态码判定
    // ========================================================================

    #[test]
    fn head_status_2xx_means_exists() {
        assert_eq!(SyncError::classify_head_status(200).unwrap(), true);
        assert_eq!(SyncError::classify_head_status(204).unwrap(), true);
    }

    #[test]
    fn head_status_404_and_409_mean_absent() {
        assert_eq!(SyncError::classify_head_status(404).unwrap(), false);
        assert_eq!(SyncError::classify_head_status(409).unwrap(), false);
    }

    #[test]
    fn head_status_auth_errors_are_not_absent() {
        // 403/401 是权限问题——静默当「不存在」会触发重复上传
        let forbidden = SyncError::classify_head_status(403).unwrap_err();
        assert!(matches!(forbidden, SyncError::Auth { .. }));
        assert!(matches!(
            SyncError::classify_head_status(401).unwrap_err(),
            SyncError::Auth { .. }
        ));
    }

    #[test]
    fn head_status_5xx_is_retryable_error() {
        let server = SyncError::classify_head_status(503).unwrap_err();
        assert!(server.is_retryable(), "5xx HEAD 失败应可重试");
    }

    #[test]
    fn head_status_429_is_reported_not_absent() {
        // 429 限流不得静默当「不存在」
        let limited = SyncError::classify_head_status(429).unwrap_err();
        assert!(!limited.is_not_found(), "429 不得判为不存在");
        assert!(
            limited.is_rate_limited(),
            "429 HEAD 应构造 RateLimited 变体"
        );
    }

    // ========================================================================
    // S6/S19（2026-09-13 探查，基线 P1-5）：限流错误结构化
    //
    // 历史实现 contains("429") 字符串嗅探——"size 4291 bytes" 这类巧合
    // 子串触发 30/60/120s 长退避；503+限流体（坚果云）与服务端过载 5xx
    // 不区分。现由 from_http_status 按状态码构造 RateLimited 变体。
    // ========================================================================

    #[test]
    fn http_429_maps_to_rate_limited_variant() {
        let err = SyncError::from_http_status(429, "Too Many Requests");
        assert!(
            matches!(err, SyncError::RateLimited { .. }),
            "429 必须映射为 RateLimited 变体"
        );
        assert!(err.is_rate_limited());
        assert!(!err.is_not_found(), "429 不得误判为不存在");
        assert!(!err.is_auth_error());
    }

    #[test]
    fn jianguoyun_503_rate_limit_body_maps_to_rate_limited() {
        // 坚果云 503 + BlockedTemporarily 体：限流而非过载
        let err = SyncError::from_http_status(503, "BlockedTemporarily: too many requests");
        assert!(
            matches!(err, SyncError::RateLimited { .. }),
            "503+限流体必须构造 RateLimited（需长退避）"
        );
    }

    #[test]
    fn plain_503_overload_stays_network_retryable() {
        // 普通过载 503（无限流标识）：保持可重试 Network，短退避
        let err = SyncError::from_http_status(503, "Service Temporarily Unavailable");
        assert!(matches!(err, SyncError::Network { .. }));
        assert!(err.is_retryable(), "过载 503 应保持可重试");
        assert!(!err.is_rate_limited());
    }

    #[test]
    fn message_containing_429_substring_no_longer_triggers_rate_limit() {
        // 巧合子串回归：响应体含 "429" 数字不再误判限流
        let err = SyncError::from_http_status(500, "object size 4291 bytes");
        assert!(!err.is_rate_limited(), "500 + 体含 429 子串不得判为限流");
    }

    #[test]
    fn auth_error_detected_by_type_for_retry_exclusion() {
        // S6：with_retry 用类型判断排除认证错误
        assert!(SyncError::from_http_status(403, "forbidden").is_auth_error());
        assert!(SyncError::from_http_status(401, "unauthorized").is_auth_error());
        assert!(!SyncError::from_http_status(500, "x").is_auth_error());
    }
}
