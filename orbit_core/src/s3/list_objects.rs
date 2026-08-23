use quick_xml::Reader;
use quick_xml::events::Event;

use super::error::S3Error;

/// S3 ListObjects/ListObjectsV2 解析结果：提取所有 Key 元素值
///
/// 与 Dart 侧 `S3SyncAdapter.listFiles` 中正则 `<Key>([^<]+)</Key>`
/// 提取行为一致，但使用 quick-xml 做结构化解析，更健壮。
pub fn parse_list_objects_xml(xml: &str, prefix: &str) -> Result<Vec<String>, S3Error> {
    let mut reader = Reader::from_str(xml);

    let mut in_key = false;
    let mut current_text = String::new();
    let mut keys = Vec::new();
    let mut buf = Vec::new();

    let prefix_with_slash = if prefix.is_empty() || prefix.ends_with('/') {
        prefix.to_string()
    } else {
        format!("{}/", prefix)
    };

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                if local_name(e.name().as_ref()) == "Key" {
                    in_key = true;
                    current_text.clear();
                } else {
                    in_key = false;
                }
            }
            Ok(Event::Text(e)) => {
                if in_key {
                    if let Ok(t) = e.unescape() {
                        current_text.push_str(&t);
                    }
                }
            }
            Ok(Event::End(e)) => {
                if local_name(e.name().as_ref()) == "Key" {
                    in_key = false;
                    let clean = if !prefix_with_slash.is_empty()
                        && current_text.starts_with(&prefix_with_slash)
                    {
                        current_text[prefix_with_slash.len()..].to_string()
                    } else {
                        current_text.clone()
                    };
                    keys.push(clean);
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(S3Error {
                    message: format!(
                        "XML parse error at position {}: {}",
                        reader.buffer_position(),
                        e
                    ),
                });
            }
            _ => {}
        }
        buf.clear();
    }

    Ok(keys)
}

/// 提取命名空间本地名（处理形如 "s3:Key" 的带命名空间元素）
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

    const SAMPLE_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>my-bucket</Name>
  <Prefix>sync/</Prefix>
  <KeyCount>3</KeyCount>
  <MaxKeys>1000</MaxKeys>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>sync/movies/abc123.json.enc</Key>
    <LastModified>2024-06-15T10:30:00.000Z</LastModified>
    <ETag>"d41d8cd98f00b204e9800998ecf8427e"</ETag>
    <Size>256</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>sync/books/def456.json.enc</Key>
    <LastModified>2024-06-16T08:15:00.000Z</LastModified>
    <ETag>"abc123"</ETag>
    <Size>128</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>sync/games/ghi789.json.enc</Key>
    <LastModified>2024-06-17T12:45:00.000Z</LastModified>
    <ETag>"xyz789"</ETag>
    <Size>512</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
</ListBucketResult>"#;

    #[test]
    fn test_parse_list_objects_with_prefix() {
        let keys = parse_list_objects_xml(SAMPLE_XML, "sync").unwrap();
        assert_eq!(keys.len(), 3);
        assert_eq!(keys[0], "movies/abc123.json.enc");
        assert_eq!(keys[1], "books/def456.json.enc");
        assert_eq!(keys[2], "games/ghi789.json.enc");
    }

    #[test]
    fn test_parse_list_objects_empty_prefix() {
        let keys = parse_list_objects_xml(SAMPLE_XML, "").unwrap();
        assert_eq!(keys.len(), 3);
        assert!(keys[0].starts_with("sync/"));
    }

    #[test]
    fn test_empty_result() {
        let xml = r#"<?xml version="1.0"?>
<ListBucketResult><Name>b</Name><Prefix>p/</Prefix><KeyCount>0</KeyCount></ListBucketResult>"#;
        let keys = parse_list_objects_xml(xml, "p").unwrap();
        assert!(keys.is_empty());
    }
}
