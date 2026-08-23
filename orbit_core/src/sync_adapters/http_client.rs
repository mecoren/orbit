use reqwest::Client;
use std::time::Duration;

use crate::sync::error::SyncError;

/// 共享 HTTP 客户端封装
///
/// 提供统一的 reqwest Client 配置、重试逻辑和超时管理。
pub struct HttpClient {
    client: Client,
    max_retries: u32,
}

impl HttpClient {
    /// 创建新的 HTTP 客户端
    ///
    /// `accept_invalid_certs`：自签名证书场景跳过 TLS 校验（用户显式开启）。
    pub fn new(
        timeout_secs: u64,
        max_retries: u32,
        accept_invalid_certs: bool,
    ) -> Result<Self, SyncError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(timeout_secs))
            .connect_timeout(Duration::from_secs(10))
            .danger_accept_invalid_certs(accept_invalid_certs)
            .build()
            .map_err(|e| SyncError::Network {
                message: format!("创建 HTTP 客户端失败: {e}"),
                retryable: false,
            })?;

        Ok(Self {
            client,
            max_retries,
        })
    }

    /// 使用默认配置创建
    pub fn default_client() -> Result<Self, SyncError> {
        Self::new(30, 3, false)
    }

    /// 获取内部 reqwest Client 引用
    pub fn inner(&self) -> &Client {
        &self.client
    }

    /// 带重试的 GET 请求
    ///
    /// 限流场景（429 / 坚果云 503 BlockedTemporarily）不进行 HTTP 级重试，
    /// 直接返回错误交由业务级 with_retry 处理（30/60/120 秒长退避）。
    /// 否则短退避（100/200/400ms）的 HTTP 级重试会加剧限流。
    pub async fn get_with_retry(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
    ) -> Result<Vec<u8>, SyncError> {
        let mut last_error = None;

        for attempt in 0..=self.max_retries {
            match self.client.get(url).headers(headers.clone()).send().await {
                Ok(response) => {
                    if response.status().is_success() {
                        return response.bytes().await.map(|b| b.to_vec()).map_err(|e| {
                            SyncError::Network {
                                message: format!("读取响应体失败: {e}"),
                                retryable: false,
                            }
                        });
                    }
                    let status = response.status();
                    let body = response.text().await.unwrap_or_default();
                    let error = SyncError::from_http_status(status.as_u16(), &body);
                    // 限流错误不进行 HTTP 级重试，交由业务级 with_retry 处理
                    if !error.is_retryable() || error.is_rate_limited() {
                        return Err(error);
                    }
                    last_error = Some(error);
                }
                Err(e) => {
                    let error = SyncError::Network {
                        message: format!("GET 请求失败: {e}"),
                        retryable: true,
                    };
                    last_error = Some(error);
                }
            }

            if attempt < self.max_retries {
                let delay = Duration::from_millis(100 * 2u64.pow(attempt));
                tokio::time::sleep(delay).await;
            }
        }

        Err(last_error.unwrap_or_else(|| SyncError::Network {
            message: "未知错误".to_string(),
            retryable: false,
        }))
    }

    /// 带重试的 PUT 请求
    ///
    /// 限流场景（429 / 坚果云 503 BlockedTemporarily）不进行 HTTP 级重试，
    /// 直接返回错误交由业务级 with_retry 处理（30/60/120 秒长退避）。
    pub async fn put_with_retry(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Vec<u8>,
    ) -> Result<(), SyncError> {
        let mut last_error = None;

        for attempt in 0..=self.max_retries {
            match self
                .client
                .put(url)
                .headers(headers.clone())
                .body(body.clone())
                .send()
                .await
            {
                Ok(response) => {
                    if response.status().is_success() {
                        return Ok(());
                    }
                    let status = response.status();
                    let resp_body = response.text().await.unwrap_or_default();
                    let error = SyncError::from_http_status(status.as_u16(), &resp_body);
                    // 限流错误不进行 HTTP 级重试，交由业务级 with_retry 处理
                    if !error.is_retryable() || error.is_rate_limited() {
                        return Err(error);
                    }
                    last_error = Some(error);
                }
                Err(e) => {
                    last_error = Some(SyncError::Network {
                        message: format!("PUT 请求失败: {e}"),
                        retryable: true,
                    });
                }
            }

            if attempt < self.max_retries {
                let delay = Duration::from_millis(100 * 2u64.pow(attempt));
                tokio::time::sleep(delay).await;
            }
        }

        Err(last_error.unwrap_or_else(|| SyncError::Network {
            message: "未知错误".to_string(),
            retryable: false,
        }))
    }
}
