use quick_xml::Reader;
use quick_xml::events::Event;

use super::error::S3Error;

/// S3 ListObjectsV2 解析结果：对象条目列表 + 分页游标
///
/// Key 剥离 `{prefix}/` 前缀（与调用方 base_path 对齐），
/// `next_token` 为响应中的 `NextContinuationToken`（`IsTruncated=true` 时存在，
/// 作为下一页 `continuation-token` 查询参数，None 表示最后一页）。
#[derive(Debug, Default, PartialEq)]
pub struct ListPage {
    pub entries: Vec<ListEntry>,
    pub next_token: Option<String>,
}

/// 单个对象条目（`<Contents>`）
///
/// `size`/`last_modified` 响应里本来就有，此前只取 Key 把它们丢了——
/// 云端备份列表按 `last_modified` 倒序排序，S3 上因此退化成 key 字典序
/// （文件名内嵌日期 → 实际是「最旧在前」，与 WebDAV 端相反）。
#[derive(Debug, Default, Clone, PartialEq)]
pub struct ListEntry {
    /// 剥离 `{prefix}/` 后的对象 Key
    pub key: String,
    /// `<Size>`：对象字节数，缺失记 0
    pub size: u64,
    /// `<LastModified>`：Unix 秒（与 `RemoteFile::last_modified` 同口径），
    /// 非 RFC3339（部分兼容服务回 `+0800` 偏移）按 0 处理
    pub last_modified: i64,
    /// `<ETag>`：并发令牌（剥引号/弱校验前缀，F26），缺失为 None
    pub etag: Option<String>,
}

/// 正在采集文本的 XML 元素（同一时刻至多一个）
#[derive(Debug, Clone, Copy, PartialEq)]
enum Field {
    None,
    Key,
    Size,
    LastModified,
    Etag,
    Token,
}

fn field_of(local: &str) -> Field {
    match local {
        "Key" => Field::Key,
        "Size" => Field::Size,
        "LastModified" => Field::LastModified,
        "ETag" => Field::Etag,
        "NextContinuationToken" => Field::Token,
        _ => Field::None,
    }
}

/// 解析 S3 ListObjectsV2 XML 响应单页
///
/// 与 Dart 侧 `S3SyncAdapter.listFiles` 中正则 `<Key>([^<]+)</Key>`
/// 提取行为一致，但使用 quick-xml 做结构化解析，更健壮。
/// 同时提取 `<NextContinuationToken>`（分页续传游标，P0-3）、
/// `<Size>`/`<LastModified>`（备份列表排序键，F27）与 `<ETag>`（并发令牌，F26）。
pub fn parse_list_objects_xml(xml: &str, prefix: &str) -> Result<ListPage, S3Error> {
    let mut reader = Reader::from_str(xml);

    let mut field = Field::None;
    let mut text = String::new();
    let mut cur = ListEntry::default();
    let mut entries = Vec::new();
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
                if local == "Contents" {
                    cur = ListEntry::default();
                    field = Field::None;
                } else {
                    field = field_of(&local);
                }
                text.clear();
            }
            Ok(Event::Text(e)) => {
                if field != Field::None
                    && let Ok(t) = e.unescape()
                {
                    text.push_str(&t);
                }
            }
            Ok(Event::End(e)) => {
                let local = local_name(e.name().as_ref());
                match field_of(&local) {
                    Field::Key => {
                        let raw = text.trim();
                        cur.key = raw
                            .strip_prefix(prefix_with_slash.as_str())
                            .unwrap_or(raw)
                            .to_string();
                    }
                    Field::Size => {
                        cur.size = text.trim().parse().unwrap_or(0);
                    }
                    Field::LastModified => {
                        cur.last_modified = chrono::DateTime::parse_from_rfc3339(text.trim())
                            .map(|dt| dt.timestamp())
                            .unwrap_or(0);
                    }
                    Field::Etag => {
                        cur.etag = crate::sync_adapters::traits::normalize_etag(&text);
                    }
                    Field::Token => {
                        next_token = Some(text.trim().to_string());
                    }
                    Field::None => {
                        // `<Contents>` 收尾：一个 Contents 一条目
                        if local == "Contents" && !cur.key.is_empty() {
                            entries.push(std::mem::take(&mut cur));
                        }
                    }
                }
                field = Field::None;
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

    Ok(ListPage {
        entries,
        next_token,
    })
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
        let keys: Vec<&str> = page.entries.iter().map(|e| e.key.as_str()).collect();
        assert_eq!(
            keys,
            vec![
                "movies/abc123.json.enc",
                "books/def456.json.enc",
                "games/ghi789.json.enc"
            ]
        );
        // IsTruncated=false → 无游标
        assert!(page.next_token.is_none());
    }

    /// F27：`<Size>`/`<LastModified>` 必须解析出来（备份列表倒序排序键）
    #[test]
    fn test_parse_extracts_size_and_last_modified() {
        let page = parse_list_objects_xml(SAMPLE_XML, "sync").unwrap();
        assert_eq!(page.entries[0].size, 256);
        assert_eq!(page.entries[1].size, 128);
        assert_eq!(
            page.entries[0].last_modified,
            chrono::DateTime::parse_from_rfc3339("2024-06-15T10:30:00.000Z")
                .unwrap()
                .timestamp()
        );
        // 排序键彼此可区分——全 0 会让稳定排序退化成 key 字典序
        assert!(page.entries[0].last_modified < page.entries[2].last_modified);
        // 非 RFC3339 的时间戳（部分兼容服务的怪格式）按 0 处理，不得整轮失败
        let odd = SAMPLE_XML.replace("2024-06-15T10:30:00.000Z", "2024-06-15 10:30:00");
        let page = parse_list_objects_xml(&odd, "sync").unwrap();
        assert_eq!(page.entries[0].last_modified, 0);
        assert_eq!(page.entries[0].size, 256, "时间格式异常不得牵连其它字段");
    }

    /// F26：`<ETag>` 必须解析并剥引号（列举侧与条件写共用同一令牌口径）
    #[test]
    fn test_parse_extracts_normalized_etag() {
        let page = parse_list_objects_xml(SAMPLE_XML, "sync").unwrap();
        assert_eq!(
            page.entries[0].etag.as_deref(),
            Some("d41d8cd98f00b204e9800998ecf8427e")
        );
        assert_eq!(page.entries[1].etag.as_deref(), Some("abc123"));
        // 缺 ETag 的条目（部分兼容服务不回）不得牵连其它字段
        let no_etag = SAMPLE_XML.replace("<ETag>\"abc123\"</ETag>", "");
        let page = parse_list_objects_xml(&no_etag, "sync").unwrap();
        assert_eq!(page.entries[1].etag, None);
        assert_eq!(page.entries[1].size, 128);
    }

    #[test]
    fn test_parse_list_objects_empty_prefix() {
        let page = parse_list_objects_xml(SAMPLE_XML, "").unwrap();
        assert_eq!(page.entries.len(), 3);
        assert!(page.entries[0].key.starts_with("sync/"));
    }

    #[test]
    fn test_empty_result() {
        let xml = r#"<?xml version="1.0"?>
<ListBucketResult><Name>b</Name><Prefix>p/</Prefix><KeyCount>0</KeyCount></ListBucketResult>"#;
        let page = parse_list_objects_xml(xml, "p").unwrap();
        assert!(page.entries.is_empty());
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
        assert_eq!(page.entries[0].key, "a.orsync");
        assert_eq!(
            page.next_token.as_deref(),
            Some("1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J2mDAiLvXgggg")
        );
    }
}
