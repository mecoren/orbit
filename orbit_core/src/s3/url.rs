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
    {
        if let Some(m) = caps.get(1) {
            return m.as_str().to_string();
        }
    }
    // AWS 中国: s3.cn-north-1.amazonaws.com.cn → cn-north-1
    if let Some(caps) = regex::Regex::new(r"s3\.([a-z0-9-]+)\.amazonaws\.com\.cn")
        .ok()
        .and_then(|re| re.captures(&lower))
    {
        if let Some(m) = caps.get(1) {
            return m.as_str().to_string();
        }
    }
    // AWS 标准: s3.us-west-2.amazonaws.com → us-west-2
    if let Some(caps) = regex::Regex::new(r"s3\.([a-z0-9-]+)\.amazonaws\.com")
        .ok()
        .and_then(|re| re.captures(&lower))
    {
        if let Some(m) = caps.get(1) {
            return m.as_str().to_string();
        }
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
