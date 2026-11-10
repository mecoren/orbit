/// AWS SigV4 UriEncode（RFC 3986 unreserved 集）
///
/// 只有 `A-Z a-z 0-9 - _ . ~` 原样保留，其余字节一律 `%XX`（**大写**十六进制，
/// 按 UTF-8 逐字节编码）——这是 AWS 对 canonical URI 与 canonical query 的
/// 硬性要求，与 `url` crate 的 WHATWG 编码集**不等价**：
///
/// | 字符 | WHATWG 路径集 | AWS UriEncode | 后果 |
/// |---|---|---|---|
/// | 空格 | `%20` | `%20` | 一致 |
/// | `#` `?` | `%23` / `%3F` | 同 | 一致（但见下） |
/// | `+` `=` `&` `,` `:` `;` `@` `$` `!` `'` `(` `)` `*` `[` `]` | **原样** | **`%XX`** | 不一致 |
///
/// `encode_slash`：canonical URI 必须**保留** `/` 作路径分隔符（传 `false`），
/// 而 key 名/单段值须编码（传 `true`）。
///
/// ## 为什么必须自己编码（F51，2026-09-30 第六轮）
///
/// 此前 `build_url` 把裸 `path` 直接拼进 URL 字符串，再由 `Url::parse` 按
/// WHATWG 规则归一。两个后果：
///
/// 1. **`#` / `?` 截断**：key 或 `base_path` 含这两个字符时，`Url::parse`
///    把它们当 fragment / query 起点 → 静默指向**另一个对象**（`%`/`"`/
///    `<`/`>`/`` ` ``/`{}` 虽被 WHATWG 编码，但 canonical URI 仍是
///    服务端未见的形态）。
/// 2. **canonical URI 与 AWS 口径不一致**：`+`/`=`/`[` 这类字符 WHATWG
///    不编码而 AWS 要求编码；签名一旦与服务端重算结果不同即整包 403。
///
/// 修法：**唯一编码点**放在 `build_url`——发出的 URL 与 `sign_request`
/// 里的 `parsed.path()` 天然同源（`url` crate 不会改动已 `%XX` 化的路径）。
pub fn uri_encode(s: &str, encode_slash: bool) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        let unreserved = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~');
        if unreserved || (!encode_slash && b == b'/') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0f) as usize] as char);
        }
    }
    out
}

/// 规范化 endpoint：补全 scheme、统一小写 scheme、去掉末尾斜杠
///
/// 与 Dart `S3SyncAdapter._normalizeEndpoint` 行为一致。
///
/// scheme 判定**大小写不敏感**（2026-11-10）：移动端输入法/剪贴板常给出
/// `HTTPS://host`，大小写敏感的 `starts_with` 会把它当无 scheme 输入再补一个
/// `https://`，拼出 `https://HTTPS://host`——`Url::parse` 取 authority 里的
/// 字面量 `HTTPS:` 当主机名，最终请求打到 `https://<bucket>.https/` 这种
/// 不存在的主机，报错与真实配置毫无关系。
pub fn normalize_endpoint(endpoint: &str) -> String {
    let mut s = endpoint.trim().to_string();
    let has_scheme = s
        .get(..8)
        .map(|p| p.eq_ignore_ascii_case("https://"))
        .unwrap_or(false)
        || s.get(..7)
            .map(|p| p.eq_ignore_ascii_case("http://"))
            .unwrap_or(false);
    if !has_scheme {
        s = format!("https://{}", s);
    }
    if let Some(pos) = s.find("://") {
        let scheme = s[..pos].to_ascii_lowercase();
        s = format!("{}{}", scheme, &s[pos..]);
    }
    if s.ends_with('/') {
        s.pop();
    }
    s
}

