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

/// head.json 明文清单结构（S4 WebDAV 分片协议）
///
/// serde 序列化为 JSON 上传；下载侧解析。字段不含任何密钥材料
/// （sha256 是密文内容的哈希）。跨密钥防混片由 sha256 天然承担：
/// 确定性加密的 nonce 派生含 data_key——不同 Data Key 加密同一附件
/// 产出不同密文 → sha256 不同 → 续传判定失败 → 清目录重传。
#[derive(serde::Serialize, serde::Deserialize)]
struct AssetPartsHead {
    total: usize,
    size: usize,
    sha256: String,
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
    ///
    /// S2（2026-09-13 探查）：server_url 无 scheme 时补 https://（与 S3
    /// build_url 的 normalize 同口径）——无 scheme URL 会让 reqwest 请求
    /// 构造直接失败且错误归类误导排障。
    fn build_url(&self, path: &str) -> String {
        let trimmed = self.config.server_url.trim();
        let base = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
            trimmed.trim_end_matches('/').to_string()
        } else {
            format!("https://{}", trimmed)
                .trim_end_matches('/')
                .to_string()
        };
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

    // ================================================================
    // S4 WebDAV 分片协议（2026-09-14 收口）
    //
    // WebDAV 无 multipart 标准协议，自造分片布局（云端）：
    //   assets_parts/{hash}/head.json      # 明文清单（无密钥材料）
    //   assets_parts/{hash}/000000.bin …  # 密文分片
    //
    // head.json 字段：total（分片数）/ size（密文字节数）/ sha256（密文
    // 整体哈希）。跨密钥防混片由 sha256 天然承担：确定性加密（6a711d6）
    // 的 nonce 派生含 data_key——不同 Data Key 加密同一附件产出不同密文
    // → sha256 不同 → 续传判定失败 → 清目录重传。无需独立的 key 指纹
    // 字段，适配器也不必持有 crypto。
    //
    // 断点续传：上传前 HEAD 探测已存在的分片（大小等于本片期望大小才
    // 跳过——确定性加密保证同片字节一致，大小相等即内容相等的可靠
    // 代理），中断重试只传缺失片。
    // ================================================================

    /// 分片触发阈值（密文 ≥ 8MiB）与片大小（5MiB）——与 S3 侧同口径
    const PARTS_THRESHOLD: usize = 8 * 1024 * 1024;
    const PARTS_SIZE: usize = 5 * 1024 * 1024;

    /// 分片路径：`assets_parts/{hash}/{index:06}.bin`
    fn part_bin_path(hash: &str, index: usize) -> String {
        format!("assets_parts/{hash}/{index:06}.bin")
    }

    /// 清单路径：`assets_parts/{hash}/head.json`
    fn parts_head_path(hash: &str) -> String {
        format!("assets_parts/{hash}/head.json")
    }

