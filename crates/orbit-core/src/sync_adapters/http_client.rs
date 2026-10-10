use reqwest::Client;
use std::time::Duration;

use crate::sync::error::{SyncError, transport_message};

/// 共享 HTTP 客户端封装
///
/// 提供统一的 reqwest Client 配置、重试逻辑和超时管理。
pub struct HttpClient {
    client: Client,
    max_retries: u32,
    /// 构造时的读超时（秒）。仅用于推导控制面请求的总预算，见
    /// [`Self::control_timeout`]。
    timeout_secs: u64,
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
            timeout_secs,
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

    /// 控制面请求（HEAD / DELETE / PROPFIND / MKCOL / multipart 协议步）
    /// 的 per-request **总**超时预算
    ///
    /// ## 为什么必须有（F81）
    ///
    /// F60 只给 `put_with_retry` 补了发送阶段超时（per-request
    /// `RequestBuilder::timeout`）。但客户端级只有 `read_timeout`，而它
    /// **只覆盖响应体读取**——「等响应头」这一段仍是不受约束的窗口
    /// （`HttpClient::new` 的注释已自陈这一点）。于是所有不带 body 的
    /// 请求（HEAD/DELETE/PROPFIND/MKCOL）以及 multipart 的
    /// Create/Complete/Abort 三步，全都**没有任何总超时**：
    /// 服务端接受连接后不回任何字节（半开的 TCP、被劫持的中间设备、
    /// 挂死的自建网关）时请求永久挂起。
    ///
    /// 代价不只是这一轮同步失败：挂起期间 `SyncGuard` 不 Drop，
    /// 引擎的同步互斥锁一直被持有，**后续所有同步入口都只能拿到
    /// `skipped`**（F60 注释里描述的同一后果，只是当时只修了 PUT）。
    ///
    /// 档位直接沿用配置的 `timeout_secs`（适配器层已把 0 归一到 30s
    /// 默认）：控制面请求没有 body，唯一会出问题的情况是挂死，用户
    /// 配的读超时正是他对该链路容忍度的声明，不必另设下限。
    pub fn control_timeout(&self) -> Duration {
        Duration::from_secs(self.timeout_secs)
    }

    /// 幂等控制面请求：带总超时 + HTTP 级重试，返回原始响应交调用方判状态码
    ///
    /// 适用范围严格限定**幂等**动词：HEAD / DELETE / PROPFIND / MKCOL。
    /// 重发它们不产生额外副作用（删不存在的对象回 404 → 本层视为幂等成功；
    /// 重复 MKCOL 回 405 → 已存在；PROPFIND/HEAD 是纯读），因此在弱网下
    /// 重试是净收益——这正是「不同网络环境下稳定性」里瞬断（连接被重置、
    /// 代理抽风）的主要自愈手段。
    ///
    /// **不可用于** CreateMultipartUpload（重发会多出一个 uploadId，前一个
    /// 成为永不清理的孤儿分片）或任何带不可重复 body 的 POST。
    ///
    /// 限流仍不在此层重试（同 `get_with_retry` 口径）：30/60/120s 的长退避
    /// 归业务级 `with_retry`，短退避只会加剧限流。
    pub async fn send_idempotent(
        &self,
        method: reqwest::Method,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Option<Vec<u8>>,
    ) -> Result<reqwest::Response, SyncError> {
        let budget = self.control_timeout();
        let mut last_error: Option<SyncError> = None;

        for attempt in 0..=self.max_retries {
            let mut req = self
                .client
                .request(method.clone(), url)
                .timeout(budget)
                .headers(headers.clone());
            if let Some(b) = body.clone() {
                req = req.body(b);
            }
            match req.send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if crate::sync::error::is_success_status(status)
                        || (300..400).contains(&status)
                        || matches!(status, 404 | 405 | 409 | 412)
                    {
                        // 2xx、3xx 与「调用方需要自己解读的状态」原样返回：
                        // - 404/405/409/412 在 WebDAV 与条件写里都有确定语义
                        //   （对象不存在 / 已存在 / 父目录缺失 / 前置条件失败），
                        //   折成错误会丢掉调用方的分支判据；
                        // - 3xx 必须放行：MKCOL 的既有口径把 301/302 当
                        //   「目录已存在」（部分服务器如此应答），折成错误会
                        //   让已存在的目录反复重建。正常重定向由 reqwest
                        //   自己跟随，走到这里说明没有可跟随的 Location。
                        return Ok(response);
                    }
                    let resp_body = response.text().await.unwrap_or_default();
                    let error = SyncError::from_http_status(status, &resp_body);
                    if !error.is_retryable() || error.is_rate_limited() {
                        return Err(error);
                    }
                    last_error = Some(error);
                }
                Err(e) => {
                    last_error = Some(SyncError::Network {
                        message: transport_message(&format!("{method} 请求"), &e),
                        retryable: true,
                    });
                }
            }

