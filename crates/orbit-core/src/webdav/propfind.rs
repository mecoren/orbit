use quick_xml::Reader;
use quick_xml::events::Event;

use super::error::WebDavError;

/// WebDAV PROPFIND 解析出的文件条目
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebDavFileEntry {
    pub href: String,
    pub display_name: Option<String>,
    pub content_length: Option<i64>,
    pub is_collection: bool,
    /// RFC 2822 格式的最后修改时间字符串（如 "Mon, 10 Jul 2026 12:00:00 GMT"）
    pub last_modified: Option<String>,
    /// 并发令牌（ETag，服务端可能带引号，解析时剥掉）
    ///
    /// F26（2026-09-19 第五轮探查）：请求体不申请 `<d:getetag/>` 时服务端不回，
    /// 列举侧就永远拿不到并发令牌；条件写（CAS）虽走 GET 的 `get_with_token`，
    /// 但列举与条件写的令牌必须同源，否则「列举看到的版本」与「CAS 比对的版本」
    /// 是两次独立快照。
    pub etag: Option<String>,
}

/// 解析 PROPFIND multistatus XML 响应
///
/// 与 Dart `WebDavAdapter` 的正则解析行为对齐，
/// 但使用 quick-xml 提供更健壮的命名空间处理。
///
/// F31：属性按**所属 propstat 的状态码**取舍。RFC 4918 的 `<status>` 描述的是
/// 同一 `<propstat>` 内全部属性的拉取结果，服务器对不支持的属性会另发一条
/// 404 propstat（Nextcloud 对目录的 getcontentlength 即如此）——历史实现把整条
/// `<response>` 的属性混收，于是「属性拉取失败」的条目照样进列表（时间戳 0），
/// 而资源本身 404 的条目也进列表，令 `url_exists` 对 207 恒真。
/// 现规则：只合并 2xx（或缺省 status）propstat 的属性；一条 response 的
/// propstat 全部非 2xx → 整条剔除（调用方据此判定资源不存在）。
pub fn parse_propfind_response(xml: &str) -> Result<Vec<WebDavFileEntry>, WebDavError> {
    let mut reader = Reader::from_str(xml);

    let mut entries = Vec::new();
    let mut current_entry: Option<WebDavFileEntry> = None;
    let mut current_text = String::new();
    // propstat 内的属性先缓冲到这里——`<status>` 出现在属性**之后**，
    // 只能等 propstat 收尾再决定合并还是丢弃。
    let mut props = WebDavFileEntry::default();
    // props 里是否真的收过属性（区分「无 propstat 包装的服务器」与
    // 「404 propstat 被丢弃后留下的空缓冲」）
    let mut props_dirty = false;
    // 本条 response 是否合并过至少一个可用 propstat
    let mut merged = false;
    let mut in_propstat = false;
    let mut propstat_status: Option<u16> = None;
    // resourcetype 是空元素对（<D:resourcetype><D:collection/></D:resourcetype>），
    // 不产生文本事件，须在 Start 事件识别 `collection` 子元素置位（RFC 4918 标准）。
    // 追踪当前是否位于 resourcetype 元素内部（含命名空间前缀与裸元素两种形态）。
    let mut in_resourcetype = false;
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let local = local_name(e.name().as_ref());
                match local.as_str() {
                    "response" => {
                        current_entry = Some(WebDavFileEntry::default());
                        props = WebDavFileEntry::default();
                        props_dirty = false;
                        merged = false;
                    }
                    "propstat" => {
                        in_propstat = true;
                        propstat_status = None;
                        props = WebDavFileEntry::default();
                        props_dirty = false;
                    }
                    // RFC 4918 标准：resourcetype 内的 <collection/> 空元素标记目录。
                    // 主流服务器（Nextcloud/群晖/坚果云/wsgidav）均只报标准形态；
                    // 微软私有的 <iscollection>1</iscollection> 在 End 事件另行处理。
                    "collection" if in_resourcetype => {
                        props.is_collection = true;
                        props_dirty = true;
                    }
                    _ => {}
                }
                in_resourcetype = local == "resourcetype" || in_resourcetype;
                current_text.clear();
            }
            Ok(Event::Empty(e)) => {
                // <D:collection/> 可能以自闭合空元素出现（部分服务器序列化风格）
                let local = local_name(e.name().as_ref());
                if local == "collection" && in_resourcetype {
                    props.is_collection = true;
                    props_dirty = true;
                }
            }
            Ok(Event::Text(e)) => {
                if let Ok(t) = e.unescape() {
                    current_text.push_str(&t);
                }
            }
            Ok(Event::End(e)) => {
                let local = local_name(e.name().as_ref());
                match local.as_str() {
                    "resourcetype" => in_resourcetype = false,
                    "status" => {
                        if in_propstat {
                            propstat_status = status_code(&current_text);
                        }
                    }
                    "propstat" => {
                        // status 缺省的服务器（不报错也不带状态码）按可用处理：
                        // 属性既然被回出来，就是服务器认为该给的值
                        let usable = propstat_status.is_none_or(|c| (200..=299).contains(&c));
                        if usable {
                            if let Some(entry) = current_entry.as_mut() {
                                merge_props(entry, std::mem::take(&mut props));
                            }
                            merged = true;
                        }
                        props = WebDavFileEntry::default();
                        props_dirty = false;
                        in_propstat = false;
                        propstat_status = None;
                    }
                    _ => {
                        if let Some(entry) = current_entry.as_mut() {
                            match local.as_str() {
                                // href 挂在 response 直属层，不属于任何 propstat，
                                // 因此不受属性状态码取舍影响
                                "href" => entry.href = decode_href(&current_text),
                                "displayname" => {
                                    props.display_name = Some(current_text.clone());
                                    props_dirty = true;
                                }
                                "getcontentlength" => {
                                    props.content_length = current_text.trim().parse::<i64>().ok();
                                    props_dirty = true;
                                }
                                "getlastmodified" => {
                                    props.last_modified = Some(current_text.trim().to_string());
                                    props_dirty = true;
                                }
                                "getetag" => {
                                    props.etag = normalize_etag(&current_text);
                                    props_dirty = true;
                                }
                                "iscollection" => {
                                    props.is_collection = current_text.trim() == "1";
                                    props_dirty = true;
                                }
                                "response" => {
                                    // 无 propstat 包装的属性（非规范服务器）按可用落地
                                    if props_dirty {
                                        merge_props(entry, std::mem::take(&mut props));
                                        merged = true;
                                    }
                                    props = WebDavFileEntry::default();
                                    props_dirty = false;
                                    if merged && !entry.href.is_empty() {
                                        // take 走并复位：current_entry 此处被借用，
                                        // 不能再调 current_entry.take()
                                        entries.push(std::mem::take(entry));
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                }
                current_text.clear();
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(WebDavError {
                    message: format!("xml parse error: {}", e),
                });
            }
            _ => {}
        }
        buf.clear();
    }
    Ok(entries)
}

/// 把 propstat 缓冲的属性并入条目：只补缺失字段，不被后到的 404 propstat 覆盖
fn merge_props(entry: &mut WebDavFileEntry, src: WebDavFileEntry) {
    if entry.href.is_empty() {
        entry.href = src.href;
    }
    if entry.display_name.is_none() {
        entry.display_name = src.display_name;
    }
    if entry.content_length.is_none() {
        entry.content_length = src.content_length;
    }
    if entry.last_modified.is_none() {
        entry.last_modified = src.last_modified;
    }
    if entry.etag.is_none() {
        entry.etag = src.etag;
    }
    entry.is_collection |= src.is_collection;
}

/// 归一化 ETag（口径与 S3 列举侧共用，见 `sync_adapters::traits::normalize_etag`）
fn normalize_etag(raw: &str) -> Option<String> {
    crate::sync_adapters::traits::normalize_etag(raw)
}

/// 从状态行 "HTTP/1.1 404 Not Found" 取状态码
fn status_code(line: &str) -> Option<u16> {
    line.split_whitespace().find_map(|t| t.parse::<u16>().ok())
}

/// href 百分号解码（F30）
///
/// RFC 4918 规定 href 是 URI 路径，服务端会对中文、空格、`#` 等做百分号编码
/// （坚果云/Nextcloud 均如此）。历史实现只做 XML 实体反转义，编码段原样保留，
/// 而下游把 href 的末段直接当文件名/附件 hash 用 → 备份列表与列举结果出现
/// `%E4%B8%AD%E6%96%87` 形态的乱码名。
/// 非法转义序列（个别服务器私有条形）回退原文：解码失败不得丢条目。
fn decode_href(raw: &str) -> String {
    let trimmed = raw.trim();
    urlencoding::decode(trimmed)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| trimmed.to_string())
}

/// 提取命名空间本地名（DAV: 命名空间的元素名形如 "D:href"）
fn local_name(name: &[u8]) -> String {
    let s = std::str::from_utf8(name).unwrap_or("");
    if let Some(idx) = s.find(':') {
        s[idx + 1..].to_string()
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 4918 标准形态：Nextcloud/群晖/坚果云等主流服务器返回
    /// `<D:resourcetype><D:collection/></D:resourcetype>` 空元素对
    /// （不产生文本事件）。P0-1 修复前该形态 is_collection 恒 false，
    /// 目录条目混入文件列表且 basename 退化为整条 URL。
    const STANDARD_XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/wait-home/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>wait-home</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/wait-home/modules/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>modules</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/wait-home/_meta.orsync</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>_meta.orsync</d:displayname>
        <d:resourcetype/>
        <d:getcontentlength>1024</d:getcontentlength>
        <d:getlastmodified>Mon, 07 Sep 2026 12:00:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"#;

    #[test]
    fn standard_resourcetype_marks_collection() {
        let entries = parse_propfind_response(STANDARD_XML).unwrap();
        assert_eq!(entries.len(), 3);
        // 两个目录条目（尾斜杠 href）都被识别为 collection
        assert!(entries[0].is_collection, "根目录必须是 collection");
        assert!(entries[1].is_collection, "子目录必须是 collection");
        // 文件条目不是 collection
        assert!(!entries[2].is_collection);
        assert_eq!(entries[2].href, "/dav/wait-home/_meta.orsync");
        assert_eq!(entries[2].content_length, Some(1024));
    }

    #[test]
    fn self_closing_collection_empty_element_also_marks_collection() {
        // 部分服务器把 <collection/> 序列化为自闭合空元素（Event::Empty）
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/dir/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/file.txt</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries[0].is_collection);
        assert!(!entries[1].is_collection);
    }

    #[test]
    fn microsoft_iscollection_still_supported() {
        // 微软私有扩展 <iscollection>1</iscollection> 走文本路径，保持兼容
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/dir/</D:href>
    <D:propstat><D:prop>
      <D:iscollection>1</D:iscollection>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/file.bin</D:href>
    <D:propstat><D:prop>
      <D:iscollection>0</D:iscollection>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert!(entries[0].is_collection);
        assert!(!entries[1].is_collection);
    }

    #[test]
    fn collection_flag_does_not_leak_across_entries() {
        // resourcetype 状态在 response 边界必须复位：
        // 第一个条目是目录、第二个文件未报 resourcetype——
        // 若 in_resourcetype 泄漏，文件会误继承目录标记
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/dir/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/file.bin</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>10</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert!(entries[0].is_collection);
        assert!(!entries[1].is_collection, "文件不得继承上一条目的目录标记");
    }

    #[test]
    fn no_namespace_prefix_form_also_parsed() {
        // 无命名空间前缀的裸元素形态（部分轻量服务器如 wsgidav）
        let xml = r#"<?xml version="1.0"?>
<multistatus>
  <response>
    <href>/dir/</href>
    <propstat><prop>
      <resourcetype><collection/></resourcetype>
    </prop></propstat>
  </response>
</multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 1);
        assert!(entries[0].is_collection);
        assert_eq!(entries[0].href, "/dir/");
    }

    /// F30：href 是 URI 路径，中文/空格须百分号解码后才能当文件名用
    #[test]
    fn href_is_percent_decoded() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/wait-home/backups/%E5%B7%A5%E4%BD%9C%20%E7%AC%94%E8%AE%B0.orfullsync</D:href>
    <D:propstat><D:prop><D:getcontentlength>9</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/wait-home/broken-%zz.orsync</D:href>
    <D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(
            entries[0].href, "/dav/wait-home/backups/工作 笔记.orfullsync",
            "编码段必须还原成真实文件名"
        );
        assert_eq!(
            entries[1].href, "/dav/wait-home/broken-%zz.orsync",
            "非法转义回退原文，不得丢条目"
        );
    }

    /// F31：资源级 404 的 response 不得进列表（url_exists 靠「有条目」判存在）
    #[test]
    fn entry_with_only_failed_propstat_is_dropped() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/wait-home/ghost.orsync</D:href>
    <D:propstat>
      <D:prop><D:resourcetype/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/wait-home/real.orsync</D:href>
    <D:propstat>
      <D:prop><D:getcontentlength>7</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 1, "全 404 的条目要整条剔除");
        assert_eq!(entries[0].href, "/dav/wait-home/real.orsync");
    }

    /// F26：getetag 解析并归一化（剥引号 / 弱校验前缀）
    #[test]
    fn getetag_is_parsed_and_normalized() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/wait-home/_meta.orsync</D:href>
    <D:propstat><D:prop>
      <D:getetag>"etag-abc"</D:getetag>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/wait-home/weak.orsync</D:href>
    <D:propstat><D:prop>
      <D:getetag>W/"weak-1"</D:getetag>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/wait-home/no-etag.orsync</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>3</D:getcontentlength>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].etag.as_deref(), Some("etag-abc"), "引号必须剥掉");
        assert_eq!(entries[1].etag.as_deref(), Some("weak-1"));
        assert_eq!(entries[2].etag, None, "服务端不回 getetag 即无令牌");
    }

    /// F31：部分属性失败（404 propstat）不得污染同条目已成功的属性
    #[test]
    fn failed_propstat_does_not_override_good_props() {
        // Nextcloud 对目录回 getcontentlength 404、其余属性 200 的常见形态
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/wait-home/sub/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Mon, 07 Sep 2026 12:00:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop><D:getcontentlength></D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_response(xml).unwrap();
        assert_eq!(entries.len(), 1, "有 2xx propstat 的条目必须保留");
        assert!(entries[0].is_collection);
        assert_eq!(
            entries[0].last_modified.as_deref(),
            Some("Mon, 07 Sep 2026 12:00:00 GMT")
        );
        assert_eq!(
            entries[0].content_length, None,
            "404 propstat 的属性不得落地"
        );
    }
}