    /// 大附件分片上传（断点续传）
    ///
    /// 1. 读 head.json：已有清单且 size/sha256 全一致 → 续传；
    ///    不一致（rekey 后密文不同，或上游异常）→ 删除旧分片目录重传
    /// 2. 逐片：HEAD 探测，已存在且 Content-Length 等于本片大小 → 跳过
    /// 3. 全部片就位后**最后**写 head.json——清单是「完整」信号，读侧
    ///    只在清单存在时拼装，中断留下的半成品目录不可读
    async fn upload_asset_parts(&self, hash: &str, encrypted: &[u8]) -> Result<(), SyncError> {
        let total = encrypted.len().div_ceil(Self::PARTS_SIZE);
        let head = AssetPartsHead {
            total,
            size: encrypted.len(),
            sha256: crate::crypto::sha256::sha256_hex(encrypted),
        };

        // 1. 既有清单检查：全字段一致 → 续传；否则清目录重传。
        //    半成品目录（无清单）也清理——防陈旧分片与新会话混片
        let head_path = Self::parts_head_path(hash);
        let reusable = match self.download(&head_path).await {
            Ok(bytes) => {
                let existing: serde_json::Result<AssetPartsHead> = serde_json::from_slice(&bytes);
                if existing.is_ok_and(|h| {
                    h.size == head.size && h.total == head.total && h.sha256 == head.sha256
                }) {
                    log::info!(
                        "[webdav parts] 续传模式：{hash} 已有匹配清单（{} 片）",
                        head.total
                    );
                    true
                } else {
                    log::info!("[webdav parts] 清单不匹配（rekey 或密文变化），清目录重传 {hash}");
                    false
                }
            }
            Err(e) if e.is_not_found() => false,
            Err(e) => return Err(e),
        };
        if !reusable {
            self.delete_parts_dir(hash).await;
        }

        // 2. 逐片上传：已存在且大小一致 → 跳过（断点续传核心）
        for index in 0..total {
            let start = index * Self::PARTS_SIZE;
            let end = std::cmp::min(start + Self::PARTS_SIZE, encrypted.len());
            let chunk = &encrypted[start..end];
            let part_path = Self::part_bin_path(hash, index);
            // 已存在且大小等于本片 → 跳过（确定性加密下大小相等即内容相等）
            if let Some(existing_len) = self.remote_file_size(&part_path).await?
                && existing_len == chunk.len() as u64
            {
                continue;
            }
            // 分片 PUT：长窗口单次 PUT（120s 总超时覆盖发送阶段——客户端
            // 默认 read_timeout 不覆盖 PUT 上行，慢速上行会被中途掐断）；
            // 外层业务级 with_retry 兜底整链路重试
            if let Some(parent) = part_path.rsplit_once('/').map(|(p, _)| p) {
                self.ensure_directory(parent).await?;
            }
            let url = self.build_url(&part_path);
            let headers = self.auth_headers();
            self.http
                .put_part_once(&url, headers, chunk.to_vec())
                .await?;
        }

        // 3. 最后写清单（「完整」信号）
        let head_json = serde_json::to_vec(&head).map_err(|e| SyncError::Network {
            message: format!("序列化分片清单失败: {e}"),
            retryable: false,
        })?;
        self.upload(&head_path, &head_json).await?;

        // 4. 删除旧单对象（rekey 对账）：rekey 重传场景旧 Key 密文仍在
        //    assets/{hash}.waitsync / assets/{hash}，读侧回退顺序
        //    （.waitsync → 裸 hash → 分片）会先命中旧密文解密失败——
        //    分片就位后必须清掉旧单对象。404（本就无旧对象，大附件
        //    首传走分片）忽略；其余失败透传（留旧对象 = 他端解密报错，
        //    不如本轮失败重试）
        for legacy in [format!("assets/{hash}.waitsync"), format!("assets/{hash}")] {
            if let Err(e) = self.delete(&legacy).await
                && !e.is_not_found()
            {
                return Err(e);
            }
        }
        Ok(())
    }

    /// 探测远端文件大小（HEAD），不存在返回 None
    async fn remote_file_size(&self, path: &str) -> Result<Option<u64>, SyncError> {
        let url = self.build_url(path);
        let headers = self.auth_headers();
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
        match SyncError::classify_head_status(response.status().as_u16())? {
            true => Ok(response
                .headers()
                .get(reqwest::header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())),
            false => Ok(None),
        }
    }

    /// 分片拼装下载：读 head.json → 逐片下载 → 拼接 + 大小/sha256 校验
    async fn download_asset_parts(&self, hash: &str) -> Result<Vec<u8>, SyncError> {
        let head_path = Self::parts_head_path(hash);
        let head_bytes = self.download(&head_path).await?;
        let head: AssetPartsHead =
            serde_json::from_slice(&head_bytes).map_err(|e| SyncError::Network {
                message: format!("解析分片清单失败: {e}"),
                retryable: false,
            })?;
        let mut assembled = Vec::with_capacity(head.size);
        for index in 0..head.total {
            let part_path = Self::part_bin_path(hash, index);
            let mut part = self.download(&part_path).await?;
            assembled.append(&mut part);
        }
        // 校验：清单声明的大小与整体 sha256 必须匹配（防分片目录被
        // 外部篡改/混入异源分片）
        if assembled.len() != head.size {
            return Err(SyncError::Network {
                message: format!(
                    "分片拼装大小不符：期望 {} 实际 {}（{hash}）",
                    head.size,
                    assembled.len()
                ),
                retryable: false,
            });
        }
        let actual = crate::crypto::sha256::sha256_hex(&assembled);
        if actual != head.sha256 {
            return Err(SyncError::Network {
                message: format!("分片拼装 sha256 校验失败（{hash}），疑似分片损坏或被篡改"),
                retryable: false,
            });
        }
        Ok(assembled)
    }

