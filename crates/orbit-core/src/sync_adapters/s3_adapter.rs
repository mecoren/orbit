use async_trait::async_trait;
use reqwest::header::HeaderMap;

use crate::s3::{
    build_url, format_amz_date, format_date_stamp, get_signature_key, hmac_sha256,
    parse_list_objects_xml, sha256_hex,
};
use crate::sync::error::SyncError;
use crate::sync_adapters::http_client::HttpClient;
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter};

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
        let timeout = if config.timeout_secs == 0 { 30 } else { config.timeout_secs };
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

    /// 构建 SigV4 签名头
    ///
    /// 从完整请求 URL 解析 host / canonical_uri / canonical_querystring，
    /// 天然兼容 virtual-hosted-style 与 path-style（与移动端 `_signS3Request` 行为一致），
    /// 避免硬编码 URL 风格导致阿里云 OSS 等仅支持 virtual-hosted-style 的服务签名不匹配。
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

        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{}\n{}/{}/s3/aws4_request\n{}",
            amz_date,
            date_stamp,
            self.config.region,
            sha256_hex(canonical_request.as_bytes())
        );

        let signing_key = get_signature_key(
            &self.config.secret_key,
            &date_stamp,
            &self.config.region,
            "s3",
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
                "AWS4-HMAC-SHA256 Credential={}/{}/{}/s3/aws4_request, SignedHeaders={}, Signature={}",
                self.config.access_key, date_stamp, self.config.region, signed_headers, signature_hex
            )
            .parse()
            .map_err(|_| SyncError::Auth {
                message: "无效授权头".to_string(),
            })?,
        );

        Ok(headers)
    }
}

#[async_trait]
impl SyncAdapter for S3Adapter {
    async fn list_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        // v7: 复用 list_all_files，再过滤 .waitsync 后缀（保持原契约）
        let all = self.list_all_files(base_path).await?;
        Ok(all
            .into_iter()
            .filter(|f| f.name.ends_with(".waitsync"))
            .collect())
    }

    async fn list_all_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        let list_url = build_url(
            &self.config.endpoint,
            &self.config.bucket,
            "",
            self.config.use_path_style,
            &[
                ("list-type".to_string(), "2".to_string()),
                ("prefix".to_string(), base_path.to_string()),
            ],
        );

        let headers = self.sign_request("GET", &list_url, &sha256_hex(b""))?;

        let response_bytes = self.http.get_with_retry(&list_url, headers).await?;
        let xml = String::from_utf8_lossy(&response_bytes).to_string();

        let keys = parse_list_objects_xml(&xml, base_path).map_err(|e| SyncError::Network {
            message: format!("解析 ListObjects XML 失败: {e}"),
            retryable: false,
        })?;

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
                retryable: false,
            })?;

        // Fix-03：校验状态码，403/500 等失败不得静默成功
        SyncError::check_delete_status(response.status().as_u16())
    }

    async fn upload_asset(&self, hash: &str, data: &[u8]) -> Result<(), SyncError> {
        // 新版本统一上传到 assets/{hash}.waitsync
        let path = format!("assets/{hash}.waitsync");
        self.upload(&path, data).await
    }

    async fn download_asset(&self, hash: &str) -> Result<Vec<u8>, SyncError> {
        // 双读回退：先试 .waitsync 新路径，404 再回退无扩展名旧路径
        let new_path = format!("assets/{hash}.waitsync");
        match self.download(&new_path).await {
            Ok(data) => Ok(data),
            Err(e) if e.is_not_found() => {
                let legacy_path = format!("assets/{hash}");
                self.download(&legacy_path).await
            }
            Err(e) => Err(e),
        }
    }

    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
        // 检查新路径；若不存在再检查旧路径（迁移期间可能两份都存在或仅旧路径存在）
        let new_path = format!("assets/{hash}.waitsync");
        let new_url = self.build_object_url(&new_path);
        let new_headers = self.sign_request("HEAD", &new_url, &sha256_hex(b""))?;

        let result = self
            .http
            .inner()
            .head(&new_url)
            .headers(new_headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("HEAD 请求失败: {e}"),
                retryable: false,
            })?;

        if result.status().is_success() {
            return Ok(true);
        }

        // 新路径不存在，回退检查旧路径
        let legacy_path = format!("assets/{hash}");
        let legacy_url = self.build_object_url(&legacy_path);
        let legacy_headers = self.sign_request("HEAD", &legacy_url, &sha256_hex(b""))?;

        let result = self
            .http
            .inner()
            .head(&legacy_url)
            .headers(legacy_headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("HEAD 请求失败: {e}"),
                retryable: false,
            })?;

        Ok(result.status().is_success())
    }

    async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
        let prefix = "assets/";
        let list_url = build_url(
            &self.config.endpoint,
            &self.config.bucket,
            "",
            self.config.use_path_style,
            &[
                ("list-type".to_string(), "2".to_string()),
                ("prefix".to_string(), prefix.to_string()),
            ],
        );

        let headers = self.sign_request("GET", &list_url, &sha256_hex(b""))?;

        let response_bytes = self.http.get_with_retry(&list_url, headers).await?;
        let xml = String::from_utf8_lossy(&response_bytes).to_string();

        let keys = parse_list_objects_xml(&xml, prefix).map_err(|e| SyncError::Network {
            message: format!("解析 ListObjects XML 失败: {e}"),
            retryable: false,
        })?;

        // 新版本文件名为 {hash}.waitsync，需剥离 .waitsync 后缀以保持接口契约。
        // 旧版本文件名为 {hash}（无后缀），保持原样。两者去重后返回。
        let mut hashes: Vec<String> = keys
            .into_iter()
            .map(|k| {
                k.strip_suffix(".waitsync").unwrap_or(&k).to_string()
            })
            .collect();
        hashes.dedup();
        Ok(hashes)
    }
}
