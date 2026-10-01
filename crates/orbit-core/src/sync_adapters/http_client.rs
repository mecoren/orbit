use reqwest::Client;
use std::time::Duration;

use crate::sync::error::{SyncError, transport_message};

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
                        message: transport_message("GET 请求", &e),
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

    /// PUT 请求的 per-request 总超时预算（F60）
    ///
    /// 口径与分片上传的 120s 窗口同源：**每 5MiB 给 120s**，不足 5MiB 也至少
    /// 120s。两档事实依据：
    ///
    /// - 分片固定 5MiB 片 × 120s 是既有约定（`put_part_once`），即容忍下限约
    ///   42 KB/s；
    /// - S3 侧 8MiB 是 multipart 阈值，即单 PUT 的最大体量 → 240s 预算，
    ///   按 350kbps（约 44 KB/s）慢速上行需约 190s，仍有 26% 余量。
    ///
    /// 纯函数，便于单测钉住档位（真跑一趟停滞传输要等满一个窗口，不适合进单测）。
    fn put_timeout_budget(body_len: usize) -> Duration {
        const PER_STEP_BYTES: usize = 5 * 1024 * 1024;
        const STEP_SECS: u64 = 120;
        let steps = body_len.div_ceil(PER_STEP_BYTES).max(1) as u64;
        Duration::from_secs(STEP_SECS * steps)
    }

    /// 带重试的 PUT 请求
    ///
    /// 限流场景（429 / 坚果云 503 BlockedTemporarily）不进行 HTTP 级重试，
    /// 直接返回错误交由业务级 with_retry 处理（30/60/120 秒长退避）。
    ///
    /// ## 发送阶段必须有超时（F60，2026-09-30 第六轮）
    ///
    /// 客户端只配了 `read_timeout`（见 `HttpClient::new`），它**只覆盖响应体
    /// 读取**。请求发送阶段（请求体上行 + 等响应头）此前**没有任何超时**：
    /// 服务端接受连接后停止读取时，socket 写阻塞，PUT 永不返回——整轮同步挂死，
    /// 并一直持着引擎的同步互斥锁（后续所有同步入口都只能拿到 `skipped`）。
    ///
    /// 现按请求体大小给 per-request 总超时（[`Self::put_timeout_budget`]）。
    /// **不能照搬分片的固定 120s**：S3 侧 <8MiB 走单 PUT，8MiB 在 350kbps
    /// 上限链路上要 190s，固定窗口会把健康的慢速上行掐断（这正是 S4 把总超时
    /// 改成读超时的原因）。上限的代价是最坏情形：4 次尝试 × 各自窗口（默认
    /// `max_retries = 3`，8MiB 单 PUT 最坏约 16 分钟）——比无限期挂死好，且
    /// 真慢速上行不会触发（每档都有 2.4 倍以上余量）。
    pub async fn put_with_retry(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Vec<u8>,
    ) -> Result<(), SyncError> {
        let mut last_error = None;
        let budget = Self::put_timeout_budget(body.len());

        for attempt in 0..=self.max_retries {
            match self
                .client
                .put(url)
                .timeout(budget)
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
                        message: transport_message("PUT 请求", &e),
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

    /// 带并发令牌读取的 GET（清单 CAS 的前置读取）
    ///
    /// 返回 `(响应体, ETag)`；服务端未提供 ETag 时令牌为 `None`，调用方
    /// 退化为「写后回读校验」。重试策略与 `get_with_retry` 一致。
    ///
    /// ## 令牌口径（F50，2026-09-30 第六轮）
    ///
    /// ETag 归一走 `sync_adapters::traits::normalize_etag`，**与列举侧
    /// （S3 `ListObjectsV2` 的 `<ETag>`、WebDAV `PROPFIND` 的
    /// `<d:getetag/>`）同源**。此前这里用裸 `trim_matches('"')`，漏了两点：
    ///
    /// 1. **弱校验前缀未剥**：服务端回 `W/"abc"` 时令牌成 `W/"abc"`
    ///    （前导 `W` 挡住引号裁剪，只裁掉尾部引号），而 `put_conditional`
    ///    会拼成 `If-Match: "W/"abc"` —— 语法非法或与真实 ETag 不等，
    ///    弱 ETag 的 WebDAV 服务端上 CAS **恒失败**：合并重试耗尽后清单
    ///    永不落盘。
    /// 2. **空值未归 `None`**：部分 WebDAV 实现对目录回 `ETag: ""`，此时
    ///    会发出 `If-Match: ""`（必然 412），等价于把并发保护变成永久失败，
    ///    而正确行为是退化为「写后回读校验」。
    pub async fn get_with_token(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
    ) -> Result<(Vec<u8>, Option<String>), SyncError> {
        let mut last_error = None;

        for attempt in 0..=self.max_retries {
            match self.client.get(url).headers(headers.clone()).send().await {
                Ok(response) => {
                    if response.status().is_success() {
                        let token = response
                            .headers()
                            .get(reqwest::header::ETAG)
                            .and_then(|v| v.to_str().ok())
                            .and_then(crate::sync_adapters::traits::normalize_etag);
                        let bytes = response.bytes().await.map_err(|e| SyncError::Network {
                            message: format!("读取响应体失败: {e}"),
                            retryable: false,
                        })?;
                        return Ok((bytes.to_vec(), token));
                    }
                    let status = response.status();
                    let body = response.text().await.unwrap_or_default();
                    let error = SyncError::from_http_status(status.as_u16(), &body);
                    if !error.is_retryable() || error.is_rate_limited() {
                        return Err(error);
                    }
                    last_error = Some(error);
                }
                Err(e) => {
                    last_error = Some(SyncError::Network {
                        message: transport_message("GET 请求", &e),
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

    /// 条件 PUT（清单乐观并发写入）
    ///
    /// - `if_match = Some(token)`：`If-Match: "token"`，对象被他人改写时 412
    /// - `if_none_match_star = true`：`If-None-Match: *`，对象已存在时 412
    ///
    /// 返回 `Ok(false)` 表示前置条件不满足（412），其余非 2xx 按类型报错。
    /// 不在此层重试 412——那是调用方的语义分支（拉取合并重试），不是网络抖动。
    pub async fn put_conditional(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Vec<u8>,
        if_match: Option<&str>,
        if_none_match_star: bool,
    ) -> Result<bool, SyncError> {
        let mut request = self.client.put(url).headers(headers).body(body);
        if let Some(token) = if_match {
            request = request.header(reqwest::header::IF_MATCH, format!("\"{token}\""));
        }
        if if_none_match_star {
            request = request.header(reqwest::header::IF_NONE_MATCH, "*");
        }

        let response = request
            .timeout(Duration::from_secs(120))
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: transport_message("条件 PUT 请求", &e),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        match status {
            412 => Ok(false),
            // 部分 WebDAV 实现对 If-Match 失败返回 409 Conflict
            409 if if_match.is_some() || if_none_match_star => Ok(false),
            s if crate::sync::error::is_success_status(s) => Ok(true),
            s => {
                let body = response.text().await.unwrap_or_default();
                Err(SyncError::from_http_status(s, &body))
            }
        }
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
    ///
    /// **返回的是响应头的原文**（F72）：该值唯一的用途是构造
    /// CompleteMultipartUpload 清单，而 S3 协议要求清单里的 Part ETag 与 UploadPart
    /// 的响应值**逐字节一致**（含双引号）。这里不做任何归一化——`normalize_etag`
    /// 那套「剥 `W/` 与引号」服务的是**并发令牌比较**（读侧/列举侧同口径），
    /// 与「把服务端回执原文回传」是两件事，套用会让严格校验的实现以
    /// `InvalidPart` / `MalformedXML` 拒绝整份清单（分片已全传完，代价是整文件重传）。
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
                message: transport_message("分片 PUT 请求", &e),
                retryable: true,
            })?;
        if !response.status().is_success() {
            let status = response.status();
            let resp_body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status.as_u16(), &resp_body));
        }
        // F72：原样回传服务端给的 ETag（仅去首尾 OWS，绝不改动引号）。
        // 旧实现是 `trim_matches('"')`——把 Complete 清单要用的回执原文当成了
        // 并发令牌来归一化。
        let etag = response
            .headers()
            .get("ETag")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim().to_string());
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

    /// 起一个只回单条 200 响应的本地服务器：`extra_headers` 原样拼进响应头
    /// （用于验证 ETag 归一化），响应体固定 1 字节。
    ///
    /// 与 `spawn_slow_body_server` 同规矩：只服务单个连接、读完请求头即回，
    /// 客户端提前断开导致的写失败按正常退出处理（绝不留 accept 死循环）。
    ///
    /// 但**请求体必须读干净再回**：本助手既被 GET 用例用，也被 PUT 用例用
    /// （`put_part_once`）。「头读完就回响应并关连接」时客户端可能仍在写 body，
    /// 内核会对「关掉仍有未读数据的连接」回 RST，reqwest 报
    /// `error sending request`（F72 用例首次带体时踩到：同一二进制时红时绿，
    /// 与被测逻辑无关）。故按 `Content-Length` 把请求体读完再回。
    fn spawn_header_server(extra_headers: &str) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let extra = extra_headers.to_string();
        tokio::task::spawn_blocking(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let mut buf = [0u8; 4096];
            let mut req = Vec::new();
            let head_end = loop {
                let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
                if n == 0 {
                    return;
                }
                req.extend_from_slice(&buf[..n]);
                if let Some(p) = req.windows(4).position(|w| w == b"\r\n\r\n") {
                    break p + 4;
                }
            };
            // 按 Content-Length 把请求体读干净，避免回响应时撞客户端未写完的 body
            let head_txt = String::from_utf8_lossy(&req[..head_end]).to_ascii_lowercase();
            let body_need = head_txt
                .split("content-length:")
                .nth(1)
                .map(|rest| {
                    rest.trim_start()
                        .chars()
                        .take_while(char::is_ascii_digit)
                        .collect::<String>()
                })
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(0);
            let mut remaining = body_need.saturating_sub(req.len() - head_end);
            while remaining > 0 {
                let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
                if n == 0 {
                    return;
                }
                remaining = remaining.saturating_sub(n);
            }
            let mut out = std::io::BufWriter::new(&mut stream);
            let head =
                format!("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n{extra}\r\n");
            if !write_out(&mut out, head.as_bytes()) {
                return;
            }
            let _ = write_out(&mut out, b"m");
        });
        format!("http://127.0.0.1:{port}/")
    }

    // ========================================================================
    // F50（2026-09-30 第六轮）：GET 侧 ETag 必须与列举侧同口径
    //
    // 列举侧（S3 ListObjects / WebDAV PROPFIND）走
    // `sync_adapters::traits::normalize_etag`：剥 `W/` + 剥引号 + 空归 None。
    // 条件写读侧此前用裸 `trim_matches('"')`，弱 ETag 与空 ETag 两种服务端
    // 回值下都会产出**发不出去的令牌**，CAS 恒失败。以下三条锁住口径。
    // ========================================================================

    /// 弱 ETag：`W/"abc"` → 令牌必须为 `abc`。
    ///
    /// 旧口径产出 `W/"abc`，`put_conditional` 拼成 `If-Match: "W/"abc"`
    /// → 弱 ETag 服务端上 CAS 恒不匹配（清单永不落盘）。
    #[tokio::test]
    async fn get_with_token_strips_weak_etag_prefix() {
        let url = spawn_header_server("ETag: W/\"abc\"\r\n");
        let http = HttpClient::new(30, 0, false).expect("构造 HTTP 客户端");
        let (_, token) = http
            .get_with_token(&url, reqwest::header::HeaderMap::new())
            .await
            .expect("GET 必须成功");
        assert_eq!(
            token.as_deref(),
            Some("abc"),
            "弱校验前缀 W/ 与引号都必须剥掉（与列举侧同口径）"
        );
    }

    /// F72：分片 PUT 的 ETag 必须**原样**回传（含双引号）
    ///
    /// 与上面三条刻意形成对照：读侧/列举侧的令牌要归一化（剥 `W/` 与引号），
    /// 而这里要的是「服务端回执原文」——它直接进 CompleteMultipartUpload 清单，
    /// 协议要求与 UploadPart 响应值逐字节一致。旧实现沿用了归一化，把引号剥掉；
    /// 严格校验的服务端会以 `InvalidPart` 拒绝整份清单，而分片已全部上传完毕。
    #[tokio::test]
    async fn put_part_returns_raw_etag_with_quotes() {
        let url = spawn_header_server("ETag: \"d41d8cd98f00b204e9800998ecf8427e\"\r\n");
        let http = HttpClient::new(30, 0, false).expect("构造 HTTP 客户端");
        let etag = http
            .put_part_once(&url, reqwest::header::HeaderMap::new(), b"part".to_vec())
            .await
            .expect("分片 PUT 必须成功");

        assert_eq!(
            etag.as_deref(),
            Some("\"d41d8cd98f00b204e9800998ecf8427e\""),
            "必须原样保留服务端双引号（Complete 清单要求逐字节一致）"
        );
    }

    /// 空 ETag（部分 WebDAV 实现对目录回 `ETag: ""`）→ 必须归 `None`，
    /// 让调用方退化到「写后回读校验」，而不是发 `If-Match: ""`（必然 412）。
    #[tokio::test]
    async fn get_with_token_maps_empty_etag_to_none() {
        let url = spawn_header_server("ETag: \"\"\r\n");
        let http = HttpClient::new(30, 0, false).expect("构造 HTTP 客户端");
        let (_, token) = http
            .get_with_token(&url, reqwest::header::HeaderMap::new())
            .await
            .expect("GET 必须成功");
        assert_eq!(token, None, "空 ETag 必须归 None（退化写后回读校验）");
    }

    /// 对照面：强 ETag 正常剥引号；无 ETag 头仍为 `None`（行为不得回退）。
    #[tokio::test]
    async fn get_with_token_keeps_strong_etag_and_absent_header() {
        let http = HttpClient::new(30, 0, false).expect("构造 HTTP 客户端");

        let url = spawn_header_server("ETag: \"abc\"\r\n");
        let (_, token) = http
            .get_with_token(&url, reqwest::header::HeaderMap::new())
            .await
            .expect("GET 必须成功");
        assert_eq!(token.as_deref(), Some("abc"), "强 ETag 只剥引号");

        let url = spawn_header_server("");
        let (_, token) = http
            .get_with_token(&url, reqwest::header::HeaderMap::new())
            .await
            .expect("GET 必须成功");
        assert_eq!(token, None, "服务端不提供 ETag 时必须为 None");
    }

    // ========================================================================
    // F60（2026-09-30 第六轮）：PUT 发送阶段的超时预算
    //
    // 真跑「服务端收下请求后停止读取」需要等满一个 120s 窗口，不适合进单测；
    // 这里钉住纯函数的档位（档位一旦被改小，慢速上行会重新被掐断）。
    // ========================================================================

    #[test]
    fn put_timeout_budget_has_120s_floor_for_small_bodies() {
        assert_eq!(HttpClient::put_timeout_budget(0), Duration::from_secs(120));
        assert_eq!(
            HttpClient::put_timeout_budget(100 * 1024),
            Duration::from_secs(120),
            "小请求体（清单、分桶）也必须给足 120s"
        );
        assert_eq!(
            HttpClient::put_timeout_budget(5 * 1024 * 1024),
            Duration::from_secs(120),
            "刚好一片仍是一档"
        );
    }

    #[test]
    fn put_timeout_budget_scales_for_large_single_put() {
        // 8MiB = S3 multipart 阈值 = 单 PUT 的最大体量 → 2 档 240s
        assert_eq!(
            HttpClient::put_timeout_budget(8 * 1024 * 1024),
            Duration::from_secs(240)
        );
        assert_eq!(
            HttpClient::put_timeout_budget(5 * 1024 * 1024 + 1),
            Duration::from_secs(240),
            "跨过 5MiB 即升档"
        );
        // 单调不减：体量变大绝不缩小预算
        assert!(HttpClient::put_timeout_budget(20 * 1024 * 1024) > Duration::from_secs(240));
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
