//! 零依赖云同步假服务（第五轮探查 Wave 5）
//!
//! 存在理由：`m4_sync_e2e.rs` 依赖本机 8123 端口的真 WebDAV，探不到就 panic，
//! 干净机器 `cargo test --workspace` 必红；而 CAS/条件写/半截响应/限流这类
//! 「只有服务端配合才能演出来」的路径此前完全没有网络级证据。这里用 std
//! `TcpListener` 起一个内存假服务，把两协议的线上行为变成可控夹具。
//!
//! 口径：
//! - 只服务 HTTP/1.1 短连接（响应恒带 `Connection: close`），一条连接一个请求，
//!   免去 keep-alive 分帧；
//! - 目录是隐式的（PUT 自动带出父级，MKCOL 恒 201），PROPFIND 由对象键反推；
//! - **不校验 SigV4 签名值**（校验签名等价于再写一遍签名器，证明不了自己），
//!   只要求 S3 请求带形态正确的 `Authorization` 头，否则 403——真签名被真服务端
//!   接受由 `#[ignore]` 的活体 MinIO 用例负责。
//! - 故障开关是「计数/布尔」，命中一次即自减，便于测试按轮次预置。

#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 假服务协议形态：决定 PROPFIND/ListObjects 的应答方言与错误体
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    WebDav,
    S3,
}

/// S3 假服务的固定桶名（path-style：URL 为 `/{bucket}/{key}`）
pub const FAKE_BUCKET: &str = "fakebucket";

#[derive(Default)]
struct Obj {
    bytes: Vec<u8>,
    etag: String,
    mtime: i64,
}

#[derive(Default)]
struct State {
    /// 键为 URL 路径本体（含前导 `/`），如 `/orbit/manifest.orsync`
    objects: HashMap<String, Obj>,
    seq: u64,
}

/// 故障注入开关：计数型命中一次自减，布尔型常开
#[derive(Default)]
pub struct Faults {
    /// 前 n 次数据面请求回 5xx（可重试）
    pub flaky: AtomicU64,
    /// 前 n 次回限流（S3 429+SlowDown / WebDAV 503+BlockedTemporarily）
    pub rate_limited: AtomicU64,
    /// 前 n 次 GET 声明完整 Content-Length 却只写一半体后断开
    pub drop_mid_body: AtomicU64,
    /// 前 n 次 GET 写完响应头后停滞（触发客户端读超时）
    pub stall: AtomicU64,
    /// 前 n 次列举响应 XML 从中间截断
    pub short_list: AtomicU64,
    /// 前 n 次条件写无条件回 412（模拟对端抢先写入）
    pub conflict: AtomicU64,
    /// 忽略 If-Match / If-None-Match（部分兼容服务的真实行为）
    pub ignore_conditional: AtomicBool,
}

impl Faults {
    fn take(&self, counter: &AtomicU64) -> bool {
        counter
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                if n == 0 { None } else { Some(n - 1) }
            })
            .is_ok()
    }
}

struct Svc {
    protocol: Protocol,
    state: Arc<Mutex<State>>,
    faults: Arc<Faults>,
    log: Arc<Mutex<Vec<String>>>,
}

/// 假服务句柄：`base_url` 直接填进 `SyncConfig.endpoint`
pub struct FakeCloud {
    pub base_url: String,
    state: Arc<Mutex<State>>,
    pub faults: Arc<Faults>,
    log: Arc<Mutex<Vec<String>>>,
}

impl FakeCloud {
    pub fn spawn(protocol: Protocol) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定空闲端口");
        let port = listener.local_addr().unwrap().port();
        let svc = Arc::new(Svc {
            protocol,
            state: Arc::new(Mutex::new(State::default())),
            faults: Arc::new(Faults::default()),
            log: Arc::new(Mutex::new(Vec::new())),
        });
        let handle = FakeCloud {
            base_url: format!("http://127.0.0.1:{port}"),
            state: svc.state.clone(),
            faults: svc.faults.clone(),
            log: svc.log.clone(),
        };
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let svc = svc.clone();
                // 每条连接一个线程：短连接协议下请求数即线程数，测试轮次有限
                std::thread::spawn(move || {
                    if let Ok(stream) = stream {
                        let _ = handle_conn(stream, svc);
                    }
                });
            }
        });
        handle
    }

    /// 线上请求记录，形如 `PUT /orbit/manifest.orsync if-match=v2 -> 200`
    pub fn requests(&self) -> Vec<String> {
        self.log.lock().unwrap().clone()
    }

    pub fn has_request_with(&self, needle: &str) -> bool {
        self.requests().iter().any(|r| r.contains(needle))
    }

    /// 云端现存对象路径（断言收敛与「第二轮零重传」）
    pub fn object_paths(&self) -> Vec<String> {
        let mut keys: Vec<String> = self.state.lock().unwrap().objects.keys().cloned().collect();
        keys.sort();
        keys
    }

    pub fn object_len(&self, path: &str) -> Option<usize> {
        self.state
            .lock()
            .unwrap()
            .objects
            .get(path)
            .map(|o| o.bytes.len())
    }

    /// 以「对端设备」身份直接改云端对象（换掉 etag），制造真实并发写冲突
    pub fn peer_write(&self, path: &str, bytes: &[u8]) {
        let mut st = self.state.lock().unwrap();
        st.seq += 1;
        let etag = format!("v{}", st.seq);
        st.objects.insert(
            path.to_string(),
            Obj {
                bytes: bytes.to_vec(),
                etag,
                mtime: 1_700_000_000,
            },
        );
    }

    pub fn reset_faults(&self) {
        let f = &self.faults;
        for c in [
            &f.flaky,
            &f.rate_limited,
            &f.drop_mid_body,
            &f.stall,
            &f.short_list,
            &f.conflict,
        ] {
            c.store(0, Ordering::SeqCst);
        }
        f.ignore_conditional.store(false, Ordering::SeqCst);
    }
}

