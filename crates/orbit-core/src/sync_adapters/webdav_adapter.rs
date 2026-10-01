use std::collections::HashSet;
use std::sync::Mutex;

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderMap};

use crate::sync::error::{SyncError, transport_message};
use crate::sync_adapters::http_client::HttpClient;
use crate::sync_adapters::traits::{RemoteFile, SyncAdapter, UploadOutcome, UploadPrecondition};
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
    ///
    /// ## 路径必须百分号编码（F61，2026-09-30 第六轮）
    ///
    /// 此前 `path` 裸拼进 URL 字符串，交给 reqwest 解析。两个后果：
    ///
    /// 1. **`#` / `?` 截断**：`base_path` 或对象名含这两个字符时，URL 在它们处
    ///    截断（`#` 之后成为 fragment，`?` 之后成为 query）→ 请求打到**另一个
    ///    路径**上，且 status 看着「正常」（读到 404 或别人的对象）；
    /// 2. **空格 / 非 ASCII 依赖 reqwest 的隐式编码**：服务端按 RFC 3986 解码，
    ///    但不同实现（坚果云、Nextcloud、自建）对未编码字符的容忍度不同。
    ///
    /// 编码走 `sync_adapters::uri_encode`（与 S3 同一实现，保留 `/` 作分隔符）。
    /// 调用方一律传**原始未编码**路径——自编码会被二次编码成 `%2520`。
    fn build_url(&self, path: &str) -> String {
        let trimmed = self.config.server_url.trim();
        let base = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
            trimmed.trim_end_matches('/').to_string()
        } else {
            format!("https://{}", trimmed)
                .trim_end_matches('/')
                .to_string()
        };
        let encoded = crate::sync_adapters::uri_encode(path, false);
        if encoded.starts_with('/') {
            format!("{}{}", base, encoded)
        } else {
            format!("{}/{}", base, encoded)
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
                // F67（2026-09-30 第六轮）：F34 脱敏漏挂的最后一处 arm——
                // 此处曾直接内插原始 URL，会把内嵌的 user:password 写进错误串
                // （错误串一路进日志与 UI），与同函数下方两处口径不一致。
                message: format!(
                    "MKCOL 递归创建目录深度超限(>10): {}",
                    crate::sync::error::redact_userinfo(url)
                ),
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
                message: transport_message("MKCOL 请求", &e),
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
                                    "无法创建云端目录「{}」: 父目录已存在但服务器拒绝创建(409)。\
                                     可能原因:目录名含非法字符、权限不足、或服务器限制。\
                                     服务器响应: {}",
                                    crate::sync::error::redact_userinfo(url),
                                    crate::sync::error::brief(&body)
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
                                "无法创建云端目录「{}」: 服务器返回 409 AncestorsNotFound,\
                                 且已到达根目录仍无法创建。请检查 endpoint 是否指向有效的 WebDAV 路径。\
                                 服务器响应: {}",
                                crate::sync::error::redact_userinfo(url),
                                crate::sync::error::brief(&body)
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
                        message: format!(
                            "MKCOL 创建目录失败: HTTP {status}: {}",
                            crate::sync::error::brief(&body)
                        ),
                        retryable: true,
                    })
                }
            }
            _ => {
                let body = response.text().await.unwrap_or_default();
                Err(SyncError::Network {
                    message: format!(
                        "MKCOL 创建目录失败: HTTP {status}: {}",
                        crate::sync::error::brief(&body)
                    ),
                    retryable: false,
                })
            }
        }
    }

    /// 检查指定 URL 的资源是否存在(PROPFIND Depth:0)
    ///
    /// 用于 MKCOL 返回 409 时区分"父目录不存在"和"目录已存在"等场景,
    /// 避免盲目递归导致死循环。
    ///
    /// F31：207 不再恒等于「存在」——按 RFC 4918，服务器对**不存在**的资源
    /// 同样回 207 + 条目级 404（Nextcloud/坚果云均如此）。历史实现在 207 上
    /// 直接返回 true，于是 MKCOL 409 时「父目录其实不存在」被误判成「目录已
    /// 存在」，跳过递归创建，后续 PUT 继续 409。现按解析后的条目判定：
    /// multistatus 里有存活条目（至少一个 2xx propstat）才算存在。
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
                message: transport_message("PROPFIND 验证请求", &e),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        if status == 404 {
            return Ok(false);
        }
        if !response.status().is_success() && status != 207 {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncError::from_http_status(status, &body));
        }
        let xml = response.text().await.map_err(|e| SyncError::Network {
            message: transport_message("读取 PROPFIND 验证响应", &e),
            retryable: false,
        })?;
        let entries = parse_propfind_response(&xml).map_err(|e| SyncError::Network {
            message: format!("解析 PROPFIND XML 失败: {e}"),
            retryable: false,
        })?;
        Ok(!entries.is_empty())
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
    // WebDAV 无 multipart 标准协议，自造分片布局（云端）。分片根目录与单对象
    // 同前缀（F23）：`assets_dir` 的末段 `assets` 换成 `assets_parts`，故
    // base_path 下的同步走 `{base_path}/assets_parts/…`，不会写到分享根目录外：
    //   …/assets_parts/{hash}/head.json      # 明文清单（无密钥材料）
    //   …/assets_parts/{hash}/000000.bin …  # 密文分片
    //
    // head.json 字段：total（分片数）/ size（密文字节数）/ sha256（密文
    // 整体哈希）。跨密钥防混片由 sha256 天然承担：确定性加密（6a711d6）
    // 的 nonce 派生含 data_key——不同 Data Key 加密同一附件产出不同密文
    // → sha256 不同 → 续传判定失败 → 清目录重传。无需独立的 key 指纹
    // 字段，适配器也不必持有 crypto。
    //
    // 断点续传：上传前 HEAD 探测已存在的分片，大小等于本片期望大小才跳过。
    // **跳过只在清单已证明目录同源时启用**（F59）：清单的 size/total/sha256
    // 全等于本轮密文 ⇒ 目录内是本轮同一份密文 ⇒ 大小相等即内容相等。清理过的
    // 目录（清单不匹配或缺失）内容不可信，一律覆盖重传——否则 rekey 后的陈旧
    // 分片（同明文跨 Data Key 的密文长度必然相同）会被整片跳过，写出内容与
    // 清单不自洽的「完整」对象。
    // ================================================================

    /// 分片触发阈值（密文 ≥ 8MiB）与片大小（5MiB）——与 S3 侧同口径
    const PARTS_THRESHOLD: usize = 8 * 1024 * 1024;
    const PARTS_SIZE: usize = 5 * 1024 * 1024;

    /// 分片路径：`{parts_root}/{hash}/{index:06}.bin`
    ///
    /// `parts_root` 由入站对象路径推导（`asset_parts_target`），因此生产链路
    /// 带 base_path 前缀时分片同样落在 `{base_path}/assets_parts` 内（F23）。
    fn part_bin_path(parts_root: &str, hash: &str, index: usize) -> String {
        format!("{parts_root}/{hash}/{index:06}.bin")
    }

    /// 清单路径：`{parts_root}/{hash}/head.json`
    fn parts_head_path(parts_root: &str, hash: &str) -> String {
        format!("{parts_root}/{hash}/head.json")
    }

    /// 大附件分片上传（断点续传）
    ///
    /// `asset_path` 为触发本路径的单对象路径（可能带 base_path 前缀），
    /// `parts_root` 由它推导——二者都必须透传，缺前缀即把分片写到 base_path 之外。
    ///
    /// 1. 读 head.json：已有清单且 size/sha256 全一致 → 续传；
    ///    不一致（rekey 后密文不同，或上游异常）→ **先删清单再**清分片目录，
    ///    清理失败即本轮失败（F59：清理不可靠时继续上传会产出内容不自洽的对象）
    /// 2. 逐片：**仅续传模式下** HEAD 探测跳过（Content-Length 等于本片大小）；
    ///    清理过的目录一律覆盖重传（F59）
    /// 3. 全部片就位后**最后**写 head.json——清单是「完整」信号，读侧
    ///    只在清单存在时拼装，中断留下的半成品目录不可读
    async fn upload_asset_parts(
        &self,
        hash: &str,
        parts_root: &str,
        asset_path: &str,
        encrypted: &[u8],
    ) -> Result<(), SyncError> {
        let total = encrypted.len().div_ceil(Self::PARTS_SIZE);
        let head = AssetPartsHead {
            total,
            size: encrypted.len(),
            sha256: crate::crypto::sha256::sha256_hex(encrypted),
        };

        // 1. 既有清单检查：全字段一致 → 续传；否则清目录重传。
        //    半成品目录（无清单）也清理——防陈旧分片与新会话混片
        let head_path = Self::parts_head_path(parts_root, hash);
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
            // F59：清单不匹配 ⇒ 目录内容不可信，必须清干净才能继续——清理失败
            // 直接上抛（外层重试），不再「尽力而为」。旧实现把失败仅记日志，随后
            // 逐片按 size 跳过 stale 分片，最终写出声明本轮密文的 head.json、目录里
            // 却是旧密文 → 读侧拼装 sha256 校验失败（retryable=false）→ 对象永久
            // 不可读，每轮重试都被同一判据拒掉
            self.delete_parts_dir(hash, parts_root).await?;
        }

        // 2. 逐片上传：已存在且大小一致 → 跳过（断点续传核心）
        for index in 0..total {
            let start = index * Self::PARTS_SIZE;
            let end = std::cmp::min(start + Self::PARTS_SIZE, encrypted.len());
            let chunk = &encrypted[start..end];
            let part_path = Self::part_bin_path(parts_root, hash, index);
            // F59：跳过的前提是「目录已被清单证明与本轮密文同源」（reusable）——
            // 确定性加密下同一密文的同片字节必然一致，大小相等才是内容相等的
            // 可靠代理；清理过/新建的目录内容不可信，必须覆盖重传
            if reusable
                && let Some(existing_len) = self.remote_file_size(&part_path).await?
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

        // 4. 删除旧单对象（rekey 对账）：分片就位后清掉同名单对象——
        //    读侧优先命中单对象，残留旧 Key 密文会导致他端解密失败。
        //    404（本就无旧对象，大附件首传走分片）忽略；其余失败透传
        //    （留旧对象 = 他端解密报错，不如本轮失败重试）
        if let Err(e) = self.delete(asset_path).await
            && !e.is_not_found()
        {
            return Err(e);
        }
        Ok(())
    }

    /// 轻量存在性探测（HEAD），**只看状态码，不看 `Content-Length`**
    ///
    /// F57（2026-09-30 第六轮）：`exists` 此前直接复用 `remote_file_size`，
    /// 而后者在缺 `Content-Length` 时返回 `None`（部分实现对 HEAD 不回该头，
    /// 或用 `Transfer-Encoding: chunked`）→ 存在的对象被判「不存在」。后果不是
    /// 报错而是**静默走错分支**：附件差集每轮空跑重传、S7 空列表防御的首传三分叉
    /// 探测误放行、pull 的活跃引用判定失真。
    async fn remote_exists(&self, path: &str) -> Result<bool, SyncError> {
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
                message: transport_message("HEAD 请求", &e),
                retryable: true,
            })?;
        SyncError::classify_head_status(response.status().as_u16())
    }

    /// 探测远端文件大小（HEAD）
    ///
    /// `Ok(None)` 有两种成因，调用方必须自己判断能否接受：**对象不存在**，或
    /// **对象存在但服务端未回 `Content-Length`**。判存在请用 `remote_exists`。
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
                message: transport_message("HEAD 请求", &e),
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

    /// 单个对象的 GET（不含分片回退）
    ///
    /// F32：坚果云在父目录不存在时对 GET 返回 409 AncestorsNotFound，
    /// `from_http_status` 现按状态码产出 `AncestorsNotFound` 变体、
    /// `is_not_found()` 已含该变体——调用方（`download` 的分片回退、
    /// 清单探测）按类型判定即可，不再需要在此按消息子串改写为 NotFound。
    async fn download_object(&self, path: &str) -> Result<Vec<u8>, SyncError> {
        let url = self.build_url(path);
        let headers = self.auth_headers();
        self.http.get_with_retry(&url, headers).await
    }

    /// 分片拼装下载：读 head.json → 逐片下载 → 拼接 + 大小/sha256 校验
    async fn download_asset_parts(
        &self,
        hash: &str,
        parts_root: &str,
    ) -> Result<Vec<u8>, SyncError> {
        let head_path = Self::parts_head_path(parts_root, hash);
        let head_bytes = self.download(&head_path).await?;
        let head: AssetPartsHead =
            serde_json::from_slice(&head_bytes).map_err(|e| SyncError::Network {
                message: format!("解析分片清单失败: {e}"),
                retryable: false,
            })?;
        // 不用 with_capacity(head.size)：head.json 是明文清单，size 由服务端
        // 提供，预分配会把「篡改一个数字」放大成本地分配风暴；拼装后与
        // head.size 不符本来就会被下面的校验拒掉
        let mut assembled = Vec::new();
        for index in 0..head.total {
            let part_path = Self::part_bin_path(parts_root, hash, index);
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

    /// 删除分片目录——**先删清单，再由分片尽力而为**
    ///
    /// F59（2026-09-30 第六轮）：原实现「逐片 DELETE 后删清单、失败仅记日志」让清理
    /// 变成不可靠操作，而调用方（`upload_asset_parts` 的清单不匹配分支）依赖「清理后
    /// 目录内容不再被当成同源」这一前提。现在把顺序倒过来并分级上报：
    ///
    /// 1. **先删 head.json**（读侧只在清单存在时拼装）——清单消失即目录立刻不可读，
    ///    残留分片退化成无害孤儿；删除失败（非 404）返回 `Err` 由外层重试。顺序
    ///    不可颠倒：先删片后删清单时，任一片删除失败都会让「不匹配的清单 + 陈旧
    ///    分片」组合继续存活，读侧持续走到拼装 sha256 校验失败。
    /// 2. 分片按序删除（000000 起连续编号），首个 404 即尾后停止，上限 10000 片防御
    ///    异常目录；此处失败仍仅记日志——孤儿分片无清单不可读，也不参与 `list_assets`
    ///    差集（不会被拉回），且清单已删 ⇒ 下一轮必走覆盖重传。
    async fn delete_parts_dir(&self, hash: &str, parts_root: &str) -> Result<(), SyncError> {
        if let Err(e) = self.delete(&Self::parts_head_path(parts_root, hash)).await
            && !e.is_not_found()
        {
            log::warn!("[webdav parts] 删除分片清单失败（清理未完成，本轮判失败）: {e}");
            return Err(e);
        }
        for index in 0..10_000 {
            let part_path = Self::part_bin_path(parts_root, hash, index);
            match self.delete(&part_path).await {
                Ok(()) => {}
                Err(e) if e.is_not_found() => break,
                Err(e) => {
                    log::info!("[webdav parts] 删除分片失败（继续）: {e}");
                }
            }
        }
        Ok(())
    }

    /// 列出 `{parts_root}/` 下的一级子目录名（即分片附件的 hash 集合）
    ///
    /// 专用 PROPFIND：`list_all_files` 过滤目录条目（is_collection），
    /// 拿不到 {hash}/ 子目录。目录不存在（从未有分片附件）返回空。
    async fn list_parts_hashes(&self, parts_root: &str) -> Result<Vec<String>, SyncError> {
        let url = self.build_url(&format!("{parts_root}/"));
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
                message: transport_message("PROPFIND 请求", &e),
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
            message: transport_message("读取 PROPFIND 响应", &e),
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
    async fn list_all_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        let url = self.build_url(base_path);

        let mut headers = self.auth_headers();
        headers.insert("Depth", "1".parse().unwrap());
        headers.insert("Content-Type", "application/xml".parse().unwrap());

        // 请求 resourcetype 以识别目录条目（RFC 4918 标准）：目录若不被过滤，
        // 其尾斜杠 href 会使 basename 提取退化为整条 URL 混入文件列表，
        // 污染 cloud_has_module_data 探测与附件 diff（见 07 排查报告 P0-1）。
        // F26：getetag 一并申请——不申请则服务端不回，列举侧永远拿不到并发令牌。
        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getetag/>
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
                message: transport_message("PROPFIND 请求", &e),
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
            message: transport_message("读取 PROPFIND 响应", &e),
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
                    etag: e.etag,
                }
            })
            .collect();

        Ok(files)
    }

    /// 下载：单对象 404 且路径是附件对象 → 回退分片拼装（S4 + F23）
    ///
    /// 回退必须挂在**路径级** `download` 上：生产链路全经 `BasePathAdapter`，
    /// 它只调 `inner.download(join(asset_path))`，挂在 `download_asset` 里的
    /// 两段回退在真机上不可达（大附件读侧必 404）。
    async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError> {
        match self.download_object(path).await {
            Ok(data) => Ok(data),
            Err(e) if e.is_not_found() => match asset_parts_target(path) {
                Some((hash, parts_root)) => self.download_asset_parts(&hash, &parts_root).await,
                None => Err(e),
            },
            Err(e) => Err(e),
        }
    }

    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
        // S4：大密文走分片协议（assets_parts/{hash}/ 布局），小数据单 PUT。
        // 分派点在 upload 层而非 upload_asset：BasePathAdapter 的
        // upload_asset 直接转发 inner.upload，分派若只在 upload_asset
        // 会被包装器绕过。模块数据（几百 KB 级）不会触阈值，路径不含
        // assets/{hash}.orsync 形态的常规上传零变化
        //
        // F23：判定改按「上一段目录名 == assets」（`asset_parts_target`），
        // 旧判定 `path.starts_with("assets/")` 在生产链路恒 false——所有路径
        // 都被包装器拼上了 base_path 前缀，S4 分片协议自落地起从未执行过，
        // 大附件静默退化成单 PUT（慢速上行必超时）。同时 parts_root 随路径
        // 推导，分片与单对象同处 {base_path} 命名空间内。
        if data.len() >= Self::PARTS_THRESHOLD
            && let Some((hash, parts_root)) = asset_parts_target(path)
        {
            return self
                .upload_asset_parts(&hash, &parts_root, path, data)
                .await;
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
        // 重建目录链后重试一次；其余错误原样透传。
        // F32：判定改按 `AncestorsNotFound` 变体（`from_http_status` 按状态码
        // 构造），不再嗅探消息子串——嗅探会被 F34 的响应体截断打掉。
        match first {
            Err(e) if matches!(e, SyncError::AncestorsNotFound { .. }) => {
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
                message: transport_message("DELETE 请求", &e),
                // S12：传输层失败是瞬态，标可重试（同 S3 侧口径）
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
        // 两段回退（单对象 → 分片拼装）已上移到 `download`（F23），此处只拼路径
        self.download(&crate::cloud_sync::paths::asset_path(hash))
            .await
    }

    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError> {
        // 分片感知探测已上移到 `exists`（F23）
        self.exists(&crate::cloud_sync::paths::asset_path(hash))
            .await
    }

    async fn list_assets(&self, assets_dir: &str) -> Result<Vec<String>, SyncError> {
        let url = self.build_url(&format!("{assets_dir}/"));

        let mut headers = self.auth_headers();
        headers.insert("Depth", "1".parse().unwrap());
        headers.insert("Content-Type", "application/xml".parse().unwrap());

        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getetag/>
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
                message: transport_message("PROPFIND 请求", &e),
                retryable: true,
            })?;

        let status = response.status().as_u16();
        // 404 = 目录不存在（首次使用时 assets 尚未创建），视为空列表。
        // 但不得提前 return：大附件只落在 assets_parts/ 下，此时 assets/ 恒 404，
        // 提前返回会让下面的分片并集永远跑不到——push 侧 S7 空列表防御误报
        // 「疑似列举异常」并跳过上传，pull 侧则永远不下载已存在的大附件（F23 补充）。
        let entries = if status == 404 {
            Vec::new()
        } else {
            // S11：非 2xx 错误走统一框架（同 list_all_files）
            if !response.status().is_success() && status != 207 {
                let body = response.text().await.unwrap_or_default();
                return Err(SyncError::from_http_status(status, &body));
            }

            let xml = response.text().await.map_err(|e| SyncError::Network {
                message: transport_message("读取 PROPFIND 响应", &e),
                retryable: false,
            })?;

            parse_propfind_response(&xml).map_err(|e| SyncError::Network {
                message: format!("解析 PROPFIND XML 失败: {e}"),
                retryable: false,
            })?
        };

        // 提取 hash：跳过目录本身（is_collection），从 display_name 或 href 提取文件名。
        // href 先剥尾斜杠（目录条目防御：rsplit 对尾斜杠取到空串）。
        // 默认文件名为 {hash}.orsync，需剥离同步后缀以保持接口契约。
        // 遗留 {hash}.waitsync / 裸 {hash} 同口径剥离。去重后返回。
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
            .map(|name| crate::cloud_sync::paths::strip_sync_extension(&name).to_string())
            .collect();

        // S4：并集分片目录（{parts_root}/{hash}/ 一级子目录名即 hash）——
        // 分片附件不在 assets/ 下，不并集会被 push 差集判缺失（每轮空跑
        // 重传）与 pull 活跃引用过滤漏拉，GC 也永远看不见它们（云端孤儿
        // 永不清理）。parts_root 与 assets_dir 同前缀（F23）。
        // list_all_files 过滤目录条目（is_collection），这里用专用 PROPFIND 取目录条目名
        for hash in self
            .list_parts_hashes(&parts_root_for_assets_dir(assets_dir))
            .await?
        {
            if !hashes.contains(&hash) {
                hashes.push(hash);
            }
        }

        // S30：dedup 只去相邻重复，先排序保证同名（多后缀并存）全去
        hashes.sort();
        hashes.dedup();
        Ok(hashes)
    }

    // ========================================================================
    // 轻量探测 / 并发令牌 / 条件写
    // ========================================================================

    /// HEAD 存在性探测（不再为判断存在而下载整个对象）
    ///
    /// 附件对象还要探分片清单：大附件只有 `assets_parts/{hash}/head.json`，
    /// 单对象恒 404。漏这一腿即「大附件被判定不存在」——push 差集每轮空跑
    /// 重传、S7 空列表防御的首传三分叉探测误放行、pull 的活跃引用判定失真。
    ///
    /// F57（2026-09-30 第六轮）：判据由「拿得到 `Content-Length`」改为
    /// **「HEAD 返回 2xx」**（走 `remote_exists`）——部分实现对 HEAD 不回
    /// `Content-Length`，旧判据会把存在的对象整片判成不存在。
    async fn exists(&self, path: &str) -> Result<bool, SyncError> {
        if self.remote_exists(path).await? {
            return Ok(true);
        }
        match asset_parts_target(path) {
            Some((hash, parts_root)) => {
                self.remote_exists(&Self::parts_head_path(&parts_root, &hash))
                    .await
            }
            None => Ok(false),
        }
    }

    /// 读取对象与并发令牌（WebDAV 回 ETag；不提供的服务端返回 None）
    async fn download_with_token(
        &self,
        path: &str,
    ) -> Result<Option<(Vec<u8>, Option<String>)>, SyncError> {
        let url = self.build_url(path);
        let headers = self.auth_headers();
        match self.http.get_with_token(&url, headers).await {
            Ok((bytes, token)) => Ok(Some((bytes, token))),
            // 404 与坚果云 409（父目录缺失，语义等同「这条路径没有对象」）
            // 都归「不存在」：F32 起由 `is_not_found()` 按变体判定
            Err(e) if e.is_not_found() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// 条件 PUT（WebDAV 用 If-Match / If-None-Match: *）
    ///
    /// 部分实现忽略条件头并返回 2xx——调用方以「写后回读校验」兜底
    /// （见 `cloud_sync::push` 的清单 CAS）。
    ///
    /// ## 先补齐父目录（F56，2026-10-01 第六轮）
    ///
    /// 此前本方法**不做** `ensure_directory`，而普通 `upload` 做。于是只要
    /// 父目录链不存在，条件写就必然失败且**错误成因被掩盖**：
    ///
    /// 1. 服务端回 409（RFC 4918 AncestorsNotFound）；
    /// 2. `put_conditional` 把「带前置条件的 409」折成 `Ok(false)`（那是为
    ///    兼容「用 409 表示 If-Match 失败」的少数实现而设的分支）；
    /// 3. 调用方（清单 CAS）据此判定「并发冲突」→ 重读清单 → 再重试；
    /// 4. 目录依旧不存在 → 再 409 → 重试耗尽后报**「并发冲突重试 N 次仍未
    ///    成功」**，而真实成因是目录缺失（可自愈），清单永不落盘。
    ///
    /// 触发面（不止首次推送）：云端目录被外部删除、用户在网盘控制台清空过
    /// 目录、只跑清单 CAS 而未先写过模块数据的路径（pull 前探测、rekey 强制
    /// 重推）。补齐父目录后 409 在本链路上只剩「CAS 失败」一种含义。
    async fn upload_conditional(
        &self,
        path: &str,
        data: &[u8],
        precondition: UploadPrecondition,
    ) -> Result<UploadOutcome, SyncError> {
        // 与 `upload` 同口径：先确保父目录存在，避免 409 AncestorsNotFound
        if let Some(parent) = path.rsplit_once('/').map(|(p, _)| p)
            && !parent.is_empty()
        {
            self.ensure_directory(parent).await?;
        }

        let url = self.build_url(path);
        let headers = self.auth_headers();
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

/// 由附件目录推导分片根目录：末段 `assets` → `assets_parts`
///
/// 入站目录形如 `assets` / `{base_path}/assets`，产出 `assets_parts` /
/// `{base_path}/assets_parts`（F23：前缀必须随路径一起走，否则分片落到
/// 分享根目录之外，列举侧看不见 → 每轮重传 + 云端孤儿永不清理）。
fn parts_root_for_assets_dir(assets_dir: &str) -> String {
    assets_dir.strip_suffix("/assets").map_or_else(
        || "assets_parts".to_string(),
        |head| format!("{head}/assets_parts"),
    )
}

/// 从对象路径识别「附件对象」，返回 (裸 hash, 该附件的分片根目录)
///
/// 附件对象 = 父目录名为 `assets` 的路径，识别 `assets/{hash}.orsync`（默认）
/// 与 `assets/{hash}.waitsync` / `assets/{hash}`（遗留），base_path 前缀任意深度
/// 皆可（`{base}/assets/{hash}.orsync`）。其余路径（模块数据、分片自身、
/// crypto/config 等）返回 None——S4 分片分派只对附件大对象生效，模块数据零变化。
fn asset_parts_target(path: &str) -> Option<(String, String)> {
    let (dir, name) = path.rsplit_once('/')?;
    if dir.rsplit('/').next()? != "assets" {
        return None;
    }
    let hash = crate::cloud_sync::paths::strip_sync_extension(name);
    if hash.is_empty() {
        return None;
    }
    Some((hash.to_string(), parts_root_for_assets_dir(dir)))
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
    // F61（2026-09-30 第六轮）：build_url 必须对路径做百分号编码
    //
    // 编码口径与 S3 共用同一实现（`sync_adapters::uri_encode`），此处验证接线。
    // ========================================================================

    fn adapter_for(server_url: &str) -> WebDavAdapter {
        WebDavAdapter::new(WebDavConfig {
            server_url: server_url.to_string(),
            username: "u".to_string(),
            password: "p".to_string(),
            timeout_secs: 30,
            skip_tls_verify: false,
        })
        .expect("构造 WebDAV 适配器")
    }

    /// `#` / `?` 必须编码：否则 URL 在此截断成 fragment / query，请求会打到
    /// **另一个路径**上，且状态码看着正常（读到 404 或别人的对象）。
    #[test]
    fn build_url_encodes_fragment_and_query_chars() {
        let a = adapter_for("https://dav.example.com/dav");
        assert_eq!(
            a.build_url("sync/user#1/a?b.orsync"),
            "https://dav.example.com/dav/sync/user%231/a%3Fb.orsync"
        );
    }

    /// 空格、`+` 与非 ASCII 一并编码（不同 WebDAV 实现对未编码字符的容忍度不同）
    #[test]
    fn build_url_encodes_space_plus_and_cjk() {
        let a = adapter_for("https://dav.example.com/dav");
        assert_eq!(
            a.build_url("wait sync/a+b/清单.orsync"),
            "https://dav.example.com/dav/wait%20sync/a%2Bb/%E6%B8%85%E5%8D%95.orsync"
        );
    }

    /// 反向：安全字符、`/` 与尾斜杠必须原样通过（paths 模块生成的路径不得被改动）
    #[test]
    fn build_url_leaves_safe_paths_untouched() {
        let a = adapter_for("https://dav.example.com/dav/");
        assert_eq!(
            a.build_url("assets_parts/0abc-def/"),
            "https://dav.example.com/dav/assets_parts/0abc-def/"
        );
        assert_eq!(
            a.build_url("modules/todo/data.orsync"),
            "https://dav.example.com/dav/modules/todo/data.orsync"
        );
    }

    /// S2 口径不得回退：无 scheme 输入补 https://、尾斜杠不产生 `//`
    #[test]
    fn build_url_scheme_and_slash_normalization_unchanged() {
        let a = adapter_for("dav.example.com/dav");
        assert_eq!(
            a.build_url("manifest.orsync"),
            "https://dav.example.com/dav/manifest.orsync"
        );
        // 前导 `/` 只补一个分隔符，不吞掉 server_url 的路径部分
        let a = adapter_for("https://dav.example.com/dav");
        assert_eq!(
            a.build_url("/leading"),
            "https://dav.example.com/dav/leading"
        );
    }

    // ========================================================================
    // S29：dir_cache 失效——PUT 409 AncestorsNotFound 时清缓存重建
    //
    // 端到端验证需真实 WebDAV 服务器（m4 集成测试职责，本机无环境为已知
    // 边界）；此处覆盖其依赖的父路径解析纯函数，重试编排逻辑由 m4 与
    // 既有 upload 路径回归。
    // ========================================================================

    // ========================================================================
    // F59（2026-09-30 第六轮）：分片目录清理的可靠性
    //
    // 为什么落在这里而不是 `tests/sync_fault_matrix.rs` 的集成级用例：附件 push
    // 会**先查云端已有附件**（`list_assets` 能看见分片目录，F23）→「云端预置
    // stale 分片目录」的场景被判成「云端已存在」而跳过上传，根本走不到清理
    // 路径（实测两个集成用例都因之假绿）。这里用最小内存 WebDAV 直接驱动
    // `upload_asset_parts`，绕开上层差集判定。
    // ========================================================================

    /// 最小内存 WebDAV：只实现分片协议用到的动词
    ///
    /// - PROPFIND 恒 404（目录「不存在」）→ `ensure_directory` 走 MKCOL(201)
    ///   （405 会让 `url_exists` 返回 Err，故必须回 404）
    /// - 对象存在性只按内存表判定；HEAD 回正确的 `Content-Length` 且**无体**
    /// - `fail_delete_ending` 命中后缀的 DELETE 回 500（F59 故障注入点）
    /// - `dirs` 记录 MKCOL 创建过的目录；**路径以 `/strict/` 开头时** PUT 要求
    ///   父目录已在 `dirs` 里，否则回 409 AncestorsNotFound（F56 故障注入点，
    ///   与 `/nolength/` 同一套路径前缀注入手法，不影响其余用例）
    struct FakeDav {
        base_url: String,
        objects: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>>,
        fail_delete_suffix: std::sync::Arc<std::sync::Mutex<Option<String>>>,
        dirs: std::sync::Arc<std::sync::Mutex<std::collections::HashSet<String>>>,
    }

    impl FakeDav {
        fn spawn() -> Self {
            use std::collections::{HashMap, HashSet};
            use std::sync::{Arc, Mutex};

            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("绑定空闲端口");
            let port = listener.local_addr().unwrap().port();
            let objects: Arc<Mutex<HashMap<String, Vec<u8>>>> =
                Arc::new(Mutex::new(HashMap::new()));
            let fail = Arc::new(Mutex::new(None::<String>));
            let dirs: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
            let (objs, fl, dr) = (objects.clone(), fail.clone(), dirs.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let (objs, fl, dr) = (objs.clone(), fl.clone(), dr.clone());
                    std::thread::spawn(move || {
                        let _ = serve_webdav(stream, objs, fl, dr);
                    });
                }
            });
            Self {
                base_url: format!("http://127.0.0.1:{port}"),
                objects,
                fail_delete_suffix: fail,
                dirs,
            }
        }

        /// 以「服务端既有对象」身份预置（模拟 rekey 后残留的陈旧清单/分片）
        fn seed(&self, path: &str, bytes: &[u8]) {
            self.objects
                .lock()
                .unwrap()
                .insert(path.to_string(), bytes.to_vec());
        }

        fn get(&self, path: &str) -> Option<Vec<u8>> {
            self.objects.lock().unwrap().get(path).cloned()
        }

        /// 命中该后缀的 DELETE 一律回 500
        fn fail_delete_ending(&self, suffix: &str) {
            *self.fail_delete_suffix.lock().unwrap() = Some(suffix.to_string());
        }
    }

    /// 单连接请求循环（HTTP/1.1 keep-alive：reqwest 连接池会复用连接）
    fn serve_webdav(
        mut stream: std::net::TcpStream,
        objects: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>>,
        fail_delete_suffix: std::sync::Arc<std::sync::Mutex<Option<String>>>,
        dirs: std::sync::Arc<std::sync::Mutex<std::collections::HashSet<String>>>,
    ) -> std::io::Result<()> {
        use std::io::{BufRead, BufReader, Read, Write};

        let mut reader = BufReader::new(stream.try_clone()?);
        loop {
            let mut request_line = String::new();
            if reader.read_line(&mut request_line)? == 0 {
                return Ok(());
            }
            if request_line.trim().is_empty() {
                continue;
            }
            let mut it = request_line.split_whitespace();
            let (Some(method), Some(target)) = (it.next(), it.next()) else {
                return Ok(());
            };
            let (method, target) = (method.to_string(), target.to_string());
            let mut body_len = 0usize;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line)? == 0 {
                    break;
                }
                let trimmed = line.trim_end();
                if trimmed.is_empty() {
                    break;
                }
                if let Some((k, v)) = trimmed.split_once(':')
                    && k.trim().eq_ignore_ascii_case("content-length")
                {
                    body_len = v.trim().parse().unwrap_or(0);
                }
            }
            let mut body = vec![0u8; body_len];
            if body_len > 0 && reader.read_exact(&mut body).is_err() {
                return Ok(());
            }
            // absolute-form（本机常驻系统代理时 reqwest 的请求行形态）归一为路径
            let path = target
                .strip_prefix("http://")
                .or_else(|| target.strip_prefix("https://"))
                .map(|rest| match rest.find('/') {
                    Some(i) => rest[i..].to_string(),
                    None => "/".to_string(),
                })
                .unwrap_or(target);

            // (状态码, 响应体, HEAD 专用声明长度)
            let (status, payload, head_len) = match method.as_str() {
                "PROPFIND" => (404, Vec::new(), None),
                "MKCOL" => {
                    dirs.lock()
                        .unwrap()
                        .insert(path.trim_end_matches('/').to_string());
                    (201, Vec::new(), None)
                }
                "PUT" => {
                    // `/strict/` 前缀：模拟「父目录不存在即 409 AncestorsNotFound」的
                    // 标准 WebDAV（RFC 4918）。其余路径保持宽松（PUT 恒 200），
                    // 以免改动 F59 分片用例的既有前提。
                    let parent = path.rsplit_once('/').map(|(p, _)| p).unwrap_or("/");
                    let missing_parent =
                        path.starts_with("/strict/") && !dirs.lock().unwrap().contains(parent);
                    if missing_parent {
                        (409, Vec::new(), None)
                    } else {
                        objects.lock().unwrap().insert(path.clone(), body);
                        (200, Vec::new(), None)
                    }
                }
                "GET" => match objects.lock().unwrap().get(&path) {
                    Some(b) => (200, b.clone(), None),
                    None => (404, Vec::new(), None),
                },
                "HEAD" => match objects.lock().unwrap().get(&path).map(|b| b.len()) {
                    // `/nolength/` 前缀：模拟部分实现「HEAD 不回 Content-Length」的形态
                    // （F57 用例），`usize::MAX` 是「不写该头」的哨兵
                    Some(_) if path.starts_with("/nolength/") => {
                        (200, Vec::new(), Some(usize::MAX))
                    }
                    Some(n) => (200, Vec::new(), Some(n)),
                    None => (404, Vec::new(), Some(0)),
                },
                "DELETE" => {
                    let injected = fail_delete_suffix
                        .lock()
                        .unwrap()
                        .as_deref()
                        .is_some_and(|s| path.ends_with(s));
                    if injected {
                        (500, b"delete failed".to_vec(), None)
                    } else if objects.lock().unwrap().remove(&path).is_some() {
                        (204, Vec::new(), None)
                    } else {
                        (404, Vec::new(), None)
                    }
                }
                _ => (405, Vec::new(), None),
            };
            let declared = head_len.unwrap_or(payload.len());
            let mut head = format!("HTTP/1.1 {status} X\r\n");
            if declared != usize::MAX {
                head.push_str(&format!("Content-Length: {declared}\r\n"));
            }
            head.push_str("Connection: keep-alive\r\n\r\n");
            stream.write_all(head.as_bytes())?;
            if head_len.is_none() {
                stream.write_all(&payload)?;
            }
            stream.flush()?;
        }
    }

    // ========================================================================
    // F56（2026-10-01 第六轮）：条件写必须与普通写一样先补齐父目录
    // ========================================================================

    /// F56：父目录链不存在时，条件写必须自愈而不是报「并发冲突」
    ///
    /// 旧行为：`upload_conditional` 不做 `ensure_directory` → 服务端 409
    /// AncestorsNotFound → `put_conditional` 把「带前置条件的 409」折成
    /// `Ok(false)` → 本方法返回 `PreconditionFailed` → 调用方（清单 CAS）判
    /// 「并发冲突」并重试，目录依旧不在 → 重试耗尽后报「并发冲突重试 N 次仍
    /// 未成功」，而真实成因是目录缺失（可自愈），**清单永不落盘**。
    ///
    /// 这里用 FakeDav 的 `/strict/` 前缀模拟标准 WebDAV（父目录不存在即 409）。
    /// 因 FakeDav 的 PROPFIND 恒 404，`ensure_directory` 会逐级 MKCOL 建链。
    #[tokio::test]
    async fn conditional_write_creates_missing_parent_directory() {
        let dav = FakeDav::spawn();
        let adapter = adapter_for(&dav.base_url);
        let payload = b"encrypted-manifest".to_vec();

        let outcome = adapter
            .upload_conditional(
                "strict/fresh/manifest.json",
                &payload,
                UploadPrecondition::Absent,
            )
            .await
            .expect("条件写不得因父目录缺失而失败");

        assert_eq!(
            outcome,
            UploadOutcome::Ok,
            "父目录缺失不属并发冲突——不得报 PreconditionFailed（那会让调用方\
             反复重读重试，最终以「并发冲突」掩盖真实成因）"
        );
        assert_eq!(
            dav.get("/strict/fresh/manifest.json"),
            Some(payload),
            "补齐父目录后条件写必须真正落到云端"
        );
    }

    /// F59：清单删除失败 ⇒ 清理未完成 ⇒ 必须上抛，且**不得写入新清单**
    ///
    /// 旧行为：失败仅记日志，随后照常逐片上传并写新 head.json——目录里是旧密文、
    /// 清单却声明本轮密文，读侧拼装 sha256 校验永久失败（`retryable: false`，每轮
    /// 重试都被同一判据拒掉）。
    #[tokio::test]
    async fn stale_manifest_delete_failure_aborts_upload() {
        let dav = FakeDav::spawn();
        let adapter = adapter_for(&dav.base_url);
        let head_path = "/assets_parts/abc123/head.json";
        let stale_head: &[u8] = br#"{"total":2,"size":1,"sha256":"stale-not-this-round"}"#;
        dav.seed(head_path, stale_head);
        dav.seed(
            "/assets_parts/abc123/000000.bin",
            &vec![0xAAu8; 5 * 1024 * 1024],
        );
        dav.fail_delete_ending("/head.json");

        let encrypted = vec![0x5Au8; 9 * 1024 * 1024];
        adapter
            .upload_asset_parts("abc123", "assets_parts", "assets/abc123.orsync", &encrypted)
            .await
            .expect_err("清单删除失败必须上抛，不得静默继续");

        assert_eq!(
            dav.get(head_path).as_deref(),
            Some(stale_head),
            "清理未完成时不得写入新清单（否则产出内容与清单不自洽的「完整」对象）"
        );
    }

    /// F59：清单不匹配 ⇒ 目录内容不可信，陈旧分片必须**覆盖重传**（不得按 size 跳过）
    ///
    /// 此处只让「删分片」失败：清单被删掉（目录从此不可读）、陈旧首片留下。旧实现
    /// 逐片按 `Content-Length` 跳过（同明文跨 Data Key 的密文长度必然相同，5MiB 首片
    /// 尺寸恒等），于是写出「清单声明本轮密文、首片还是旧密文」的对象。
    #[tokio::test]
    async fn stale_parts_are_overwritten_when_manifest_mismatch() {
        let dav = FakeDav::spawn();
        let adapter = adapter_for(&dav.base_url);
        let head_path = "/assets_parts/abc123/head.json";
        let first_part = "/assets_parts/abc123/000000.bin";
        dav.seed(
            head_path,
            br#"{"total":2,"size":1,"sha256":"stale-not-this-round"}"#,
        );
        dav.seed(first_part, &vec![0xAAu8; 5 * 1024 * 1024]);
        dav.fail_delete_ending(".bin");

        let encrypted: Vec<u8> = (0..9 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        adapter
            .upload_asset_parts("abc123", "assets_parts", "assets/abc123.orsync", &encrypted)
            .await
            .expect("清单已删、目录不可读 ⇒ 清理视为完成，应能上传");

        assert_eq!(
            dav.get(first_part),
            Some(encrypted[..5 * 1024 * 1024].to_vec()),
            "陈旧首片必须被覆盖重传，而不是按 size 跳过"
        );
        let head: AssetPartsHead =
            serde_json::from_slice(&dav.get(head_path).expect("清单已写入")).expect("清单可解析");
        assert_eq!(head.size, encrypted.len());
        assert_eq!(head.sha256, crate::crypto::sha256::sha256_hex(&encrypted));
    }

    /// F57：HEAD 2xx 但不回 `Content-Length` ⇒ 仍算「存在」
    ///
    /// 旧实现复用 `remote_file_size`，缺该头时返回 `None` → **存在的对象被判「不存在」**。
    /// 后果不是报错而是静默走错分支：附件差集每轮空跑重传、S7 首传三分叉探测误放行、
    /// pull 的活跃引用判定失真。这里用 `/nolength/` 前缀让假服务省略该头。
    #[tokio::test]
    async fn head_without_content_length_still_counts_as_existing() {
        let dav = FakeDav::spawn();
        let adapter = adapter_for(&dav.base_url);
        dav.seed("/nolength/abc.orsync", b"payload");

        assert!(
            adapter
                .exists("nolength/abc.orsync")
                .await
                .expect("HEAD 探测"),
            "HEAD 2xx 即存在，与是否回 Content-Length 无关"
        );
        // 对照：大小语义如实反映「服务端没给长度」——所以它不能被当作存在性判据
        assert_eq!(
            adapter
                .remote_file_size("/nolength/abc.orsync")
                .await
                .expect("HEAD 探测"),
            None
        );
    }
}

