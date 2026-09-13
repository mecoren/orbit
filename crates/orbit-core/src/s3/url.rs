/// 规范化 endpoint：补全 scheme、去掉末尾斜杠
///
/// 与 Dart `S3SyncAdapter._normalizeEndpoint` 行为一致。
pub fn normalize_endpoint(endpoint: &str) -> String {
    let mut s = endpoint.trim().to_string();
    if !s.starts_with("http://") && !s.starts_with("https://") {
        s = format!("https://{}", s);
    }
    if s.ends_with('/') {
        s.pop();
    }
    s
}

/// 从 endpoint 推断 S3 region
pub fn infer_region(endpoint: &str) -> String {
    let lower = endpoint.to_lowercase();
    // 阿里云 OSS: oss-cn-shenzhen.aliyuncs.com → cn-shenzhen
    if let Some(caps) = regex::Regex::new(r"oss-([a-z0-9-]+)\.aliyuncs\.com")
        .ok()
        .and_then(|re| re.captures(&lower))
        && let Some(m) = caps.get(1)
    {
        return m.as_str().to_string();
    }
    // AWS 中国: s3.cn-north-1.amazonaws.com.cn → cn-north-1
    if let Some(caps) = regex::Regex::new(r"s3\.([a-z0-9-]+)\.amazonaws\.com\.cn")
        .ok()
        .and_then(|re| re.captures(&lower))
        && let Some(m) = caps.get(1)
    {
        return m.as_str().to_string();
    }
    // AWS 标准: s3.us-west-2.amazonaws.com → us-west-2
    if let Some(caps) = regex::Regex::new(r"s3\.([a-z0-9-]+)\.amazonaws\.com")
        .ok()
        .and_then(|re| re.captures(&lower))
        && let Some(m) = caps.get(1)
    {
        return m.as_str().to_string();
    }
    if lower.contains("amazonaws.com") {
        return "us-east-1".to_string();
    }
    "us-east-1".to_string()
}

/// 判断是否应使用 path-style（Path-Style）访问
///
/// - AWS 官方域名（amazonaws.com）与阿里云 OSS 默认域名（aliyuncs.com）
///   使用 virtual-hosted-style。阿里云 OSS 对默认域名不支持 path-style，
///   会返回 `403 SecondLevelDomainForbidden: Please use virtual hosted style to access.`
/// - 其余（MinIO、自建 S3 等）使用 path-style
pub fn infer_use_path_style(endpoint: &str) -> bool {
    let lower = endpoint.to_lowercase();
    !(lower.contains("amazonaws.com") || lower.contains("aliyuncs.com"))
}

/// 根据 endpoint 判断签名使用的 service 名称
pub fn infer_service(endpoint: &str) -> String {
    let lower = endpoint.to_lowercase();
    if lower.contains("aliyuncs.com") {
        "oss".to_string()
    } else {
        "s3".to_string()
    }
}

/// 构建 S3 对象 URL
///
/// Virtual-Hosted-Style: https://<bucket>.<endpoint>/<path>
/// Path-Style: https://<endpoint>/<bucket>/<path>
pub fn build_url(
    endpoint: &str,
    bucket: &str,
    path: &str,
    use_path_style: bool,
    query_params: &[(String, String)],
) -> String {
    // S2（2026-09-13 探查）：此前 normalize_endpoint 是死代码——无 scheme
    // 输入（minio.example.com:9000）拼出无 scheme 的最终 URL，签名层
    // Url::parse 失败被误报「认证错误」；尾斜杠产生 //bucket 双斜杠。
    // build_url 自我规范化（补 scheme + 去尾斜杠），注释假设自此成立。
    let endpoint = &normalize_endpoint(endpoint);
    let uri = url::Url::parse(endpoint).unwrap_or_else(|_| {
        // 不可能触发，normalize_endpoint 保证 scheme 存在
        url::Url::parse(&format!("https://{}", endpoint)).unwrap()
    });
    let host = uri.host_str().unwrap_or("");
    let host_with_port = match uri.port() {
        Some(p) => format!("{}:{}", host, p),
        None => host.to_string(),
    };
    let mut buffer = if use_path_style {
        format!("{}/{}", endpoint, bucket)
    } else {
        format!("{}://{}.{}", uri.scheme(), bucket, host_with_port)
    };
    if !path.is_empty() {
        buffer.push('/');
        buffer.push_str(path);
    }
    if !query_params.is_empty() {
        buffer.push('?');
        buffer.push_str(&build_canonical_query(query_params));
    }
    buffer
}

