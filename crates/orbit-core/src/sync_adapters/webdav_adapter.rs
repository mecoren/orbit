use std::collections::HashSet;
use std::sync::Mutex;

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderMap};

use crate::sync::error::SyncError;
use crate::sync_adapters::http_client::HttpClient;
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter};
use crate::webdav::parse_propfind_response;

/// WebDAV 同步适配器配置
pub struct WebDavConfig {
    pub server_url: String,
    pub username: String,
    pub password: String,
    /// 请求超时秒数（0 = 默认 30s）
    pub timeout_secs: u64,
    /// 跳过 TLS 证书校验（自签名证书场景，用户显式开启）
    pub skip_tls_verify: bool,
}

/// WebDAV 同步适配器
///
/// 复用现有 webdav/ 模块的 PROPFIND 解析逻辑，
/// 新增 reqwest HTTP 请求层。
///
/// 目录存在性缓存：`ensure_directory` 对每个路径只 PROPFIND 一次，
/// 后续相同路径直接跳过，避免坚果云等限流严格的服务被频繁 PROPFIND 触发 503。
pub struct WebDavAdapter {
    http: HttpClient,
    config: WebDavConfig,
    /// 已确认存在的目录路径缓存（避免重复 PROPFIND）
    ///
    /// 使用 `Mutex<HashSet<String>>` 而非 `tokio::sync::Mutex`：
    /// 检查/插入是同步快速操作，无需跨 await 持有锁。
    /// 适配器本身通过 `Arc<WebDavAdapter>` 共享，HashSet 跨克隆共享同一份。
    dir_cache: Mutex<HashSet<String>>,
}

impl WebDavAdapter {
    pub fn new(config: WebDavConfig) -> Result<Self, SyncError> {
        // timeout_secs=0 视为未设置，回落默认 30s
        let timeout = if config.timeout_secs == 0 {
            30
        } else {
            config.timeout_secs
        };
        let http = HttpClient::new(timeout, 3, config.skip_tls_verify)?;
        Ok(Self {
            http,
            config,
            dir_cache: Mutex::new(HashSet::new()),
        })
    }