// ====================================================================
// S4 WebDAV 分片协议纯函数（2026-09-14）
//
// 端到端分片上传/拼装需真实 WebDAV 服务器（m4 集成测试职责，本机
// 无环境为已知边界）；此处覆盖分派判定的全部路径形态与清单结构。
// ====================================================================

/// 测试辅助：只要 hash 分量（分片根目录另有专项用例）
#[cfg(test)]
fn hash_of(path: &str) -> Option<String> {
    asset_parts_target(path).map(|(h, _)| h)
}

/// 测试辅助：只要分片根目录分量
#[cfg(test)]
fn parts_root_of(path: &str) -> Option<String> {
    asset_parts_target(path).map(|(_, root)| root)
}

#[test]
fn asset_parts_target_new_naming() {
    assert_eq!(hash_of("assets/abc123.orsync").as_deref(), Some("abc123"));
    assert_eq!(
        parts_root_of("assets/abc123.orsync").as_deref(),
        Some("assets_parts"),
        "无前缀形态（根目录部署）的分片根目录仍是 assets_parts"
    );
}

/// F23 核心回归：base_path 前缀形态必须识别，且 parts_root 同带前缀
///
/// 旧判定 `path.starts_with("assets/")` 对本形态返回 None → 生产链路大附件
/// 分片协议从未执行。此用例把「前缀深度无关」与「分片不得写到 base_path
/// 之外」两件事一起钉住。
#[test]
fn asset_parts_target_accepts_base_path_prefixed_form() {
    assert_eq!(hash_of("wait/assets/abc.orsync").as_deref(), Some("abc"));
    assert_eq!(
        parts_root_of("wait/assets/abc.orsync").as_deref(),
        Some("wait/assets_parts"),
        "分片必须落在 base_path/assets_parts 之内"
    );
    // 多级前缀同理
    assert_eq!(
        parts_root_of("a/b/c/assets/abc.orsync").as_deref(),
        Some("a/b/c/assets_parts")
    );
}