/// 构建 canonical query string（按 key 字典序排列，URL 编码）
pub fn build_canonical_query(params: &[(String, String)]) -> String {
    let mut sorted = params.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    sorted
        .iter()
        .map(|(k, v)| format!("{}={}", urlencoding::encode(k), urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

#[cfg(test)]
mod tests {
    use super::*;

    // ========================================================================
    // infer_service（P0-4）：OSS 签名 service 必须返回 "oss"
    // 硬编码 "s3" 时 OSS 的 V4 credential scope 不匹配 → 全部请求 403
    // ========================================================================

    #[test]
    fn infer_service_oss_domain() {
        assert_eq!(infer_service("https://oss-cn-shenzhen.aliyuncs.com"), "oss");
        assert_eq!(
            infer_service("https://OSS-CN-HANGZHOU.ALIYUNCS.COM"),
            "oss",
            "域名大小写不敏感"
        );
    }

    #[test]
    fn infer_service_aws_and_minio() {
        assert_eq!(infer_service("https://s3.us-west-2.amazonaws.com"), "s3");
        assert_eq!(infer_service("https://minio.example.com"), "s3");
    }

    // ========================================================================
    // build_canonical_query：分页参数（continuation-token）按 key 排序 + URL 编码
    // ========================================================================

    #[test]
    fn canonical_query_sorts_and_encodes() {
        let q = build_canonical_query(&[
            ("prefix".to_string(), "assets/".to_string()),
            ("list-type".to_string(), "2".to_string()),
            ("continuation-token".to_string(), "a b+c/1=".to_string()),
        ]);
        // 按 key 字典序：continuation-token < list-type < prefix
        assert_eq!(
            q,
            "continuation-token=a%20b%2Bc%2F1%3D&list-type=2&prefix=assets%2F"
        );
    }

    // ========================================================================
    // S2：endpoint 规范化接线——build_url 必须对任意输入形态产出可解析 URL
    // 历史 bug：normalize_endpoint 是死代码，无 scheme 输入拼出无 scheme URL，
    // 签名层 Url::parse 失败被误报「认证错误」
    // ========================================================================

    #[test]
    fn build_url_normalizes_schemeless_endpoint() {
        // 最常见的自建 MinIO 配置形态：无 scheme 带端口
        let url = build_url(
            "minio.example.com:9000",
            "mybucket",
            "assets/abc.waitsync",
            true,
            &[],
        );
        assert_eq!(url, "https://minio.example.com:9000/mybucket/assets/abc.waitsync");
    }

    #[test]
    fn build_url_normalizes_trailing_slash() {
        // 尾斜杠不得产生 //bucket 双斜杠
        let url = build_url(
            "https://minio.example.com:9000/",
            "mybucket",
            "data.waitsync",
            true,
            &[],
        );
        assert_eq!(url, "https://minio.example.com:9000/mybucket/data.waitsync");
    }

    #[test]
    fn build_url_preserves_explicit_scheme() {
        // 显式 http:// 不得被改写为 https（局域网 MinIO 常用 http）
        let url = build_url(
            "http://192.168.1.10:9000",
            "b",
            "k",
            true,
            &[],
        );
        assert_eq!(url, "http://192.168.1.10:9000/b/k");
    }

    #[test]
    fn build_url_virtual_hosted_style_untouched() {
        // 带 scheme 的标准 virtual-hosted-style 输入保持原有行为
        let url = build_url(
            "https://oss-cn-shenzhen.aliyuncs.com",
            "mybucket",
            "modules/todo/data.waitsync",
            false,
            &[],
        );
        assert_eq!(
            url,
            "https://mybucket.oss-cn-shenzhen.aliyuncs.com/modules/todo/data.waitsync"
        );
    }

    #[test]
    fn build_url_whitespace_only_endpoint_falls_back_to_https() {
        // 全空白输入：normalize 后为 "https://"，parse 失败走兜底分支
        // 兜底保证产出带 scheme 的 URL（scheme 恒存在，签名层不再失败）
        let url = build_url("   ", "b", "k", true, &[]);
        assert!(url.starts_with("https://"), "兜底也必须带 scheme: {url}");
    }
}