    /// 构建 Basic Auth 头
    fn auth_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        let credentials = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            format!("{}:{}", self.config.username, self.config.password),
        );
        headers.insert(
            AUTHORIZATION,
            format!("Basic {}", credentials).parse().unwrap(),
        );
        headers
    }

    /// 构建完整的 WebDAV URL
    fn build_url(&self, path: &str) -> String {
        let base = self.config.server_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{}{}", base, path)
        } else {
            format!("{}/{}", base, path)
        }
    }

    /// 确保目录存在,逐级创建(MKCOL)
    ///
    /// `path` 为目录路径(如 `sync/data` 或 `assets`),无需尾斜杠。
    /// 逐级创建每一级目录,当某级返回 409(父目录不存在)时,
    /// 自动递归向上创建所有缺失的父目录,然后重试当前目录。
    /// PROPFIND 预检查避免递归循环(父目录已存在但 MKCOL 仍 409 的场景)。
    ///
    /// 复用已有目录:每级先 PROPFIND 预检,存在则跳过 MKCOL,
    /// 避免 WebDAV 上已有同名文件夹时仍触发新建(路径大小写/尾斜杠不一致场景)。
    ///
    /// 目录存在性缓存:已确认存在的目录路径记录在 `dir_cache` 中,
    /// 后续相同路径直接跳过,避免对坚果云等限流严格的服务频繁 PROPFIND。
    async fn ensure_directory(&self, path: &str) -> Result<(), SyncError> {
        let clean_path = path.trim_matches('/');
        if clean_path.is_empty() {
            return Ok(());
        }

        // 缓存命中：路径已确认存在，直接跳过（避免 PROPFIND 请求）
        if let Ok(cache) = self.dir_cache.lock()
            && cache.contains(clean_path)
        {
            return Ok(());
        }

        // 按层级逐级创建:sync/data → 先创建 sync,再创建 sync/data
        let parts: Vec<&str> = clean_path.split('/').filter(|s| !s.is_empty()).collect();
        let mut current = String::new();

        for part in parts {
            if current.is_empty() {
                current = part.to_string();
            } else {
                current = format!("{}/{}", current, part);
            }
            // 缓存命中：该层级已确认存在，跳过
            let cached = self
                .dir_cache
                .lock()
                .map(|c| c.contains(&current))
                .unwrap_or(false);
            if cached {
                continue;
            }
            let url = self.build_url(&current);
            // 预检:目录已存在则直接跳过,复用 WebDAV 上已有文件夹
            if self.url_exists(&url).await? {
                // 缓存：该层级已确认存在
                if let Ok(mut cache) = self.dir_cache.lock() {
                    cache.insert(current.clone());
                }
                continue;
            }
            self.mkcol_with_retry(&url, 0).await?;
            // 缓存：该层级已成功创建
            if let Ok(mut cache) = self.dir_cache.lock() {
                cache.insert(current.clone());
            }
        }

        Ok(())
    }

    /// 对指定 URL 执行 MKCOL,409 时递归向上创建父目录
    ///
    /// WebDAV RFC 4918: MKCOL 返回 409 表示父目录不存在(AncestorsNotFound)。
    /// 此方法自动解析父目录 URL 并递归创建,直到成功或到达 host 根。
    ///
    /// 防循环策略:用 PROPFIND 检查父目录是否真实存在:
    /// - 父目录不存在 → 递归创建父目录,然后重试当前目录
    /// - 父目录已存在但 MKCOL 仍 409 → 真实错误(权限/目录名无效),不重试
    ///
    /// 幂等性保障:5xx(含 503)时先用 PROPFIND 检查目录是否已存在。
    /// 部分 WebDAV 服务器在过载时对 MKCOL 返回 503,但目录可能已被创建
    /// (前一次 MKCOL 请求到达但响应丢失)。此时视为成功,避免无谓重试。
    async fn mkcol_with_retry(&self, url: &str, depth: u32) -> Result<(), SyncError> {
        // 防止异常情况下的无限递归(正常路径不会超过 10 层)
        if depth > 10 {
            return Err(SyncError::Network {
                message: format!("MKCOL 递归创建目录深度超限(>10): {url}"),
                retryable: false,
            });
        }

        let headers = self.auth_headers();
        let response = self
            .http
            .inner()
            .request(reqwest::Method::from_bytes(b"MKCOL").unwrap(), url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("MKCOL 请求失败: {e}"),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        match status {
            // 201 Created: 目录创建成功
            // 405 Method Not Allowed: 目录已存在(RFC 4918 标准行为)
            // 301/302: 重定向(目录已存在)
            201 | 301 | 302 | 405 => Ok(()),
            // 409 Conflict: 按 RFC 4918 表示父目录不存在(AncestorsNotFound)
            // 用 PROPFIND 检查父目录状态以决定递归或报错,避免死循环
            409 => {
                let body = response.text().await.unwrap_or_default();

                // 先检查目标目录是否已存在(部分非标准服务器对已存在目录返回 409)
                if self.url_exists(url).await? {
                    return Ok(());
                }

                // 目标目录确实不存在,检查父目录是否存在
                match Self::parent_url(url) {
                    Some(parent_url) => {
                        let parent_exists = self.url_exists(&parent_url).await?;

                        if parent_exists {
                            // 父目录已存在但 MKCOL 仍返回 409:
                            // 非祖先缺失,而是权限/名称等问题,直接报错避免死循环
                            Err(SyncError::Config {
                                field: "endpoint/path".to_string(),
                                message: format!(
                                    "无法创建云端目录「{url}」: 父目录已存在但服务器拒绝创建(409)。\
                                     可能原因:目录名含非法字符、权限不足、或服务器限制。\
                                     服务器响应: {body}"
                                ),
                            })
                        } else {
                            // 父目录不存在,递归创建后再重试当前目录
                            // (Box::pin 解决 async fn 递归限制)
                            Box::pin(self.mkcol_with_retry(&parent_url, depth + 1)).await?;
                            Box::pin(self.mkcol_with_retry(url, depth + 1)).await
                        }
                    }
                    None => {
                        // 已到达 host 根仍返回 409,无法继续创建
                        Err(SyncError::Config {
                            field: "endpoint".to_string(),
                            message: format!(
                                "无法创建云端目录「{url}」: 服务器返回 409 AncestorsNotFound,\
                                 且已到达根目录仍无法创建。请检查 endpoint 是否指向有效的 WebDAV 路径。\
                                 服务器响应: {body}"
                            ),
                        })
                    }
                }
            }
            // 5xx 服务端错误:先检查目录是否已存在,存在则视为成功(幂等)
            // 场景:服务器过载时对 MKCOL 返回 503,但前一次请求可能已创建目录
            500..=599 => {
                let body = response.text().await.unwrap_or_default();
                if self.url_exists(url).await? {
                    // 目录已存在,幂等返回成功
                    Ok(())
                } else {
                    Err(SyncError::Network {
                        message: format!("MKCOL 创建目录失败: HTTP {status}: {body}"),
                        retryable: true,
                    })
                }
            }
            _ => {
                let body = response.text().await.unwrap_or_default();
                Err(SyncError::Network {
                    message: format!("MKCOL 创建目录失败: HTTP {status}: {body}"),
                    retryable: false,
                })
            }
        }
    }

    /// 检查指定 URL 的资源是否存在(PROPFIND Depth:0)
    ///
    /// 用于 MKCOL 返回 409 时区分"父目录不存在"和"目录已存在"等场景,
    /// 避免盲目递归导致死循环。返回 true 表示存在(207/2xx),false 表示不存在(404)。
    async fn url_exists(&self, url: &str) -> Result<bool, SyncError> {
        let mut headers = self.auth_headers();
        headers.insert("Depth", "0".parse().unwrap());
        headers.insert("Content-Type", "application/xml".parse().unwrap());

        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
  </d:prop>
</d:propfind>"#;

        let response = self
            .http
            .inner()
            .request(reqwest::Method::from_bytes(b"PROPFIND").unwrap(), url)
            .headers(headers)
            .body(propfind_body.to_string())
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("PROPFIND 验证请求失败: {e}"),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        // 207 Multi-Status 或 2xx: 资源存在
        // 404: 资源不存在
        Ok(status == 207 || (200..=299).contains(&status))
    }

    /// 解析 URL 的父目录 URL
    ///
    /// 如 "https://host/dav/myfolder/sync" → Some("https://host/dav/myfolder")
    /// 如 "https://host/dav" → Some("https://host")  (host 根)
    /// 如 "https://host" → None  (无法再向上,已到根)
    fn parent_url(url: &str) -> Option<String> {
        // 去掉 query 和 fragment
        let url = url.split('?').next().unwrap_or(url);
        let url = url.split('#').next().unwrap_or(url);
        // 去掉末尾斜杠
        let url = url.trim_end_matches('/');

        // 定位 "://" 分隔符
        let scheme_end = url.find("://")?;
        // "://" 之后的部分(host/path)
        let after_scheme = &url[scheme_end + 3..];

        // 在 after_scheme 中找最后一个 '/'(即 path 的最后一段分隔符)
        let last_slash = after_scheme.rfind('/')?;
        // 截取到该 '/' 为止,即为父目录 URL
        let parent = &url[..scheme_end + 3 + last_slash];
        if parent.is_empty() {
            None
        } else {
            Some(parent.to_string())
        }
    }
}

