use quick_xml::Reader;
use quick_xml::events::Event;

use super::error::S3Error;

/// S3 ListObjectsV2 解析结果：对象 Key 列表 + 分页游标
///
/// Key 剥离 `{prefix}/` 前缀（与调用方 base_path 对齐），
/// `next_token` 为响应中的 `NextContinuationToken`（`IsTruncated=true` 时存在，
/// 作为下一页 `continuation-token` 查询参数，None 表示最后一页）。
#[derive(Debug, Default, PartialEq)]
pub struct ListPage {
    pub keys: Vec<String>,
    pub next_token: Option<String>,
}

/// 解析 S3 ListObjectsV2 XML 响应单页
///
/// 与 Dart 侧 `S3SyncAdapter.listFiles` 中正则 `<Key>([^<]+)</Key>`
/// 提取行为一致，但使用 quick-xml 做结构化解析，更健壮。
/// 同时提取 `<NextContinuationToken>`（分页续传游标，P0-3）。
pub fn parse_list_objects_xml(xml: &str, prefix: &str) -> Result<ListPage, S3Error> {
    let mut reader = Reader::from_str(xml);

    let mut in_key = false;
    let mut in_token = false;
    let mut current_text = String::new();
    let mut keys = Vec::new();
    let mut next_token: Option<String> = None;
    let mut buf = Vec::new();

    let prefix_with_slash = if prefix.is_empty() || prefix.ends_with('/') {
        prefix.to_string()
    } else {
        format!("{}/", prefix)
    };

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let local = local_name(e.name().as_ref());
                match local.as_str() {
                    "Key" => {
                        in_key = true;
                        current_text.clear();
                    }
                    "NextContinuationToken" => {
                        in_token = true;
                        current_text.clear();
                    }
                    _ => {
                        in_key = false;
                        in_token = false;
                    }
                }
            }
            Ok(Event::Text(e)) => {
                if (in_key || in_token)
                    && let Ok(t) = e.unescape()
                {
                    current_text.push_str(&t);
                }
            }
            Ok(Event::End(e)) => {
                let local = local_name(e.name().as_ref());
                match local.as_str() {
                    "Key" => {
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
                    "NextContinuationToken" => {
                        in_token = false;
                        next_token = Some(current_text.clone());
                    }
                    _ => {}
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

    Ok(ListPage { keys, next_token })
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
        let page = parse_list_objects_xml(SAMPLE_XML, "sync").unwrap();
        assert_eq!(page.keys.len(), 3);
        assert_eq!(page.keys[0], "movies/abc123.json.enc");
        assert_eq!(page.keys[1], "books/def456.json.enc");
        assert_eq!(page.keys[2], "games/ghi789.json.enc");
        // IsTruncated=false → 无游标
        assert!(page.next_token.is_none());
    }

    #[test]
    fn test_parse_list_objects_empty_prefix() {
        let page = parse_list_objects_xml(SAMPLE_XML, "").unwrap();
        assert_eq!(page.keys.len(), 3);
        assert!(page.keys[0].starts_with("sync/"));
    }

    #[test]
    fn test_empty_result() {
        let xml = r#"<?xml version="1.0"?>
<ListBucketResult><Name>b</Name><Prefix>p/</Prefix><KeyCount>0</KeyCount></ListBucketResult>"#;
        let page = parse_list_objects_xml(xml, "p").unwrap();
        assert!(page.keys.is_empty());
        assert!(page.next_token.is_none());
    }

    #[test]
    fn test_truncated_page_extracts_next_token() {
        // P0-3：IsTruncated=true 时必须提取 NextContinuationToken 供分页续传，
        // 否则 >1000 对象静默截断（pull 拉不到、push 误判云端缺文件）
        let xml = r#"<?xml version="1.0"?>
<ListBucketResult>
  <Name>b</Name><Prefix>sync/</Prefix><KeyCount>1</KeyCount>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J2mDAiLvXgggg</NextContinuationToken>
  <Contents><Key>sync/a.orsync</Key></Contents>
</ListBucketResult>"#;
        let page = parse_list_objects_xml(xml, "sync").unwrap();
        assert_eq!(page.keys, vec!["a.orsync"]);
        assert_eq!(
            page.next_token.as_deref(),
            Some("1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J2mDAiLvXgggg")
        );
    }
}
