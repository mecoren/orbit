use async_trait::async_trait;
use reqwest::header::HeaderMap;

use crate::s3::{
    build_url, format_amz_date, format_date_stamp, get_signature_key, hmac_sha256, infer_service,
    parse_list_objects_xml, sha256_hex,
};
use crate::sync::error::SyncError;
use crate::sync_adapters::http_client::HttpClient;
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter, UploadOutcome, UploadPrecondition};

/// S3 同步适配器配置
pub struct S3Config {
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub access_key: String,
    pub secret_key: String,
    pub use_path_style: bool,
    /// 请求超时秒数（0 = 默认 30s）
    pub timeout_secs: u64,
    /// 跳过 TLS 证书校验（自签名证书场景，用户显式开启）
    pub skip_tls_verify: bool,
}

/// S3 同步适配器
///
/// 复用现有 s3/ 模块的签名和解析逻辑，
/// 新增 reqwest HTTP 请求层。
pub struct S3Adapter {
    http: HttpClient,
    config: S3Config,
}

impl S3Adapter {
    pub fn new(config: S3Config) -> Result<Self, SyncError> {
        let timeout = if config.timeout_secs == 0 {
            30
        } else {
            config.timeout_secs
        };
        let http = HttpClient::new(timeout, 3, config.skip_tls_verify)?;
        Ok(Self { http, config })
    }

    /// 构建 S3 对象 URL
    fn build_object_url(&self, path: &str) -> String {
        build_url(
            &self.config.endpoint,
            &self.config.bucket,
            path,
            self.config.use_path_style,
            &[],
        )
    }

    /// 构建带查询参数的 S3 对象 URL（multipart 协议的 uploadId 等需要）
    fn build_object_url_with_query(&self, path: &str, query: &[(String, String)]) -> String {
        build_url(
            &self.config.endpoint,
            &self.config.bucket,
            path,
            self.config.use_path_style,
            query,
        )
    }

    /// 构建 SigV4 签名头
    ///
    /// 从完整请求 URL 解析 host / canonical_uri / canonical_querystring，
    /// 天然兼容 virtual-hosted-style 与 path-style（与移动端 `_signS3Request` 行为一致），
    /// 避免硬编码 URL 风格导致阿里云 OSS 等仅支持 virtual-hosted-style 的服务签名不匹配。
    ///
    /// 签名 service 名按 endpoint 推断（P0-4）：阿里云 OSS 的 V4 credential scope
    /// 要求 `{date}/{region}/oss/aws4_request`，硬编码 "s3" 会导致 OSS 全部请求 403。
    fn sign_request(
        &self,
        method: &str,
        url: &str,
        payload_hash: &str,
    ) -> Result<HeaderMap, SyncError> {
        let now = chrono::Utc::now();
        let amz_date = format_amz_date(&now);
        let date_stamp = format_date_stamp(&now);

        // 从完整 URL 解析 host（含端口）、canonical_uri 与 canonical_querystring
        let parsed = url::Url::parse(url).map_err(|e| SyncError::Auth {
            message: format!("无效请求 URL: {e}"),
        })?;
        let host = match parsed.port() {
            Some(p) => format!("{}:{}", parsed.host_str().unwrap_or(""), p),
            None => parsed.host_str().unwrap_or("").to_string(),
        };
        let canonical_uri = if parsed.path().is_empty() {
            "/".to_string()
        } else {
            parsed.path().to_string()
        };
        let canonical_querystring = parsed.query().unwrap_or("");

        let canonical_headers = format!(
            "host:{}\nx-amz-content-sha256:{}\nx-amz-date:{}\n",
            host, payload_hash, amz_date
        );
        let signed_headers = "host;x-amz-content-sha256;x-amz-date";

        let canonical_request = format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            method,
            canonical_uri,
            canonical_querystring,
            canonical_headers,
            signed_headers,
            payload_hash
        );

