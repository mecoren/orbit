use quick_xml::Reader;
use quick_xml::events::Event;

use super::error::WebDavError;

/// WebDAV PROPFIND 解析出的文件条目
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebDavFileEntry {
    pub href: String,
    pub display_name: Option<String>,
    pub content_length: Option<i64>,
    pub is_collection: bool,
    /// RFC 2822 格式的最后修改时间字符串（如 "Mon, 10 Jul 2026 12:00:00 GMT"）
    pub last_modified: Option<String>,
}

/// 解析 PROPFIND multistatus XML 响应
///
/// 与 Dart `WebDavSyncAdapter` 的正则解析行为对齐，
/// 但使用 quick-xml 提供更健壮的命名空间处理。
pub fn parse_propfind_response(xml: &str) -> Result<Vec<WebDavFileEntry>, WebDavError> {
    let mut reader = Reader::from_str(xml);

    let mut entries = Vec::new();
    let mut current_entry: Option<WebDavFileEntry> = None;
    let mut current_text = String::new();
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
                        current_entry = Some(WebDavFileEntry {
                            href: String::new(),
                            display_name: None,
                            content_length: None,
                            is_collection: false,
                            last_modified: None,
                        });
                    }
                    // RFC 4918 标准：resourcetype 内的 <collection/> 空元素标记目录。
                    // 主流服务器（Nextcloud/群晖/坚果云/wsgidav）均只报标准形态；
                    // 微软私有的 <iscollection>1</iscollection> 在 End 事件另行处理。
                    "collection" if in_resourcetype => {
                        if let Some(entry) = current_entry.as_mut() {
                            entry.is_collection = true;
                        }
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
                    if let Some(entry) = current_entry.as_mut() {
                        entry.is_collection = true;
                    }
                }
            }
            Ok(Event::Text(e)) => {
                if let Ok(t) = e.unescape() {
                    current_text.push_str(&t);
                }
            }
            Ok(Event::End(e)) => {
                let local = local_name(e.name().as_ref());
                if local == "resourcetype" {
                    in_resourcetype = false;
                }
                if let Some(entry) = current_entry.as_mut() {
                    match local.as_str() {
                        "href" => entry.href = current_text.clone(),
                        "displayname" => entry.display_name = Some(current_text.clone()),
                        "getcontentlength" => {
                            entry.content_length = current_text.trim().parse::<i64>().ok();
                        }
                        "getlastmodified" => {
                            entry.last_modified = Some(current_text.trim().to_string());
                        }
                        "iscollection" => {
                            entry.is_collection = current_text.trim() == "1";
                        }
                        "response" => {
                            if let Some(e) = current_entry.take() {
                                entries.push(e);
                            }
                        }
                        _ => {}
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
    <d:href>/dav/wait-home/_meta.waitsync</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>_meta.waitsync</d:displayname>
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
        assert_eq!(entries[2].href, "/dav/wait-home/_meta.waitsync");
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
}