// ============================================================================
// 线上协议实现
// ============================================================================

struct Reply {
    status: u16,
    body: Vec<u8>,
    etag: Option<String>,
    /// 写完响应头后停滞（客户端读超时用例）
    stall: bool,
    /// 声明完整长度却只写一半体
    truncate: bool,
    /// 无体响应（HEAD）
    head_only: bool,
}

impl Reply {
    fn new(status: u16, body: Vec<u8>) -> Self {
        Self {
            status,
            body,
            etag: None,
            stall: false,
            truncate: false,
            head_only: false,
        }
    }

    fn text(status: u16, msg: &str) -> Self {
        Self::new(status, msg.as_bytes().to_vec())
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        412 => "Precondition Failed",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn unquote(v: &str) -> &str {
    v.trim().trim_matches('"')
}

/// 单连接请求循环（HTTP/1.1 keep-alive）
///
/// 客户端（reqwest）有连接池：若服务端「一请求一关闭」，池里会出现已被对端
/// 关闭的连接，下次复用时偶发 `error sending request`（fault_matrix 的
/// 9MiB 分片用例曾据此翻红，且每请求一条新连接把用例拖到两分钟级）。
/// 这里改为在同一条连接上连续处理请求，直到客户端关闭（`read_line` 返回 0）
/// 或响应本身破坏了连接状态（半截体/停滞——必须关闭）。
fn handle_conn(mut stream: TcpStream, svc: Arc<Svc>) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut reader = BufReader::new(stream.try_clone()?);

    loop {
        let mut request_line = String::new();
        match reader.read_line(&mut request_line) {
            Ok(0) => return Ok(()), // 客户端关闭连接
            Ok(_) => {}
            Err(_) => return Ok(()), // 读超时/重置：结束本连接
        }
        if request_line.trim().is_empty() {
            continue;
        }
        let mut it = request_line.split_whitespace();
        let (Some(method), Some(target)) =
            (it.next().map(str::to_string), it.next().map(str::to_string))
        else {
            return Ok(());
        };

        let mut headers = HashMap::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line)? == 0 {
                break;
            }
            let trimmed = line.trim_end();
            if trimmed.is_empty() {
                break;
            }
            if let Some((k, v)) = trimmed.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }
        let mut body = Vec::new();
        if let Some(len) = headers
            .get("content-length")
            .and_then(|v| v.trim().parse::<usize>().ok())
        {
            body.resize(len, 0u8);
            if reader.read_exact(&mut body).is_err() {
                return Ok(()); // 半截请求体：连接已不可用
            }
        }

        let (path, query) = match target.split_once('?') {
            Some((p, q)) => (p.to_string(), q.to_string()),
            None => (target.clone(), String::new()),
        };
        let reply = dispatch(&svc, &method, &path, &query, &headers, &body);
        let summary = format!(
            "{method} {target}{} -> {}",
            headers
                .get("if-match")
                .map(|v| format!(" if-match={}", unquote(v)))
                .or_else(|| headers
                    .get("if-none-match")
                    .map(|v| format!(" if-none-match={}", v)))
                .unwrap_or_default(),
            reply.status
        );
        svc.log.lock().unwrap().push(summary);

        let keep_alive = write_reply(&mut stream, &method, reply)?;
        if !keep_alive {
            return Ok(());
        }
    }
}