        // credential scope 的 service 按域名推断：OSS 用 "oss"，其余用 "s3"（P0-4）
        let service = infer_service(&self.config.endpoint);
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{}\n{}/{}/{}/aws4_request\n{}",
            amz_date,
            date_stamp,
            self.config.region,
            service,
            sha256_hex(canonical_request.as_bytes())
        );

        let signing_key = get_signature_key(
            &self.config.secret_key,
            &date_stamp,
            &self.config.region,
            &service,
        );
        let signature = hmac_sha256(&signing_key, string_to_sign.as_bytes());
        let signature_hex = signature
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<String>();

        let mut headers = HeaderMap::new();
        headers.insert(
            "x-amz-date",
            amz_date.parse().map_err(|_| SyncError::Auth {
                message: "无效日期头".to_string(),
            })?,
        );
        headers.insert(
            "x-amz-content-sha256",
            payload_hash.parse().map_err(|_| SyncError::Auth {
                message: "无效内容哈希头".to_string(),
            })?,
        );
        headers.insert(
            "Authorization",
            format!(
                "AWS4-HMAC-SHA256 Credential={}/{}/{}/{}/aws4_request, SignedHeaders={}, Signature={}",
                self.config.access_key, date_stamp, self.config.region, service, signed_headers,
                signature_hex
            )
            .parse()
            .map_err(|_| SyncError::Auth {
                message: "无效授权头".to_string(),
            })?,
        );

        Ok(headers)
    }

    /// 分页列举指定 prefix 下的全部对象 key（P0-3）
    ///
    /// ListObjectsV2 单页默认最多 1000 条；循环携带 `continuation-token`
    /// 直到响应无 `NextContinuationToken`，避免大桶静默截断
    /// （pull 拉不到第 1001 个附件、push 误判云端缺文件全量重传）。
    /// 防御上限 1000 页（100 万对象）防异常服务器死循环。
    async fn list_all_keys_paginated(&self, prefix: &str) -> Result<Vec<String>, SyncError> {
        // prefix 统一带尾斜杠（P0-10）：S3 prefix 是字符串前缀匹配，
        // `wait` 会同时命中 `wait2/...`、`waitfoo/...` 造成跨目录污染；
        // 解析端剥离按 `{prefix}/`，两端必须同口径
        let prefix_with_slash = if prefix.is_empty() || prefix.ends_with('/') {
            prefix.to_string()
        } else {
            format!("{}/", prefix)
        };

        let mut keys = Vec::new();
        let mut continuation_token: Option<String> = None;
        for _ in 0..1000 {
            let mut query: Vec<(String, String)> = vec![
                ("list-type".to_string(), "2".to_string()),
                ("prefix".to_string(), prefix_with_slash.clone()),
            ];
            if let Some(token) = &continuation_token {
                query.push(("continuation-token".to_string(), token.clone()));
            }
            let list_url = build_url(
                &self.config.endpoint,
                &self.config.bucket,
                "",
                self.config.use_path_style,
                &query,
            );
            let headers = self.sign_request("GET", &list_url, &sha256_hex(b""))?;
            let response_bytes = self.http.get_with_retry(&list_url, headers).await?;
            let xml = String::from_utf8_lossy(&response_bytes).to_string();

            let page = parse_list_objects_xml(&xml, &prefix_with_slash).map_err(|e| {
                SyncError::Network {
                    message: format!("解析 ListObjects XML 失败: {e}"),
                    retryable: false,
                }
            })?;
            keys.extend(page.keys);
            match page.next_token {
                Some(token) => continuation_token = Some(token),
                None => return Ok(keys),
            }
        }
        Err(SyncError::Network {
            message: "ListObjectsV2 分页超过 1000 页仍未结束，中止以防异常服务器死循环".to_string(),
            retryable: false,
        })
    }

    // ====================================================================
    // S4 multipart 分片上传（2026-09-14 收口）
    //
    // 大附件（≥ 8MiB）走 S3 原生 multipart 协议：CreateMultipartUpload
    // → 逐片 UploadPart（5MiB/片）→ CompleteMultipartUpload。分片在服务端
    // 拼装，Complete 后对象落在原路径——云端布局与单 PUT 产物完全一致，
    // 读者（download_asset）无感知。
    //
    // 收益：
    // - 失败重传单位从整文件降到单片（断网中断后续传本会话内从片边界继续，
    //   跨会话重试因确定性加密（6a711d6）密文不变，S3 侧未见 Abort 前会话
    //   的 uploadId 不可续，走新会话全量分片——但仍只花网络时间不花整文件
    //   重传的放大倍数）
    // - 慢速上行：每片一个独立 HTTP 请求 + put_part_once 的 120s 窗口，
    //   5MiB 片在 350kbps 下限链路约 2 分钟可完成；单 PUT 的 30s 窗口
    //   在 1.4Mbps 以下必超时
    // ====================================================================

    /// multipart 触发阈值：密文 ≥ 8MiB 走分片（小于此值单 PUT 更快，
    /// multipart 的 Create/Complete 两次额外请求在小对象上是纯开销）
    const MULTIPART_THRESHOLD: usize = 8 * 1024 * 1024;

    /// 分片大小：5MiB（S3 UploadPart 的最小允许片大小，除最后一片外）
    const MULTIPART_PART_SIZE: usize = 5 * 1024 * 1024;

    /// 分片级重试次数（独立于 HTTP 级与业务级重试——分片小、失败重传
    /// 代价低，可承受比整文件更高的重试密度）
    const PART_MAX_RETRIES: u32 = 3;

    /// 大对象 multipart 分片上传
    ///
    /// 流程：POST `?uploads`（Create）→ PUT `?uploadId=…&partNumber=N`
    /// 逐片 → POST `?uploadId=…`（Complete，body 为全部 PartNumber/ETag）。
    /// 任一步失败尝试 Abort（尽力而为，失败仅记日志——未 Abort 的分片由
    /// S3 生命周期规则/存储桶清理策略兜底，不影响数据正确性）。
    async fn multipart_upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        // 1. CreateMultipartUpload：POST {path}?uploads
        let create_url =
            self.build_object_url_with_query(path, &[("uploads".to_string(), String::new())]);
        let headers = self.sign_request("POST", &create_url, &sha256_hex(b""))?;
        let response = self
            .http
            .inner()
            .post(&create_url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("CreateMultipartUpload 请求失败: {e}"),
                retryable: true,
            })?;
        let status = response.status().as_u16();
        if !crate::sync::error::is_success_status(status) {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status, &body));
        }
        let create_xml = response.text().await.map_err(|e| SyncError::Network {
            message: format!("读取 CreateMultipartUpload 响应失败: {e}"),
            retryable: false,
        })?;
        let upload_id = parse_upload_id(&create_xml).ok_or_else(|| SyncError::Network {
            message: format!(
                "CreateMultipartUpload 响应缺少 UploadId: {}",
                truncate_xml(&create_xml)
            ),
            retryable: false,
        })?;

        // 2. 逐片 UploadPart（分片级重试：失败重传单片而非整文件）
        let mut part_etags: Vec<String> = Vec::new();
        for (idx, chunk) in data.chunks(Self::MULTIPART_PART_SIZE).enumerate() {
            let part_number = idx + 1;
            let etag = self
                .upload_part_with_retry(&upload_id, path, part_number, chunk)
                .await?;
            part_etags.push(etag);
        }

        // 3. CompleteMultipartUpload：POST {path}?uploadId=…（带分片清单 body）
        let complete_url =
            self.build_object_url_with_query(path, &[("uploadId".to_string(), upload_id.clone())]);
        let mut body = String::from("<CompleteMultipartUpload>\n");
        for (i, etag) in part_etags.iter().enumerate() {
            body.push_str(&format!(
                "  <Part><PartNumber>{}</PartNumber><ETag>{}</ETag></Part>\n",
                i + 1,
                etag
            ));
        }
        body.push_str("</CompleteMultipartUpload>");
        let body_bytes = body.into_bytes();
        let payload_hash = sha256_hex(&body_bytes);
        let headers = self.sign_request("POST", &complete_url, &payload_hash)?;
        let response = self
            .http
            .inner()
            .post(&complete_url)
            .headers(headers)
            .body(body_bytes)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("CompleteMultipartUpload 请求失败: {e}"),
                retryable: true,
            })?;
        let status = response.status().as_u16();
        if !crate::sync::error::is_success_status(status) {
            // Complete 偶发 500 但对象实际已拼装完成（响应丢失场景），
            // 错误 body 常含实际错误信息；不重试（重发 Complete 幂等，
            // 但 body 已消费），直接报错由业务级 with_retry 重走全流程
            let resp_body = response.text().await.unwrap_or_default();
            // Abort 尽力而为
            self.abort_multipart(path, &upload_id).await;
            return Err(SyncError::from_http_status(status, &resp_body));
        }
        Ok(())
    }

    /// 单片上传（带分片级重试：网络/限流错误重试 3 次，2/4/8s 退避）
    ///
    /// 返回该片的 ETag（Complete 阶段清单需要）。每次重试是全新的
    /// HTTP 请求（put_part_once 无 HTTP 级重试），不叠加放大。
    async fn upload_part_with_retry(
        &self,
        upload_id: &str,
        path: &str,
        part_number: usize,
        chunk: &[u8],
    ) -> Result<String, SyncError> {
        let mut last_err: Option<SyncError> = None;
        for attempt in 0..=Self::PART_MAX_RETRIES {
            let url = self.build_object_url_with_query(
                path,
                &[
                    ("partNumber".to_string(), part_number.to_string()),
                    ("uploadId".to_string(), upload_id.to_string()),
                ],
            );
            let payload_hash = sha256_hex(chunk);
            let headers = self.sign_request("PUT", &url, &payload_hash)?;
            match self.http.put_part_once(&url, headers, chunk.to_vec()).await {
                Ok(Some(etag)) => return Ok(etag),
                Ok(None) => {
                    // ETag 缺失按错误处理：Complete 清单缺 ETag 会被 S3 拒绝，
                    // 早失败比 Complete 时失败重试代价低
                    return Err(SyncError::Network {
                        message: format!(
                            "分片 {part_number} 上传成功但响应缺少 ETag 头，无法构造 Complete 清单"
                        ),
                        retryable: false,
                    });
                }
                Err(e) => {
                    let retryable = e.is_retryable() && !e.is_rate_limited();
                    if !retryable || attempt == Self::PART_MAX_RETRIES {
                        return Err(e);
                    }
                    last_err = Some(e);
                }
            }
            let delay = std::time::Duration::from_secs(2u64.pow(attempt));
            tokio::time::sleep(delay).await;
        }
        Err(last_err.unwrap_or_else(|| SyncError::Network {
            message: "分片上传未知错误".to_string(),
            retryable: false,
        }))
    }

    /// AbortMultipartUpload（尽力而为：失败仅日志，不影响主错误）
    async fn abort_multipart(&self, path: &str, upload_id: &str) {
        let url = self
            .build_object_url_with_query(path, &[("uploadId".to_string(), upload_id.to_string())]);
        let headers = match self.sign_request("DELETE", &url, &sha256_hex(b"")) {
            Ok(h) => h,
            Err(e) => {
                log::info!("[s3 multipart] Abort 签名失败（忽略）: {e}");
                return;
            }
        };
        match self.http.inner().delete(&url).headers(headers).send().await {
            Ok(r) if r.status().is_success() => {}
            other => {
                let desc = match other {
                    Ok(r) => format!("HTTP {}", r.status()),
                    Err(e) => e.to_string(),
                };
                log::info!(
                    "[s3 multipart] Abort 未成功（忽略，未清理分片由存储桶策略兜底）: {desc}"
                );
            }
        }
    }
}

