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
    ///
    /// S4 半项（2026-09-14）：`timeout_secs` 的语义从**总超时**改为
    /// **读超时**——连接建立后，每次读响应体操作单独计时 `timeout_secs`，
    /// 成功读到一块即重置计时器。此前 reqwest `ClientBuilder::timeout`
    /// 是「连接开始到响应体读完」的固定总预算，家庭网络下行 5-30Mbps
    /// 时 50MB 附件下载全程超 30s 即被掐断，尽管传输一直在正常推进。
    /// 读超时只断「停滞」连接，不断「慢而在动」的传输。
    ///
    /// ## 语义边界（reqwest 0.12.28 源码核实）
    /// 读超时**只覆盖响应体读取阶段**（reqwest 在 body 逐 chunk 包
    /// ReadTimeoutBody，每 chunk 重置）；请求发送阶段（PUT 上传大请求体、
    /// 等待响应头）仍是单一不重置窗口——慢速上行传大附件的问题**没有**
    /// 被本次改动解决，S4 的 multipart 分片上传维持推迟（触发器不变：
    /// 用户反馈 20MB+ 附件同步失败）。勿据本改动误判上传已缓解。
    pub fn new(
        timeout_secs: u64,
        max_retries: u32,
        accept_invalid_certs: bool,
    ) -> Result<Self, SyncError> {
        let client = Client::builder()
            .read_timeout(Duration::from_secs(timeout_secs))
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

    /// 单次 PUT（无 HTTP 级重试、120s 总超时长窗口），返回响应 ETag
    ///
    /// S4 multipart 分片上传专用（2026-09-14）：分片级重试由调用方
    /// （`upload_part_with_retry` 循环）控制，避免 HTTP 级 3 次短退避与
    /// 分片级重试叠加成 9 次放大风暴；120s 总超时窗口给慢速上行足够
    /// 余量——5MiB 分片在 350kbps 下限链路传输约 2 分钟，30s 通用窗口
    /// 会在传输中途掐断健康连接。用 per-request `RequestBuilder::timeout`
    /// 覆盖客户端默认读超时（读超时不覆盖发送阶段，见 HttpClient::new 注释）。
    ///
    /// ETag 缺失返回 `Ok(None)`：绝大多数 S3 兼容实现都回 ETag 头，
    /// 拿不到时由调用方决定缺 ETag 的 Complete 是否可行。
    pub async fn put_part_once(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Vec<u8>,
    ) -> Result<Option<String>, SyncError> {
        let response = self
            .client
            .put(url)
            .timeout(Duration::from_secs(120))
            .headers(headers)
            .body(body)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("分片 PUT 请求失败: {e}"),
                retryable: true,
            })?;
        if !response.status().is_success() {
            let status = response.status();
            let resp_body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status.as_u16(), &resp_body));
        }
        let etag = response
            .headers()
            .get("ETag")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim_matches('"').to_string());
        Ok(etag)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// 起一个可控节奏的本地 HTTP 服务器：立即返回响应头，响应体按
    /// `chunk_delay` 节奏逐块写出（每块 1 字节），返回 http://127.0.0.1:{port}/ 地址。
    ///
    /// 只服务单个连接：调用方 `HttpClient::new(_, 0, _)` 零重试恰发一次
    /// 请求；且阻塞任务绝不能留 accept 死循环——Runtime drop 会等阻塞
    /// 池任务收尾，不退出的任务会把测试进程挂死到超时。客户端提前断开
    /// （停滞用例被读超时掐断）导致的写失败按正常退出处理。
    fn spawn_slow_body_server(chunk_delay: Duration, total_chunks: usize) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::task::spawn_blocking(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            // 读完请求头即可（GET 无请求体，读到空行即请求结束）
            let mut buf = [0u8; 4096];
            let mut req = Vec::new();
            loop {
                let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
                if n == 0 {
                    return;
                }
                req.extend_from_slice(&buf[..n]);
                if req.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            let mut out = std::io::BufWriter::new(&mut stream);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {total_chunks}\r\nConnection: close\r\n\r\n"
            );
            if !write_out(&mut out, head.as_bytes()) {
                return;
            }
            for _ in 0..total_chunks {
                std::thread::sleep(chunk_delay);
                if !write_out(&mut out, b"a") {
                    return;
                }
            }
        });
        format!("http://127.0.0.1:{port}/")
    }

    /// 写入并强制 flush；客户端已断开（停滞用例被掐断）时返回 false
    fn write_out(out: &mut dyn std::io::Write, bytes: &[u8]) -> bool {
        std::io::Write::write_all(out, bytes).is_ok() && std::io::Write::flush(out).is_ok()
    }

    // ========================================================================
    // S4 半项（2026-09-14）：超时语义 总超时 → 读超时
    //
    // reqwest ClientBuilder::timeout 是「连接开始到响应体读完」的固定
    // 总预算：慢而在动的传输只要总时长超线就被掐断（50MB 附件 × 家庭
    // 下行带宽 = 高失败率）。read_timeout 是「每次读操作单独计时、读到
    // 一块即重置」：只断停滞，不断慢速。以下用本地可控节奏服务器对照
    // 验证两种场景——慢而在动必须成功、真停滞必须仍被掐断。
    //
    // 注意 timeout_secs 粒度是秒，读超时线只能取 1s；慢速用例把总时长
    // 拉到 1.5s（超线）而块间隔 50ms（远小于线内），停滞用例首块延迟
    // 1.5s（1s 线的 1.5 倍余量）确保读等待必然超线。
    // ========================================================================

    /// 慢而在动的下载：总时长 1.5s > 1s 超时线，但块间隔 50ms 远小于
    /// 读超时 → 必须成功。
    ///
    /// 旧总超时语义下本用例必失败（总时长 1.5s > 1s），回归防线：
    /// 若未来有人改回 `.timeout()`，此测试立刻变红。
    #[tokio::test]
    async fn read_timeout_allows_slow_but_progressing_download() {
        // 响应体 30 块 × 50ms 间隔 = 总 1.5s，是 1s 读超时线的 1.5 倍
        let url = spawn_slow_body_server(Duration::from_millis(50), 30);
        let http = HttpClient::new(1, 0, false).expect("构造 HTTP 客户端");
        let body = http
            .get_with_retry(&url, reqwest::header::HeaderMap::new())
            .await
            .expect("慢而在动的下载不得被读超时掐断（总时长超线但每块按时到达）");
        assert_eq!(body.len(), 30, "响应体必须完整读回");
    }

    /// 真停滞：服务器返回响应头后 1.5s 才写首块 → 读等待必然超过 1s
    /// 读超时线，必须掐断（读超时 ≠ 无限等待），同步链路的 with_retry
    /// 才有重试机会。
    #[tokio::test]
    async fn read_timeout_still_cuts_stalled_connection() {
        // 响应头立即返回，首块延迟 1.5s 写出——客户端在 1s 读超时线
        // 内等不到任何字节，必须报错
        let url = spawn_slow_body_server(Duration::from_millis(1500), 1);
        let http = HttpClient::new(1, 0, false).expect("构造 HTTP 客户端");
        let result = http
            .get_with_retry(&url, reqwest::header::HeaderMap::new())
            .await;
        assert!(
            result.is_err(),
            "停滞连接（1.5s 无字节到达 > 1s 读超时线）必须仍能掐断"
        );
    }
}