    /// 删除分片目录（尽力而为：逐片 DELETE + 清单 DELETE，失败仅日志）
    ///
    /// 分片按序上传（000000 起连续编号），按序删除直到首个 404 即尾后
    /// 停止；上限 10000 片防御异常目录。部分失败留孤儿分片无碍正确性
    /// （无 head.json 不可读、不参与 list_assets 差集不会拉回）。
    async fn delete_parts_dir(&self, hash: &str) {
        for index in 0..10_000 {
            let part_path = Self::part_bin_path(hash, index);
            match self.delete(&part_path).await {
                Ok(()) => {}
                Err(e) if e.is_not_found() => break,
                Err(e) => {
                    log::info!("[webdav parts] 删除分片失败（继续）: {e}");
                }
            }
        }
        if let Err(e) = self.delete(&Self::parts_head_path(hash)).await
            && !e.is_not_found()
        {
            log::info!("[webdav parts] 删除清单失败（继续）: {e}");
        }
    }

    /// 列出 assets_parts/ 下的一级子目录名（即分片附件的 hash 集合）
    ///
    /// 专用 PROPFIND：`list_all_files` 过滤目录条目（is_collection），
    /// 拿不到 {hash}/ 子目录。目录不存在（从未有分片附件）返回空。
    async fn list_parts_hashes(&self) -> Result<Vec<String>, SyncError> {
        let url = self.build_url("assets_parts/");
        let mut headers = self.auth_headers();
        headers.insert("Depth", "1".parse().unwrap());
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
        if status == 404 {
            return Ok(Vec::new());
        }
        if !response.status().is_success() && status != 207 {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status, &body));
        }
        let xml = response.text().await.map_err(|e| SyncError::Network {
            message: format!("读取 PROPFIND 响应失败: {e}"),
            retryable: false,
        })?;
        let entries = parse_propfind_response(&xml).map_err(|e| SyncError::Network {
            message: format!("解析 PROPFIND XML 失败: {e}"),
            retryable: false,
        })?;
        // 只取目录条目（{hash}/ 子目录）；assets_parts/ 自身（首条目，
        // href 与请求 URL 同路径）也会出现——用「目录且非根」过滤
        Ok(entries
            .into_iter()
            .filter(|e| e.is_collection && !e.href.is_empty())
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
            .filter(|name| !name.is_empty() && name != "assets_parts")
            .collect())
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
        // S11（2026-09-13 探查，基线 P1-1）：非 2xx 错误走统一状态码框架
        // from_http_status——此前手写 Network{retryable:false} 让 5xx 不可
        // 重试（与统一框架相反）、body 丢弃（限流标识不可识别）、401/403
        // 被归为 Network 误导排障方向。
        if !response.status().is_success() && status != 207 {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status, &body));
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
                // S19（2026-09-13 探查）：409 数字判断保留（from_http_status 的
                // 兜底分支将非 2xx/4xx 归 Network 且消息带 "HTTP 409" 状态码
                // 锚点——适配器对 GET 无法拿到原始 status，此嗅探有锚点、非
                // 裸子串），AncestorsNotFound 体特征一并校验防 409 其他语义
                // （如 MKCOL 冲突）误判。
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
        // S4：大密文走分片协议（assets_parts/{hash}/ 布局），小数据单 PUT。
        // 分派点在 upload 层而非 upload_asset：BasePathAdapter 的
        // upload_asset 直接转发 inner.upload，分派若只在 upload_asset
        // 会被包装器绕过。模块数据（几百 KB 级）不会触阈值，路径不含
        // assets/{hash}.waitsync 形态的常规上传零变化
        if data.len() >= Self::PARTS_THRESHOLD
            && let Some(hash) = asset_hash_from_path(path)
        {
            return self.upload_asset_parts(&hash, data).await;
        }
        // 先确保父目录存在,避免 409 AncestorsNotFound
        // (如 path = "sync/data/file.waitsync" → 创建 sync/data 目录)
        if let Some(parent) = path.rsplit_once('/').map(|(p, _)| p)
            && !parent.is_empty()
        {
            self.ensure_directory(parent).await?;
        }

        let url = self.build_url(path);
        let headers = self.auth_headers();
        let first = self
            .http
            .put_with_retry(&url, headers.clone(), data.to_vec())
            .await;

        // S29（2026-09-14 审查）：dir_cache 失效处理——云端目录被外部删除后，
        // 缓存仍认为目录存在（ensure_directory 直接跳过 MKCOL），PUT 持续 409
        // 直至进程重启。409（AncestorsNotFound，父目录缺失语义）时清空缓存、
        // 重建目录链后重试一次；非 409 错误原样透传。
        // 识别口径与 download 一致：from_http_status 兜底分支的消息带 "HTTP 409"
        // 状态码锚点 + AncestorsNotFound 体特征（适配器对 PUT 同样拿不到原始
        // status，此嗅探有状态码锚点，非裸子串）。
        match first {
            Err(e)
                if e.to_string().contains("HTTP 409")
                    && e.to_string().contains("AncestorsNotFound") =>
            {
                log::info!("[webdav] PUT 409 AncestorsNotFound：清空目录缓存并重建后重试 {path}");
                if let Ok(mut cache) = self.dir_cache.lock() {
                    cache.clear();
                }
                if let Some(parent) = path.rsplit_once('/').map(|(p, _)| p)
                    && !parent.is_empty()
                {
                    self.ensure_directory(parent).await?;
                }
                let headers = self.auth_headers();
                self.http.put_with_retry(&url, headers, data.to_vec()).await
            }
            other => other,
        }
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
                // S12：传输层失败是瞬态，标可重试（同 S3 侧口径）
                retryable: true,
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
        // 三段回退：.waitsync 单对象 → 裸 hash 旧命名 → assets_parts 分片拼装
        // （S4：大附件的分片形态）。前两者 404 后才查分片清单，清单存在
        // 即拼装（清单只在全部片就位后写入，半成品目录无清单不可读）
        let new_path = format!("assets/{hash}.waitsync");
        match self.download(&new_path).await {
            Ok(data) => Ok(data),
            Err(e) if e.is_not_found() => {
                let legacy_path = format!("assets/{hash}");
                match self.download(&legacy_path).await {
                    Ok(data) => Ok(data),
                    Err(e2) if e2.is_not_found() => self.download_asset_parts(hash).await,
                    Err(e2) => Err(e2),
                }
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
                retryable: true,
            })?;

        if SyncError::classify_head_status(result.status().as_u16())? {
            return Ok(true);
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
                retryable: true,
            })?;

        match SyncError::classify_head_status(result.status().as_u16())? {
            true => Ok(true),
            // S4：大附件的分片形态——单对象两路径都 404 后查分片清单。
            // 不查清单会误判「不存在」：push 差集每轮把分片附件当缺失
            // 空跑重传（幂等但浪费），首传探测三分叉也会误放行
            false => self
                .remote_file_size(&Self::parts_head_path(hash))
                .await
                .map(|s| s.is_some()),
        }
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
        // S11：非 2xx 错误走统一框架（同 list_all_files）
        if !response.status().is_success() && status != 207 {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status, &body));
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

        // S4：并集分片目录（assets_parts/{hash}/ 一级子目录名即 hash）——
        // 分片附件不在 assets/ 下，不并集会被 push 差集判缺失（每轮空跑
        // 重传）与 pull 活跃引用过滤漏拉。list_all_files 过滤目录条目
        // （is_collection），这里用专用 PROPFIND 取目录条目名
        for hash in self.list_parts_hashes().await? {
            if !hashes.contains(&hash) {
                hashes.push(hash);
            }
        }

        // S30：dedup 只去相邻重复，先排序保证同名（.waitsync 与裸 hash）全去
        hashes.sort();
        hashes.dedup();
        Ok(hashes)
    }
}