#[test]
fn asset_parts_target_bare_naming_and_legacy_suffix() {
    // 裸文件名（无后缀）原样作为 hash 解析
    assert_eq!(hash_of("assets/abc123").as_deref(), Some("abc123"));
    // 遗留后缀不再是同步载荷：原样保留，避免与同 hash 的新对象混淆
    assert_eq!(
        hash_of("assets/abc123.waitsync").as_deref(),
        Some("abc123.waitsync")
    );
}

#[test]
fn asset_parts_target_rejects_non_asset() {
    // 模块数据路径（同名文件在 modules/ 下）不得误判为附件
    assert!(hash_of("modules/todos/data.orsync").is_none());
    assert!(hash_of("modules/todos/data.waitsync").is_none());
    assert!(hash_of("crypto/config").is_none());
    assert!(hash_of("_meta.orsync").is_none());
    assert!(hash_of("_meta.waitsync").is_none());
    // 分片自身路径（父目录是 {hash}）不得再触发分片分派——否则
    // download/exists 的回退会在拼装内部自我递归
    assert!(hash_of("wait/assets_parts/abc/head.json").is_none());
    assert!(hash_of("assets_parts/abc/000000.bin").is_none());
    // assets 必须是**目录段**，不是文件名的一部分
    assert!(hash_of("assets_dir.orsync").is_none());
    assert!(hash_of("wait/assetsx/abc.orsync").is_none());
}

#[test]
fn asset_parts_target_rejects_empty_hash() {
    assert!(hash_of("assets/.orsync").is_none());
}

#[test]
fn parts_root_for_assets_dir_replaces_last_segment() {
    assert_eq!(parts_root_for_assets_dir("assets"), "assets_parts");
    assert_eq!(
        parts_root_for_assets_dir("wait-sync/user1/assets"),
        "wait-sync/user1/assets_parts"
    );
}

#[test]
fn part_paths_are_derived_correctly() {
    assert_eq!(
        WebDavAdapter::part_bin_path("assets_parts", "abc", 0),
        "assets_parts/abc/000000.bin"
    );
    assert_eq!(
        WebDavAdapter::part_bin_path("wait/assets_parts", "abc", 42),
        "wait/assets_parts/abc/000042.bin"
    );
    assert_eq!(
        WebDavAdapter::parts_head_path("wait/assets_parts", "abc"),
        "wait/assets_parts/abc/head.json"
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