/// 写响应；返回是否可继续复用本连接
///
/// 半截体（`truncate`）与停滞（`stall`）故意破坏连接语义，写完即关闭。
fn write_reply(stream: &mut TcpStream, method: &str, reply: Reply) -> std::io::Result<bool> {
    let declared = reply.body.len();
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: {declared}\r\nConnection: keep-alive\r\nContent-Type: text/plain; charset=utf-8\r\n",
        reply.status,
        reason(reply.status)
    );
    if let Some(etag) = &reply.etag {
        head.push_str(&format!("ETag: \"{etag}\"\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.flush()?;

    if reply.stall {
        std::thread::sleep(Duration::from_millis(1500));
        return Ok(false);
    }
    if !reply.head_only && method != "HEAD" {
        let written = if reply.truncate {
            declared / 2
        } else {
            declared
        };
        stream.write_all(&reply.body[..written])?;
        stream.flush()?;
        if reply.truncate {
            return Ok(false);
        }
    }
    Ok(true)
}

fn dispatch(
    svc: &Svc,
    method: &str,
    path: &str,
    query: &str,
    headers: &HashMap<String, String>,
    body: &[u8],
) -> Reply {
    let f = &svc.faults;
    let is_list = query.contains("list-type") || method == "PROPFIND";
    let data_plane = matches!(method, "GET" | "PUT" | "DELETE") && !is_list;

    if data_plane && f.take(&f.flaky) {
        return Reply::text(503, "Service Unavailable");
    }
    if data_plane && f.take(&f.rate_limited) {
        return match svc.protocol {
            Protocol::S3 => Reply::text(429, "<Error><Code>SlowDown</Code></Error>"),
            Protocol::WebDav => Reply::text(
                503,
                "<?xml version=\"1.0\"?><error>BlockedTemporarily</error>",
            ),
        };
    }
    if svc.protocol == Protocol::S3
        && data_plane
        && !headers
            .get("authorization")
            .map(|v| v.starts_with("AWS4-HMAC-SHA256 ") && v.contains("Signature="))
            .unwrap_or(false)
    {
        return Reply::text(
            403,
            "<Error><Code>AccessDenied</Code><Detail>missing SigV4 Authorization header</Detail></Error>",
        );
    }

    match method {
        "MKCOL" => Reply::text(201, ""),
        "PROPFIND" => propfind(
            svc,
            path,
            headers.get("depth").map(|s| s.as_str()).unwrap_or("1"),
        ),
        "DELETE" => {
            let mut st = svc.state.lock().unwrap();
            if st.objects.remove(path).is_some() {
                Reply::text(204, "")
            } else {
                not_found(svc)
            }
        }
        "PUT" => put(svc, path, headers, body),
        "GET" | "HEAD" => {
            if is_list {
                return list(svc, path, query);
            }
            let st = svc.state.lock().unwrap();
            match st.objects.get(path) {
                Some(o) => {
                    let mut r = Reply::new(200, o.bytes.clone());
                    r.etag = Some(o.etag.clone());
                    r.head_only = method == "HEAD";
                    r.stall = method == "GET" && f.take(&f.stall);
                    r.truncate = method == "GET" && f.take(&f.drop_mid_body);
                    r
                }
                None => not_found(svc),
            }
        }
        _ => Reply::text(405, "method not allowed"),
    }
}

fn not_found(svc: &Svc) -> Reply {
    match svc.protocol {
        Protocol::S3 => Reply::text(
            404,
            "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>",
        ),
        Protocol::WebDav => Reply::text(
            404,
            "<?xml version=\"1.0\"?><d:error xmlns:d=\"DAV:\"><S:status xmlns:S=\"http://apache.org/webdav/error\">404</S:status></d:error>",
        ),
    }
}

fn put(svc: &Svc, path: &str, headers: &HashMap<String, String>, body: &[u8]) -> Reply {
    let if_match = headers.get("if-match").map(|v| unquote(v).to_string());
    let if_absent = headers
        .get("if-none-match")
        .map(|v| v.trim() == "*")
        .unwrap_or(false);
    let conditional = if_match.is_some() || if_absent;

    let mut st = svc.state.lock().unwrap();
    if conditional && !svc.faults.ignore_conditional.load(Ordering::SeqCst) {
        let forced = svc.faults.take(&svc.faults.conflict);
        let stale = match (if_match.as_deref(), st.objects.get(path)) {
            (Some(want), Some(o)) => want != o.etag,
            (Some(_), None) => true,
            (None, Some(_)) => if_absent,
            (None, None) => false,
        };
        if stale || forced {
            return Reply::text(412, "precondition failed");
        }
    }
    st.seq += 1;
    let etag = format!("v{}", st.seq);
    let mtime = 1_700_000_000 + st.seq as i64;
    st.objects.insert(
        path.to_string(),
        Obj {
            bytes: body.to_vec(),
            etag: etag.clone(),
            mtime,
        },
    );
    let mut r = Reply::text(200, "");
    r.etag = Some(etag);
    r
}

fn rfc2822(secs: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(secs, 0)
        .map(|dt| dt.format("%a, %d %b %Y %H:%M:%S GMT").to_string())
        .unwrap_or_else(|| "Mon, 01 Jan 2024 00:00:00 GMT".to_string())
}

fn iso8601(secs: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(secs, 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%S.000Z").to_string())
        .unwrap_or_default()
}

/// S3 ListObjectsV2：按 `prefix` 查询参数做字面前缀匹配（与真 S3 同口径）
fn list(svc: &Svc, path: &str, query: &str) -> Reply {
    let params: HashMap<&str, &str> = query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .collect();
    let prefix = params.get("prefix").copied().unwrap_or("");
    let bucket_prefix = format!("{}/", path.trim_start_matches('/'));

    let st = svc.state.lock().unwrap();
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
    );
    xml.push_str(&format!(
        "<Name>{FAKE_BUCKET}</Name><Prefix>{prefix}</Prefix><IsTruncated>false</IsTruncated>"
    ));
    let mut matched: Vec<(&String, &Obj)> = st
        .objects
        .iter()
        .filter(|(key, _)| {
            key.strip_prefix(&bucket_prefix)
                .map(|obj_key| obj_key.starts_with(prefix))
                .unwrap_or(false)
        })
        .collect();
    matched.sort_by_key(|(key, _)| (*key).clone());
    let matched_count = matched.len();
    for (key, obj) in matched.iter() {
        let obj_key = key.strip_prefix(&bucket_prefix).unwrap_or(key);
        xml.push_str(&format!(
            "<Contents><Key>{}</Key><LastModified>{}</LastModified><ETag>\"{}\"</ETag><Size>{}</Size></Contents>",
            obj_key,
            iso8601(obj.mtime),
            obj.etag,
            obj.bytes.len()
        ));
    }
    xml.push_str(&format!(
        "<KeyCount>{}</KeyCount></ListBucketResult>",
        matched_count
    ));
    if svc.faults.take(&svc.faults.short_list) {
        let cut = xml.len() / 2;
        xml.truncate(cut);
    }
    Reply::new(200, xml.into_bytes())
}

/// WebDAV PROPFIND：由对象键反推目录树
fn propfind(svc: &Svc, path: &str, depth: &str) -> Reply {
    let dir = path.trim_end_matches('/');
    let st = svc.state.lock().unwrap();
    // 一级子项由对象键反推（目录不单独存标记）
    let children = |prefix: &str| -> Vec<(String, bool, usize, i64)> {
        let mut out: Vec<(String, bool, usize, i64)> = Vec::new();
        let needle = format!("{prefix}/");
        for (key, obj) in st.objects.iter() {
            let Some(rest) = key.strip_prefix(&needle) else {
                continue;
            };
            if let Some(sub) = rest.split_once('/').map(|(s, _)| s) {
                // 中间目录：同名只出一条
                let name = format!("{needle}{sub}");
                if out.iter().all(|(href, _, _, _)| *href != name) {
                    out.push((name, true, 0, obj.mtime));
                }
            } else {
                out.push((format!("{needle}{rest}"), false, obj.bytes.len(), obj.mtime));
            }
        }
        out.sort();
        out
    };

    let is_dir = st.objects.keys().any(|k| k.starts_with(&format!("{dir}/")));
    let self_obj = st.objects.get(path);
    if !is_dir && self_obj.is_none() {
        return not_found(svc);
    }

    let mut xml =
        String::from("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">");
    let push = |xml: &mut String, href: &str, is_collection: bool, size: usize, mtime: i64| {
        xml.push_str("<d:response><d:href>");
        xml.push_str(href);
        xml.push_str("</d:href><d:propstat><d:prop><d:resourcetype>");
        if is_collection {
            xml.push_str("<d:collection/>");
        }
        xml.push_str("</d:resourcetype>");
        if !is_collection {
            xml.push_str(&format!("<d:getcontentlength>{size}</d:getcontentlength>"));
        }
        xml.push_str(&format!(
            "<d:getlastmodified>{}</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
            rfc2822(mtime)
        ));
    };
    if is_dir {
        push(&mut xml, dir, true, 0, 1_700_000_000);
    } else if let Some(o) = self_obj {
        push(&mut xml, path, false, o.bytes.len(), o.mtime);
    }
    if depth != "0" && is_dir {
        for (href, is_collection, size, mtime) in children(dir) {
            push(&mut xml, &href, is_collection, size, mtime);
        }
    }
    xml.push_str("</d:multistatus>");
    if svc.faults.take(&svc.faults.short_list) {
        let cut = xml.len() / 2;
        xml.truncate(cut);
    }
    Reply::new(207, xml.into_bytes())
}