/// 从附件对象路径提取内容哈希（S4 分片分派用）
///
/// 识别 `assets/{hash}.waitsync`（新命名）与 `assets/{hash}`（旧命名）；
/// 其余路径（模块数据、crypto/config 等）返回 None——`upload` 的 S4
/// 分片分派只对附件大对象生效，模块数据零变化。
fn asset_hash_from_path(path: &str) -> Option<String> {
    let name = path.rsplit('/').next()?;
    let hash = name.strip_suffix(".waitsync").unwrap_or(name);
    if path.starts_with("assets/") && !hash.is_empty() {
        Some(hash.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ========================================================================
    // parent_url：MKCOL 409 递归建目录的父路径解析（纯函数）
    // ========================================================================

    #[test]
    fn parent_url_strips_last_segment() {
        assert_eq!(
            WebDavAdapter::parent_url("https://host/dav/myfolder/sync"),
            Some("https://host/dav/myfolder".to_string())
        );
    }

    #[test]
    fn parent_url_root_level_returns_host() {
        // 只剩一级路径 → 父目录是 host 根
        assert_eq!(
            WebDavAdapter::parent_url("https://host/dav"),
            Some("https://host".to_string())
        );
    }

    #[test]
    fn parent_url_host_only_returns_none() {
        // 已到 host 根，无法再向上
        assert_eq!(WebDavAdapter::parent_url("https://host"), None);
    }

    #[test]
    fn parent_url_ignores_query_and_fragment() {
        assert_eq!(
            WebDavAdapter::parent_url("https://host/a/b?x=1#frag"),
            Some("https://host/a".to_string())
        );
    }

    #[test]
    fn parent_url_trims_trailing_slash_first() {
        // 尾斜杠先剥再取父级，不得取到空段
        assert_eq!(
            WebDavAdapter::parent_url("https://host/a/b/"),
            Some("https://host/a".to_string())
        );
    }

    // ========================================================================
    // S29：dir_cache 失效——PUT 409 AncestorsNotFound 时清缓存重建
    //
    // 端到端验证需真实 WebDAV 服务器（m4 集成测试职责，本机无环境为已知
    // 边界）；此处覆盖其依赖的父路径解析纯函数，重试编排逻辑由 m4 与
    // 既有 upload 路径回归。
    // ========================================================================
}

// ====================================================================
// S4 WebDAV 分片协议纯函数（2026-09-14）
//
// 端到端分片上传/拼装需真实 WebDAV 服务器（m4 集成测试职责，本机
// 无环境为已知边界）；此处覆盖分派判定的全部路径形态与清单结构。
// ====================================================================

#[test]
fn asset_hash_from_path_new_naming() {
    assert_eq!(
        asset_hash_from_path("assets/abc123.waitsync").as_deref(),
        Some("abc123")
    );
}

#[test]
fn asset_hash_from_path_legacy_naming() {
    assert_eq!(
        asset_hash_from_path("assets/abc123").as_deref(),
        Some("abc123")
    );
}

#[test]
fn asset_hash_from_path_rejects_non_asset() {
    // 模块数据路径（同名文件在 modules/ 下）不得误判为附件
    assert!(asset_hash_from_path("modules/todos/data.waitsync").is_none());
    assert!(asset_hash_from_path("crypto/config").is_none());
    assert!(asset_hash_from_path("_meta.waitsync").is_none());
    // 带 base_path 的完整形态：assets/ 必须是路径段而非前缀子串
    assert!(asset_hash_from_path("wait/assets/abc.waitsync").is_none());
}

#[test]
fn asset_hash_from_path_rejects_empty_hash() {
    assert!(asset_hash_from_path("assets/.waitsync").is_none());
}

#[test]
fn part_paths_are_derived_correctly() {
    assert_eq!(
        WebDavAdapter::part_bin_path("abc", 0),
        "assets_parts/abc/000000.bin"
    );
    assert_eq!(
        WebDavAdapter::part_bin_path("abc", 42),
        "assets_parts/abc/000042.bin"
    );
    assert_eq!(
        WebDavAdapter::parts_head_path("abc"),
        "assets_parts/abc/head.json"
    );
}

#[test]
fn parts_head_serializes_to_plain_json() {
    let head = AssetPartsHead {
        total: 3,
        size: 12_000_000,
        sha256: "deadbeef".to_string(),
    };
    let json = serde_json::to_string(&head).unwrap();
    let parsed: AssetPartsHead = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.total, 3);
    assert_eq!(parsed.size, 12_000_000);
    assert_eq!(parsed.sha256, "deadbeef");
    // 明文字段可断言：清单不含任何密钥材料
    assert!(json.contains("deadbeef"));
    assert!(!json.contains("key"));
}

/// 分片数学：8MiB 阈值 = 1×5MiB + 3MiB 尾片；12MiB = 2×5MiB + 2MiB
#[test]
fn parts_chunking_math() {
    let ps = WebDavAdapter::PARTS_SIZE;
    for (total_bytes, expect_parts) in [
        (WebDavAdapter::PARTS_THRESHOLD, 2), // 8MiB → 5+3
        (ps, 1),                             // 恰一片
        (ps + 1, 2),                         // 片+1 字节 → 尾片 1 字节
        (ps * 2, 2),                         // 恰两片
    ] {
        assert_eq!(
            total_bytes.div_ceil(ps),
            expect_parts,
            "{total_bytes} 字节应分 {expect_parts} 片"
        );
    }
}