            if attempt < self.max_retries {
                tokio::time::sleep(Duration::from_millis(100 * 2u64.pow(attempt))).await;
            }
        }

        Err(last_error.unwrap_or_else(|| SyncError::Network {
            message: format!("{method} 请求失败：重试耗尽"),
            retryable: false,
        }))
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

    /// PUT 请求的 per-request 总超时预算（F60 建档，F82 加余量）
    ///
    /// 口径：每 5MiB 给 120s **×1.25 安全余量**，不足 5MiB 也至少一档。
    /// 纯函数，便于单测钉住档位（真跑一趟停滞传输要等满一个窗口，不适合进单测）。
    ///
    /// ## 为什么要有显式余量（F82）
    ///
    /// 档位原本按「350kbps 下限链路传 5MiB 恰好约 120s」取**整**，余量趋近
    /// 0：任何抖动（TCP 慢启动、TLS 握手、丢包重传、上行被 QoS 挤占）都可能
    /// 把一条健康传输掐在窗口边缘。那条 350kbps 是**假设**（F60 引入时便如此）
    /// 而非实测下界，却被当作硬上界在用——这是本档位最脆的地方。
    ///
    /// 余量取 **1.25 倍**而非更大：它只该吸收抖动，不该去补偿「上行比假设
    /// 更慢」。后者该调小分片粒度（降低单片体量），而不是拉长窗口把失败
    /// 推迟到几分钟之后——那只会让每轮同步卡得更久、用户更早失去耐心。
    ///
    /// 代价明写出来，别让它变成惊喜：`put_with_retry` 默认 4 次尝试，
    /// 8MiB 单 PUT 最坏 4 × 300s ≈ 20 分钟。这仍优于无限期挂死（F60 的
    /// 取舍），但挂起期间引擎的同步互斥锁被持有、后续入口全拿 `skipped`，
    /// 所以余量不宜再放大。
    fn put_timeout_budget(body_len: usize) -> Duration {
        const PER_STEP_BYTES: usize = 5 * 1024 * 1024;
        const STEP_SECS: u64 = 120;
        // F82 安全余量：见上
        const STEP_MARGIN_NUM: u64 = 5;
        const STEP_MARGIN_DEN: u64 = 4;
        let steps = body_len.div_ceil(PER_STEP_BYTES).max(1) as u64;
        Duration::from_secs(STEP_SECS * STEP_MARGIN_NUM / STEP_MARGIN_DEN * steps)
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
    ///
    /// ## 超时按请求体大小给（F81）
    ///
    /// 此前是写死的 120s。清单是本客户端唯一的小对象（KB 级），当前取值与
    /// [`Self::put_timeout_budget`] 的一档完全重合，但写死意味着「清单将来
    /// 因设备/表变多而变大」时不会有任何提示——复用体量预算，档位自动跟随。
    ///
    /// ## 传输层失败可重试（F81）
    ///
    /// 清单条件写是整轮同步的**收敛点**（此前分桶都已上传，就差它落定），
    /// 单次瞬断就把整轮 push 判失败，性价比极差。这里对**传输层**失败重试
    /// （短退避），业务级 `with_retry` 仍在其上兜底。
    ///
    /// 重发是安全的，由前置条件保证：若首次其实写成功而响应丢失，重发带的是
    /// 旧令牌 → 服务端回 412 → 返回 `Ok(false)` → 调用方按「并发冲突」重读
    /// 清单，发现正是自己那版（或基于新清单重算）后收敛，代价是多一轮清单
    /// 读写，不会覆盖他端数据。
    pub async fn put_conditional(
        &self,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: Vec<u8>,
        if_match: Option<&str>,
        if_none_match_star: bool,
    ) -> Result<bool, SyncError> {
        let budget = Self::put_timeout_budget(body.len());
        let mut last_error: Option<SyncError> = None;

        for attempt in 0..=self.max_retries {
            let mut request = self
                .client
                .put(url)
                .headers(headers.clone())
                .body(body.clone());
            if let Some(token) = if_match {
                request = request.header(reqwest::header::IF_MATCH, format!("\"{token}\""));
            }
            if if_none_match_star {
                request = request.header(reqwest::header::IF_NONE_MATCH, "*");
            }

            let response = match request.timeout(budget).send().await {
                Ok(r) => r,
                Err(e) => {
                    last_error = Some(SyncError::Network {
                        message: transport_message("条件 PUT 请求", &e),
                        retryable: true,
                    });
                    if attempt < self.max_retries {
                        tokio::time::sleep(Duration::from_millis(100 * 2u64.pow(attempt))).await;
                    }
                    continue;
                }
            };

            let status = response.status().as_u16();
            return match status {
                412 => Ok(false),
                // 部分 WebDAV 实现对 If-Match 失败返回 409 Conflict，故条件写下的 409
                // 折成「前置条件不满足」。
                //
                // F56（2026-10-01 第六轮）：409 在 WebDAV 里**本来还有一个含义**——
                // RFC 4918 的 AncestorsNotFound（父目录链缺失，见 `from_http_status`
                // 的同码分支）。这条折叠之所以安全，前提是**调用方保证父目录存在**：
                // `WebDavAdapter::upload_conditional` 与 `upload` 一样先
                // `ensure_directory(parent)`，缺目录会在那里自愈（失败也会以
                // `SyncError` 上抛，而不是走到这里）。**故本层收到的 409 只剩
                // 「CAS 失败」一种含义**；新增条件写调用点时必须同样先补齐父目录，
                // 否则父目录缺失会被误报成并发冲突，调用方会徒劳重读重试。
                409 if if_match.is_some() || if_none_match_star => Ok(false),
                s if crate::sync::error::is_success_status(s) => Ok(true),
                s => {
                    let body = response.text().await.unwrap_or_default();
                    Err(SyncError::from_http_status(s, &body))
                }
            };
        }

        Err(last_error.unwrap_or_else(|| SyncError::Network {
            message: "条件 PUT 请求失败：重试耗尽".to_string(),
            retryable: false,
        }))
    }

    /// 单次 PUT（无 HTTP 级重试、总超时按分片体量给），返回响应 ETag
    ///
    /// S4 multipart 分片上传专用（2026-09-14）：分片级重试由调用方
    /// （`upload_part_with_retry` 循环）控制，避免 HTTP 级 3 次短退避与
    /// 分片级重试叠加成 9 次放大风暴；长超时窗口给慢速上行足够余量——
    /// 5MiB 分片在 350kbps 下限链路传输约 2 分钟，30s 通用窗口会在传输
    /// 中途掐断健康连接。用 per-request `RequestBuilder::timeout` 覆盖
    /// 客户端默认读超时（读超时不覆盖发送阶段，见 `HttpClient::new` 注释）。
    ///
    /// ## 预算与单 PUT 共用同一个纯函数（F82）
    ///
    /// 此前这里是写死的 `Duration::from_secs(120)`，与
    /// [`Self::put_timeout_budget`] 的「每 5MiB 给 120s」一档**碰巧相等**。
    /// 两个独立的字面量守同一件事，正是本仓注释里反复警告的漂移温床：改了一处
    /// 忘了另一处，分片与单 PUT 的容忍度就会静默分叉。现直接复用同一函数——
    /// 分片体量多大就按体量算，档位永远跟随。
    ///
    /// 注意这**不增加**余量：5MiB 分片仍是 120s，与「350kbps 下限链路约需
    /// 119.8s」几乎贴死。该下限是全仓共享的假设（`put_timeout_budget` 的
    /// 注释同样以它立论），要动就得连同那条假设一起重估，不能只在一处放宽。
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
            .timeout(Self::put_timeout_budget(body.len()))
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
    // F81：控制面请求（HEAD/DELETE/PROPFIND/MKCOL）必须有总超时
    //
    // `read_timeout` 只覆盖响应体读取；「等响应头」这段不受约束。服务端
    // 接受连接后不写任何字节时，请求会永久挂起并一直持着引擎的同步互斥锁
    // （后续同步入口全部 `skipped`）。以下用「黑洞服务器」钉住这条防线。
    //
    // 阻塞夹具的收尾纪律（Rust 的 spawn_blocking 任务会被 Runtime drop 等待，
    // 留死循环/长 sleep 会把用例拖到分钟级）：只服务有限次连接、socket 设读
    // 超时、等不到客户端就按截止时间退出。
    // ========================================================================

    /// 黑洞服务器：接受连接、读完请求后**永不写任何响应**
    ///
    /// 只服务单连接；客户端超时掐断后 `read` 回 0 即返回，绝不 `accept` 第二次。
    fn spawn_blackhole_server() -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::task::spawn_blocking(move || {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            let mut stream = stream;
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut buf = [0u8; 1024];
            // 静默消费客户端发来的字节（读完请求），但一个响应字节都不回
            loop {
                match std::io::Read::read(&mut stream, &mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {}
                }
            }
        });
        format!("http://127.0.0.1:{port}/")
    }

    /// HEAD 遇黑洞必须在预算内失败，而不是永久挂起
    ///
    /// 旧实现（裸 `.send()`，无 `.timeout()`）在本用例上会挂到测试超时——
    /// 这正是线上「同步指示器永远转圈、且后续同步全被跳过」的成因。
    #[tokio::test]
    async fn control_request_is_cut_off_when_server_never_responds() {
        let url = spawn_blackhole_server();
        let http = HttpClient::new(1, 0, false).expect("构造 HTTP 客户端");
        assert_eq!(
            http.control_timeout(),
            Duration::from_secs(1),
            "控制面预算沿用配置的超时（适配器层已把 0 归一到 30s 默认）"
        );

        let started = std::time::Instant::now();
        let result = http
            .send_idempotent(
                reqwest::Method::HEAD,
                &url,
                reqwest::header::HeaderMap::new(),
                None,
            )
            .await;
        assert!(
            result.is_err(),
            "服务端不回响应头时必须报错，绝不能无限等待"
        );
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "必须在超时预算附近失败，实耗 {:?}",
            started.elapsed()
        );
    }

    /// 纯函数档位：预算必须严格等于配置值，不得被悄悄放大或缩小
    #[test]
    fn control_timeout_tracks_configured_value() {
        for secs in [1u64, 15, 30, 120] {
            let http = HttpClient::new(secs, 0, false).expect("构造 HTTP 客户端");
            assert_eq!(http.control_timeout(), Duration::from_secs(secs));
        }
    }

    /// 起一个「首次连接读完整请求后直接断开、第二次正常应答」的本地服务器
    ///
    /// 读完整请求（含 body）再断，保证客户端的写阶段先成功、失败点落在
    /// 读响应阶段——这才是「响应丢失」的真实形态（提前断会撞 RST，失败点
    /// 变成发送阶段，测的就不是同一件事）。
    ///
    /// accept 非阻塞 + 5s 截止：零重试用例只发一次请求，第二次 `accept`
    /// 必然等不到，没有截止的话该阻塞任务会一直挂着。
    fn spawn_drop_first_request_server() -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).expect("切非阻塞 accept");
        let port = listener.local_addr().unwrap().port();
        tokio::task::spawn_blocking(move || {
            for round in 0..2u8 {
                // 等一个连接，最多 5s；等不到就收尾（绝不无限 accept）
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                let mut stream = loop {
                    match listener.accept() {
                        Ok((s, _)) => break s,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            if std::time::Instant::now() >= deadline {
                                return;
                            }
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        Err(_) => return,
                    }
                };
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let mut buf = [0u8; 4096];
                let mut req = Vec::new();
                // 读请求头
                loop {
                    match std::io::Read::read(&mut stream, &mut buf) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => {
                            req.extend_from_slice(&buf[..n]);
                            if req.windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                    }
                }
                // 按 Content-Length 把请求体读干净（否则关连接会撞 RST，
                // 失败点变成「发送阶段」而非「响应丢失」）
                let head_txt = String::from_utf8_lossy(&req).to_ascii_lowercase();
                let need = head_txt
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
                let mut remaining = need.saturating_sub(req.len());
                while remaining > 0 {
                    match std::io::Read::read(&mut stream, &mut buf) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => remaining = remaining.saturating_sub(n),
                    }
                }
                if round == 0 {
                    // 响应丢失：连接直接断，客户端只看到传输层错误
                    drop(stream);
                    continue;
                }
                let mut out = std::io::BufWriter::new(&mut stream);
                let head = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                if std::io::Write::write_all(&mut out, head.as_bytes()).is_err() {
                    return;
                }
                let _ = std::io::Write::flush(&mut out);
            }
        });
        format!("http://127.0.0.1:{port}/")
    }

    /// 首次响应丢失后必须重试并成功，而不是把整轮同步判失败
    #[tokio::test]
    async fn put_conditional_retries_after_lost_response() {
        let url = spawn_drop_first_request_server();
        let http = HttpClient::new(5, 2, false).expect("构造 HTTP 客户端");

        let ok = http
            .put_conditional(
                &url,
                reqwest::header::HeaderMap::new(),
                b"manifest-payload".to_vec(),
                Some("v1"),
                false,
            )
            .await
            .expect("重试后必须成功，不得把瞬断抛给调用方");

        assert!(ok, "重试成功即前置条件成立（服务端返回 200）");
    }

    /// 零重试时不得重试：单次尝试失败即上抛（把重试预算交给调用方配置）
    #[tokio::test]
    async fn put_conditional_without_retries_fails_fast() {
        let url = spawn_drop_first_request_server();
        let http = HttpClient::new(5, 0, false).expect("构造 HTTP 客户端");

        let err = http
            .put_conditional(
                &url,
                reqwest::header::HeaderMap::new(),
                b"manifest-payload".to_vec(),
                Some("v1"),
                false,
            )
            .await
            .expect_err("零重试时首次失败即上抛");
        assert!(err.is_retryable(), "传输层失败仍须标可重试供业务层判断");
    }

    // ========================================================================
    // F60（2026-09-30 第六轮）：PUT 发送阶段的超时预算
    //
    // 真跑「服务端收下请求后停止读取」需要等满一个 120s 窗口，不适合进单测；
    // 这里钉住纯函数的档位（档位一旦被改小，慢速上行会重新被掐断）。
    // ========================================================================

    #[test]
    fn put_timeout_budget_has_full_first_tier_floor_for_small_bodies() {
        // F82：档位 = 120s × 1.25 = 150s
        const TIER: u64 = 150;
        assert_eq!(HttpClient::put_timeout_budget(0), Duration::from_secs(TIER));
        assert_eq!(
            HttpClient::put_timeout_budget(100 * 1024),
            Duration::from_secs(TIER),
            "小请求体（清单、分桶）也必须给足一档"
        );
        assert_eq!(
            HttpClient::put_timeout_budget(5 * 1024 * 1024),
            Duration::from_secs(TIER),
            "刚好一片仍是一档"
        );
    }

    #[test]
    fn put_timeout_budget_scales_for_large_single_put() {
        // 8MiB = S3 multipart 阈值 = 单 PUT 的最大体量 → 2 档
        assert_eq!(
            HttpClient::put_timeout_budget(8 * 1024 * 1024),
            Duration::from_secs(300)
        );
        assert_eq!(
            HttpClient::put_timeout_budget(5 * 1024 * 1024 + 1),
            Duration::from_secs(300),
            "跨过 5MiB 即升档"
        );
        // 单调不减：体量变大绝不缩小预算
        assert!(HttpClient::put_timeout_budget(20 * 1024 * 1024) > Duration::from_secs(300));
    }

    /// F82 的实质性质：一档预算必须**宽于**「350kbps 下限传满一片」所需时间
    ///
    /// 旧档位 120s 对该下限（约 119.8s）几乎贴死，余量趋近 0——一次 TCP
    /// 慢启动或一个重传就足以掐断健康传输。本断言直接用字节数算需求时间，
    /// 不依赖任何写死的秒数：余量被谁改没、被改到多少，这条都会红。
    #[test]
    fn budget_has_headroom_over_the_assumed_slow_uplink() {
        const SLOW_UPLINK_BPS: u64 = 350_000 / 8; // 350kbps → 字节/秒
        for size in [
            5 * 1024 * 1024usize,     // 一片（分片粒度）
            8 * 1024 * 1024,          // 单 PUT 上限（multipart 阈值）
            1024 * 1024usize,         // 小分桶
        ] {
            let needed = Duration::from_secs_f64(size as f64 / SLOW_UPLINK_BPS as f64);
            let budget = HttpClient::put_timeout_budget(size);
            assert!(
                budget > needed,
                "{size} 字节：预算 {budget:?} 必须宽于 350kbps 链路的 {needed:?}，\
                 否则慢速健康传输会被掐断"
            );
        }
    }

    /// F82：分片 PUT 的预算档位必须由体量预算函数产出（不再各写一个字面量）
    ///
    /// 旧实现 `put_part_once` 写死 `120s`，与本函数的「每 5MiB 给一档」
    /// **碰巧相等**。两个独立字面量守同一件事，是本仓反复警告的漂移温床：
    /// 改一处忘另一处，症状只会表现为「某个体量的附件偶发超时」，几乎无法
    /// 归因。改后分片体量多大就按体量算，档位永远跟随。
    ///
    /// 复制字面量而非引用适配器常量：`http_client` 是适配器依赖的下层，
    /// 反向引用会成环。两条常量必须同步变更，本断言会在漂移时变红。
    #[test]
    fn one_part_size_lands_on_the_first_budget_tier() {
        const PART_SIZE: usize = 5 * 1024 * 1024; // = S3Adapter::MULTIPART_PART_SIZE
        assert_eq!(
            HttpClient::put_timeout_budget(PART_SIZE),
            Duration::from_secs(150),
            "5MiB 分片必须落在一档；分片粒度若变更，此断言先行报警"
        );
        // 尾片只会更小，预算不得更紧
        assert!(HttpClient::put_timeout_budget(PART_SIZE / 2) >= HttpClient::put_timeout_budget(PART_SIZE));
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
