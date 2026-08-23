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
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let local = local_name(e.name().as_ref());
                if local == "response" {
                    current_entry = Some(WebDavFileEntry {
                        href: String::new(),
                        display_name: None,
                        content_length: None,
                        is_collection: false,
                        last_modified: None,
                    });
                }
                current_text.clear();
            }
            Ok(Event::Text(e)) => {
                if let Ok(t) = e.unescape() {
                    current_text.push_str(&t);
                }
            }
            Ok(Event::End(e)) => {
                let local = local_name(e.name().as_ref());
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
