pub mod http_client;
pub mod s3_adapter;
pub mod traits;
pub mod webdav_adapter;

pub use traits::{RemoteFile, SyncAdapter};

/// RFC 3986 unreserved 集路径编码（保留 `/`），**两协议共用**
///
/// 唯一实现在 `s3::url::uri_encode`（F51 为 S3 canonical URI 与请求 URL 建立的
/// 唯一编码点）。WebDAV 的路径编码规则与之一致，故此处只做**转发**而不是复制一份
/// ——两份实现迟早会在「哪些字符必须 `%XX`」上漂移，而那正是 F51/F61 的病灶。
pub(crate) use crate::s3::url::uri_encode;