#[async_trait]
impl SyncAdapter for WebDavAdapter {
    async fn list_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        // v7: 复用 list_all_files，再过滤 .waitsync 后缀（保持原契约）
        let all = self.list_all_files(base_path).await?;
        Ok(all
            .into_iter()
            .filter(|f| f.name.ends_with(".waitsync"))
            .collect())
    }

    async fn list_all_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        let url = self.build_url(base_path);

        let mut headers = self.auth_headers();
        headers.insert("Depth", "1".parse().unwrap());
        headers.insert("Content-Type", "application/xml".parse().unwrap());

        // 请求 resourcetype 以识别目录条目（RFC 4918 标准）：目录若不被过滤，
        // 其尾斜杠 href 会使 basename 提取退化为整条 URL 混入文件列表，
        // 污染 cloud_has_module_data 探测与附件 diff（见 07 排查报告 P0-1）。
        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>"#;

        let response = self
            .http
            .inner()
            .request(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap_or(reqwest::Method::GET),
                &url,
            )
            .headers(headers)
            .body(propfind_body.to_string())
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("PROPFIND 请求失败: {e}"),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        // 404: 目录不存在,视为空目录(首次同步时目录尚未创建)
        if status == 404 {
            return Ok(Vec::new());
        }
        if !response.status().is_success() && status != 207 {
            return Err(SyncError::Network {
                message: format!("PROPFIND 失败: {}", response.status()),
                retryable: false,
            });
        }

        let xml = response.text().await.map_err(|e| SyncError::Network {
            message: format!("读取 PROPFIND 响应失败: {e}"),
            retryable: false,
        })?;

        let entries = parse_propfind_response(&xml).map_err(|e| SyncError::Network {
            message: format!("解析 PROPFIND XML 失败: {e}"),
            retryable: false,
        })?;

        // 转换为 RemoteFile（v7: 不过滤后缀，调用方自行过滤）
        // 过滤掉目录本身（is_collection=true）和空 href 条目
        // 将 RFC 2822 日期字符串解析为 Unix 时间戳（毫秒），解析失败时回退为 0
        // v7: name 统一使用 basename（仅文件名），与 S3 adapter 行为一致
        // 坚果云等 WebDAV 服务 PROPFIND 返回的 href 是服务器绝对路径
        // （如 /dav/wait-home/backups/file.waitfullsync），直接作为 name 会导致
        // 调用方拼接路径时重复前缀，必须提取最后一段路径作为文件名
        let files: Vec<RemoteFile> = entries
            .into_iter()
            .filter(|e| !e.is_collection && !e.href.is_empty())
            .map(|e| {
                let last_modified = e
                    .last_modified
                    .as_deref()
                    .and_then(|s| chrono::DateTime::parse_from_rfc2822(s).ok())
                    .map(|dt| dt.timestamp())
                    .unwrap_or(0);
                // 优先使用 display_name，否则从 href 提取 basename。
                // 先剥尾斜杠再取最后一段：目录条目的 href 以 "/" 结尾，
                // rsplit 会取到空串；直接回退整条 URL 会把目录当文件混入列表
                let name = e.display_name.unwrap_or_else(|| {
                    e.href
                        .trim_end_matches('/')
                        .rsplit('/')
                        .next()
                        .filter(|s| !s.is_empty())
                        .unwrap_or(&e.href)
                        .to_string()
                });
                RemoteFile {
                    name,
                    size: e.content_length.unwrap_or(0) as u64,
                    last_modified,
                    lamport_version: 0,
                }
            })
            .collect();

        Ok(files)
    }

    async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
        let url = self.build_url(path);
        let headers = self.auth_headers();
        match self.http.get_with_retry(&url, headers).await {
            Ok(data) => Ok(data),
            Err(SyncError::Network { message, retryable }) => {
                // 坚果云在父目录不存在时对 GET 返回 409 AncestorsNotFound，
                // 这与 MKCOL 的 409 语义不同，应视为资源不存在而非网络错误。
                if message.contains("HTTP 409") && message.contains("AncestorsNotFound") {
                    Err(SyncError::NotFound {
                        message: format!("资源不存在(409): {message}"),
                    })
                } else {
                    Err(SyncError::Network { message, retryable })
                }
            }
            Err(e) => Err(e),
        }
    }

    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        // 先确保父目录存在,避免 409 AncestorsNotFound
        // (如 path = "sync/data/file.waitsync" → 创建 sync/data 目录)
        if let Some(parent) = path.rsplit_once('/').map(|(p, _)| p)
            && !parent.is_empty()
        {
            self.ensure_directory(parent).await?;
        }

        let url = self.build_url(path);
        let headers = self.auth_headers();
        self.http.put_with_retry(&url, headers, data.to_vec()).await
    }

    async fn delete(&self, path: &str) -> Result<(), SyncError> {
        let url = self.build_url(path);
        let headers = self.auth_headers();

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
        // 检查新路径；若 404/409 再检查旧路径（迁移期间可能两份都存在或仅旧路径存在）。
        // P1-2：HEAD 非 2xx 不再一律当「不存在」——403/500 透传错误，
        // 只有 404/409 才回退旧路径（与 S3 适配器同口径）
        let new_path = format!("assets/{hash}.waitsync");
        let new_url = self.build_url(&new_path);
        let headers = self.auth_headers();

        let result = self
            .http
            .inner()
            .head(&new_url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("HEAD 请求失败: {e}"),
                retryable: false,
            })?;

        match SyncError::classify_head_status(result.status().as_u16())? {
            true => return Ok(true),
            false => {}
        }

        // 新路径不存在（404/409），回退检查旧路径
        let legacy_path = format!("assets/{hash}");
        let legacy_url = self.build_url(&legacy_path);
        let headers = self.auth_headers();
        let result = self
            .http
            .inner()
            .head(&legacy_url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("HEAD 请求失败: {e}"),
                retryable: false,
            })?;

        SyncError::classify_head_status(result.status().as_u16())
    }

    async fn list_assets(&self) -> Result<Vec<String>, SyncError> {
        let url = self.build_url("assets/");

        let mut headers = self.auth_headers();
        headers.insert("Depth", "1".parse().unwrap());
        headers.insert("Content-Type", "application/xml".parse().unwrap());

        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>"#;

        let response = self
            .http
            .inner()
            .request(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap_or(reqwest::Method::GET),
                &url,
            )
            .headers(headers)
            .body(propfind_body.to_string())
            .send()
            .await
            .map_err(|e| SyncError::Network {
                message: format!("PROPFIND 请求失败: {e}"),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        // 404: 目录不存在,视为空列表(首次使用时 assets 目录尚未创建)
        if status == 404 {
            return Ok(Vec::new());
        }
        if !response.status().is_success() && status != 207 {
            return Err(SyncError::Network {
                message: format!("PROPFIND 失败: {}", response.status()),
                retryable: false,
            });
        }

        let xml = response.text().await.map_err(|e| SyncError::Network {
            message: format!("读取 PROPFIND 响应失败: {e}"),
            retryable: false,
        })?;

        let entries = parse_propfind_response(&xml).map_err(|e| SyncError::Network {
            message: format!("解析 PROPFIND XML 失败: {e}"),
            retryable: false,
        })?;

        // 提取 hash：跳过目录本身（is_collection），从 display_name 或 href 提取文件名。
        // href 先剥尾斜杠（目录条目防御：rsplit 对尾斜杠取到空串）。
        // 新版本文件名为 {hash}.waitsync，需剥离 .waitsync 后缀以保持接口契约。
        // 旧版本文件名为 {hash}（无后缀），保持原样。两者去重后返回。
        let mut hashes: Vec<String> = entries
            .into_iter()
            .filter(|e| !e.is_collection)
            .map(|e| {
                e.display_name.unwrap_or_else(|| {
                    e.href
                        .trim_end_matches('/')
                        .rsplit('/')
                        .next()
                        .unwrap_or("")
                        .to_string()
                })
            })
            .filter(|s| !s.is_empty())
            .map(|name| {
                // 剥离 .waitsync 后缀（新版本文件名）
                name.strip_suffix(".waitsync").unwrap_or(&name).to_string()
            })
            .collect();
        hashes.dedup();
        Ok(hashes)
    }
}