#[async_trait]
impl SyncAdapter for S3Adapter {
    async fn list_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        // v7: 复用 list_all_files，再过滤同步后缀（默认 .orsync，兼容遗留 .waitsync）
        let all = self.list_all_files(base_path).await?;
        Ok(all
            .into_iter()
            .filter(|f| crate::cloud_sync::paths::is_sync_payload_name(&f.name))
            .collect())
    }

    async fn list_all_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        // 分页列举（P0-3）：>1000 对象不再静默截断
        let keys = self.list_all_keys_paginated(base_path).await?;

        // 将 key 列表转为 RemoteFile（不过滤后缀，调用方自行过滤）
        // lamport_version 无法从 ListObjects 响应获取（.waitsync 是二进制包，
        // lamport_version 在包内 SyncRecord 中），保持 0，由 Pull 阶段下载后从包内容获取
        let files: Vec<RemoteFile> = keys
            .into_iter()
            .map(|k| RemoteFile {
                name: k,
                size: 0,
                last_modified: 0,
                lamport_version: 0,
            })
            .collect();

        Ok(files)
    }

    async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
        let url = self.build_object_url(path);
        let headers = self.sign_request("GET", &url, &sha256_hex(b""))?;
        self.http.get_with_retry(&url, headers).await
    }

    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        // S4：大对象走 multipart 分片（服务端拼装，产物与单 PUT 一致）；
        // 小对象保持单 PUT（Create/Complete 两次额外请求在小对象上是纯开销）
        if data.len() >= Self::MULTIPART_THRESHOLD {
            return self.multipart_upload(path, data).await;
        }
        let url = self.build_object_url(path);
        let payload_hash = sha256_hex(data);
        let headers = self.sign_request("PUT", &url, &payload_hash)?;
        self.http.put_with_retry(&url, headers, data.to_vec()).await
    }

    async fn delete(&self, path: &str) -> Result<(), SyncError> {
        // S3 DELETE 请求
        let url = self.build_object_url(path);
        let headers = self.sign_request("DELETE", &url, &sha256_hex(b""))?;

        let response = self
            .http
            .inner()
            .delete(&url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("DELETE 请求失败: {e}"),
                // S12：传输层失败（连接中断/超时）是瞬态，标可重试——
                // 此前 retryable:false 让业务级 with_retry 直接放弃
                retryable: true,
            })?;

        // Fix-03：校验状态码，403/500 等失败不得静默成功
        SyncError::check_delete_status(response.status().as_u16())
    }

    async fn upload_asset(&self, hash: &str, data: &[u8]) -> Result<(), SyncError> {
        // 默认统一上传到 assets/{hash}.orsync
        let path = crate::cloud_sync::paths::asset_path(hash);
        self.upload(&path, data).await
    }

    async fn download_asset(&self, hash: &str) -> Result<Vec<u8>, SyncError> {
        // 单一路径：assets/{hash}.orsync（无历史数据，不再回退遗留命名）
        self.download(&crate::cloud_sync::paths::asset_path(hash)).await
    }

    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
        // HEAD 存在性探测（403/500/429 透传类型化错误，不得静默当不存在）
        self.exists(&crate::cloud_sync::paths::asset_path(hash)).await
    }

    async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
        // 分页列举（P0-3）：附件超过 1000 个不再静默截断
        let keys = self.list_all_keys_paginated("assets/").await?;

        // 新版本文件名为 {hash}.orsync，需剥离同步后缀以保持接口契约。
        // 遗留 {hash}.waitsync / 裸 {hash} 同口径剥离。去重后返回。
        let mut hashes: Vec<String> = keys
            .into_iter()
            .map(|k| crate::cloud_sync::paths::strip_sync_extension(&k).to_string())
            .collect();
        // S30：dedup 只去相邻重复，先排序保证同名（多后缀并存）全去
        hashes.sort();
        hashes.dedup();
        Ok(hashes)
    }

    // ========================================================================
    // 轻量探测 / 并发令牌 / 条件写
    // ========================================================================

    /// HEAD 存在性探测（不再为判断存在而下载整个对象）
    async fn exists(&self, path: &str) -> Result<bool, SyncError> {
        let url = self.build_object_url(path);
        let headers = self.sign_request("HEAD", &url, &sha256_hex(b""))?;
        let response = self
            .http
            .inner()
            .head(&url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("HEAD 请求失败: {e}"),
                retryable: true,
            })?;
        SyncError::classify_head_status(response.status().as_u16())
    }

    /// 读取对象与并发令牌（S3 回 ETag）
    async fn download_with_token(
        &self,
        path: &str,
    ) -> Result<Option<(Vec<u8>, Option<String>)>, SyncError> {
        let url = self.build_object_url(path);
        let headers = self.sign_request("GET", &url, &sha256_hex(b""))?;
        match self.http.get_with_token(&url, headers).await {
            Ok((bytes, token)) => Ok(Some((bytes, token))),
            Err(e) if e.is_not_found() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// 条件 PUT（S3/OSS 支持 If-Match 与 If-None-Match: *）
    ///
    /// 清单是小对象（不会触达 multipart 分派阈值），条件头可达。
    async fn upload_conditional(
        &self,
        path: &str,
        data: &[u8],
        precondition: UploadPrecondition,
    ) -> Result<UploadOutcome, SyncError> {
        let url = self.build_object_url(path);
        let payload_hash = sha256_hex(data);
        let headers = self.sign_request("PUT", &url, &payload_hash)?;
        let (if_match, if_none_star) = match &precondition {
            UploadPrecondition::None => (None, false),
            UploadPrecondition::Absent => (None, true),
            UploadPrecondition::Match(token) => (Some(token.as_str()), false),
        };
        let ok = self
            .http
            .put_conditional(&url, headers, data.to_vec(), if_match, if_none_star)
            .await?;
        Ok(if ok {
            UploadOutcome::Ok
        } else {
            UploadOutcome::PreconditionFailed
        })
    }
}

// ============================================================================
// multipart 协议辅助（纯函数，供单测）
// ============================================================================

/// 从 CreateMultipartUpload 响应 XML 提取 UploadId
///
/// 响应形如 `<UploadId>…</UploadId>`；简单标签提取足够（无嵌套/转义语义），
/// 不引完整 XML 解析器。
pub(crate) fn parse_upload_id(xml: &str) -> Option<String> {
    let start = xml.find("<UploadId>")? + "<UploadId>".len();
    let end = xml[start..].find("</UploadId>")? + start;
    let id = &xml[start..end];
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

/// 截断 XML 用于错误日志（防大响应刷屏）
///
/// `…` 是多字节字符，断言用字符数而非 String::len()（字节数）。
pub(crate) fn truncate_xml(xml: &str) -> String {
    if xml.len() <= 200 {
        xml.to_string()
    } else {
        format!("{}…", &xml[..200])
    }
}

#[cfg(test)]
mod multipart_tests {
    use super::*;

    #[test]
    fn parse_upload_id_extracts_value() {
        let xml = r#"<?xml version="1.0"?>
<InitiateMultipartUploadResult>
  <Bucket>wait</Bucket>
  <Key>assets/abc.orsync</Key>
  <UploadId>VXBsb2FkIElEIGZvciA2ly+xx</UploadId>
</InitiateMultipartUploadResult>"#;
        assert_eq!(
            parse_upload_id(xml).as_deref(),
            Some("VXBsb2FkIElEIGZvciA2ly+xx")
        );
    }

    #[test]
    fn parse_upload_id_missing_returns_none() {
        assert!(parse_upload_id("<Error><Code>x</Code></Error>").is_none());
        assert!(
            parse_upload_id("<UploadId></UploadId>").is_none(),
            "空值视为缺失"
        );
    }

    #[test]
    fn truncate_keeps_short_and_cuts_long() {
        assert_eq!(truncate_xml("short"), "short");
        let long = "x".repeat(300);
        let cut = truncate_xml(&long);
        // 字符数：200 个 x + 1 个省略号 = 201（String::len 是字节数，
        // … 占 3 字节，len() = 203）
        assert_eq!(cut.chars().count(), 201);
        assert_eq!(cut.len(), 203);
    }

    /// multipart 分片纯计算：8MiB 阈值 = 1 个完整 5MiB 片 + 3MiB 尾片
    #[test]
    fn multipart_chunking_math() {
        let total = S3Adapter::MULTIPART_THRESHOLD;
        let full = total / S3Adapter::MULTIPART_PART_SIZE;
        let rem = total % S3Adapter::MULTIPART_PART_SIZE;
        assert_eq!(full, 1, "8MiB 阈值含 1 个完整 5MiB 片");
        assert!(rem > 0 && rem < S3Adapter::MULTIPART_PART_SIZE, "尾片 3MiB");
    }
}