/// endpoint 结构自检：`None` = 可用，`Some(原因)` = 配置期就该拦下
///
/// 只要 `build_url` 拿不到「带 scheme + 带主机名」的 endpoint，
/// virtual-hosted-style 拼接就会把残缺片段当主机名：Endpoint 只填到
/// `https://`（或 `https`、`HTTPS://`）时实际请求的是
/// `https://<bucket>.https/?list-type=2`（2026-11-10 移动端实测报错
/// 「error sending request for url (https://wait-test.https/?li…)」），
/// 用户拿着一个完全正确的 OSS 地址却看到「网络错误」。
/// 故在校验层（`engine::validate_config`）与构造层（`engine::create_adapter`）
/// 统一拦截，报可读的配置错误。
pub fn endpoint_problem(endpoint: &str) -> Option<String> {
    let trimmed = endpoint.trim();
    // 显式写了非 http(s) 协议：`normalize_endpoint` 会再补一个 `https://`，
    // 拼出的主机名与用户意图无关，必须按协议拦下
    if let Some(pos) = trimmed.find("://") {
        let scheme = trimmed[..pos].to_ascii_lowercase();
        if !matches!(scheme.as_str(), "http" | "https") {
            return Some(format!("仅支持 http:// 或 https://，当前是 {scheme}://"));
        }
    }
    let normalized = normalize_endpoint(trimmed);
    let parsed = match url::Url::parse(&normalized) {
        Ok(u) => u,
        Err(e) => return Some(format!("不是有效的 URL（{e}）")),
    };
    // 残缺输入 `https` 会被补成 `https://https`，主机名恰好是字面量
    // "https"——真实主机名不会长这样，按「没填主机」处理
    let host_ok = parsed
        .host_str()
        .map(|h| {
            !h.is_empty() && !h.eq_ignore_ascii_case("http") && !h.eq_ignore_ascii_case("https")
        })
        .unwrap_or(false);
    if !host_ok {
        return Some("缺少主机名（应形如 https://oss-cn-shenzhen.aliyuncs.com）".to_string());
    }
    None
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
///
/// F80（2026-10-01 第六轮）口径论证：SigV4 的 credential scope service 只有两类
/// 取值——阿里云 OSS 要求 `oss`（P0-4），其余一切 S3 兼容实现（MinIO/Ceph/B2/
/// R2/腾讯 COS 兼容层等）按 AWS 规范均接受 `s3`。故「非 OSS 即 s3」的判定是
/// 完备的，扩展域名清单反而会在无真机验证的情况下引入 SignatureDoesNotMatch
/// 风险（真服务端方言验证是 N53 盲区，不做臆测性扩展）。
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
///
/// **`bucket` 与 `path` 在此处按 AWS UriEncode 编码（F51 的唯一编码点）**：
/// 发出的 URL 与 `S3Adapter::sign_request` 里 `Url::parse(url).path()`
/// 因此天然同源，canonical URI 不会与 AWS 重算结果漂移。调用方传入**原始
/// 未编码**的路径（含空格、`#`、`+` 等），不要自行百分号编码（会二次编码）。
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
        format!("{}/{}", endpoint, uri_encode(bucket, true))
    } else {
        format!("{}://{}.{}", uri.scheme(), bucket, host_with_port)
    };
    if !path.is_empty() {
        // F51：唯一编码点。发出的 URL 与 sign_request 的 parsed.path()
        // 必须与 AWS UriEncode 口径完全一致（保留 `/` 作分隔符）。
        buffer.push('/');
        buffer.push_str(&uri_encode(path, false));
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
            "assets/abc.orsync",
            true,
            &[],
        );
        assert_eq!(
            url,
            "https://minio.example.com:9000/mybucket/assets/abc.orsync"
        );
    }

    #[test]
    fn build_url_normalizes_trailing_slash() {
        // 尾斜杠不得产生 //bucket 双斜杠
        let url = build_url(
            "https://minio.example.com:9000/",
            "mybucket",
            "data.orsync",
            true,
            &[],
        );
        assert_eq!(url, "https://minio.example.com:9000/mybucket/data.orsync");
    }

    #[test]
    fn build_url_preserves_explicit_scheme() {
        // 显式 http:// 不得被改写为 https（局域网 MinIO 常用 http）
        let url = build_url("http://192.168.1.10:9000", "b", "k", true, &[]);
        assert_eq!(url, "http://192.168.1.10:9000/b/k");
    }

    #[test]
    fn build_url_virtual_hosted_style_untouched() {
        // 带 scheme 的标准 virtual-hosted-style 输入保持原有行为
        let url = build_url(
            "https://oss-cn-shenzhen.aliyuncs.com",
            "mybucket",
            "modules/todo/data.orsync",
            false,
            &[],
        );
        assert_eq!(
            url,
            "https://mybucket.oss-cn-shenzhen.aliyuncs.com/modules/todo/data.orsync"
        );
    }

    #[test]
    fn build_url_whitespace_only_endpoint_falls_back_to_https() {
        // 全空白输入：normalize 后为 "https://"，parse 失败走兜底分支
        // 兜底保证产出带 scheme 的 URL（scheme 恒存在，签名层不再失败）
        let url = build_url("   ", "b", "k", true, &[]);
        assert!(url.starts_with("https://"), "兜底也必须带 scheme: {url}");
    }

    // ========================================================================
    // F51（2026-09-30 第六轮）：AWS UriEncode 纳入唯一编码点
    //
    // 此前路径裸拼进 URL 由 `Url::parse` 按 WHATWG 规则归一：`#`/`?` 截断、
    // `+`/`=`/`[` 等 AWS 要求编码的字符原样保留 → canonical URI 与
    // 服务端重算结果不一致（整包 403），或静默指向另一个对象。
    // ========================================================================

    #[test]
    fn uri_encode_keeps_unreserved_and_slash() {
        // 真实的 URL 路径形态（hash 十六进制 + 表名 + 后缀）必须原样通过
        assert_eq!(
            uri_encode("tables/todo_tasks/12.orsync", false),
            "tables/todo_tasks/12.orsync"
        );
        assert_eq!(
            uri_encode("assets/abc-def_1.2~3", false),
            "assets/abc-def_1.2~3"
        );
    }

    #[test]
    fn uri_encode_encodes_aws_only_chars() {
        // 这一批正是 WHATWG 路径集**不编码**而 AWS 要求编码的字符
        assert_eq!(
            uri_encode("a+b=c&d,e:f;g@h$i!j'k(l)m*n[o]", false),
            "a%2Bb%3Dc%26d%2Ce%3Af%3Bg%40h%24i%21j%27k%28l%29m%2An%5Bo%5D"
        );
    }

    #[test]
    fn uri_encode_encodes_slash_when_asked() {
        // encode_slash = true 供「单段值 / key 名」使用（如 canonical query）
        assert_eq!(uri_encode("a/b", true), "a%2Fb");
        assert_eq!(
            uri_encode("a/b", false),
            "a/b",
            "canonical URI 必须保留分隔符"
        );
    }

    #[test]
    fn uri_encode_handles_truncation_chars_percent_and_utf8() {
        // `#` / `?` 不编码会被 Url::parse 当 fragment / query 起点
        assert_eq!(uri_encode("k#1?2", false), "k%231%3F2");
        // 裸 `%` 在地址里非法，必须自身编码（否则出现非法百分号序列）
        assert_eq!(uri_encode("100%", false), "100%25");
        // 非 ASCII 按 UTF-8 逐字节编码（"中" = E4 B8 AD）
        assert_eq!(uri_encode("中", true), "%E4%B8%AD");
    }

    #[test]
    fn build_url_percent_encodes_path_and_leaves_no_fragment() {
        // base_path 含空格 / `+` / `#` 的真实形态：此前 `#` 之后整段被截断成
        // fragment，签名与实际对象同时指向错误目标
        let url = build_url(
            "https://minio.example.com",
            "b",
            "wait sync/a+b#c",
            true,
            &[],
        );
        assert_eq!(url, "https://minio.example.com/b/wait%20sync/a%2Bb%23c");

        // 签名侧直接取 parsed.path()：与发出的形态同源，即 AWS canonical URI
        let parsed = url::Url::parse(&url).unwrap();
        assert_eq!(parsed.path(), "/b/wait%20sync/a%2Bb%23c");
        assert!(parsed.fragment().is_none(), "不得残留 fragment");
        assert!(parsed.query().is_none(), "不得把 key 里的 ? 当查询起点");
    }

    #[test]
    fn build_url_empty_path_unchanged() {
        assert_eq!(
            build_url("https://minio.example.com", "b", "", true, &[]),
            "https://minio.example.com/b"
        );
        assert_eq!(
            build_url("https://s3.us-west-2.amazonaws.com", "b", "", false, &[]),
            "https://b.s3.us-west-2.amazonaws.com"
        );
    }

    #[test]
    fn build_url_query_still_encoded_after_path_encoding() {
        // 路径编码不得干扰查询串（uploadId 含 `+`/`/`/`=` 的典型值）
        let url = build_url(
            "https://minio.example.com",
            "b",
            "tables/todo/1.orsync",
            true,
            &[("uploadId".to_string(), "a+b/c=".to_string())],
        );
        assert_eq!(
            url,
            "https://minio.example.com/b/tables/todo/1.orsync?uploadId=a%2Bb%2Fc%3D"
        );
    }

    // ========================================================================
    // endpoint 残缺输入（2026-11-10 移动端实测）
    //
    // Endpoint 只填到 `https://`（或遗留大写 scheme）时，virtual-hosted-style
    // 拼接把残缺片段当主机名，请求打到 `https://<bucket>.https/`，
    // 用户看到的是与配置无关的「网络错误」。
    // ========================================================================

    #[test]
    fn normalize_endpoint_scheme_is_case_insensitive() {
        // 大写 scheme 不得被再补一个 https://（会拼出 https://HTTPS://host）
        assert_eq!(
            normalize_endpoint("HTTPS://oss-cn-shenzhen.aliyuncs.com/"),
            "https://oss-cn-shenzhen.aliyuncs.com"
        );
        assert_eq!(
            normalize_endpoint("Http://192.168.1.10:9000"),
            "http://192.168.1.10:9000"
        );
        // 无 scheme 仍按原约定补 https://
        assert_eq!(
            normalize_endpoint("minio.example.com:9000"),
            "https://minio.example.com:9000"
        );
    }

    #[test]
    fn build_url_degenerate_endpoint_fabricates_scheme_host() {
        // 记录历史行为（回归锚点）：残缺 endpoint 会产出 `<bucket>.https`，
        // 真实链路已由 endpoint_problem 在配置期拦下，此处仅锁死不再恶化
        let url = build_url("https://", "wait-test", "", false, &[]);
        assert_eq!(url, "https://wait-test.https");
    }

    #[test]
    fn endpoint_problem_accepts_real_endpoints() {
        for ok in [
            "https://oss-cn-shenzhen.aliyuncs.com",
            "https://oss-cn-shenzhen.aliyuncs.com/",
            "HTTPS://oss-cn-shenzhen.aliyuncs.com/",
            "http://192.168.1.10:9000",
            "minio.example.com:9000",
        ] {
            assert_eq!(endpoint_problem(ok), None, "应判为可用: {ok}");
        }
    }

    #[test]
    fn endpoint_problem_rejects_truncated_and_non_http() {
        for (bad, hint) in [
            ("", "不是有效的 URL"),
            ("   ", "不是有效的 URL"),
            ("https", "缺少主机名"),
            ("https://", "不是有效的 URL"),
            ("HTTPS://", "不是有效的 URL"),
            ("ftp://oss-cn-shenzhen.aliyuncs.com", "仅支持 http://"),
        ] {
            let problem = endpoint_problem(bad).expect("残缺 endpoint 必须被拦下");
            assert!(
                problem.contains(hint),
                "原因应含「{hint}」，实际: {problem}（输入: {bad}）"
            );
        }
    }
}
