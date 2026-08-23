use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// SHA-256 哈希，返回 hex 字符串
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    result.iter().map(|b| format!("{:02x}", b)).collect()
}

/// HMAC-SHA256，返回原始字节
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// AWS Signature V4 签名密钥派生
///
/// 与 Dart `S3SyncAdapter._getSignatureKey` 行为一致。
pub fn get_signature_key(
    secret_key: &str,
    date_stamp: &str,
    region: &str,
    service: &str,
) -> Vec<u8> {
    let k_date = hmac_sha256(
        format!("AWS4{}", secret_key).as_bytes(),
        date_stamp.as_bytes(),
    );
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

/// 格式化为 AMZ 日期：yyyyMMddTHHmmssZ
pub fn format_amz_date(date: &DateTime<Utc>) -> String {
    date.format("%Y%m%dT%H%M%SZ").to_string()
}

/// 格式化为日期戳：yyyyMMdd
pub fn format_date_stamp(date: &DateTime<Utc>) -> String {
    date.format("%Y%m%d").to_string()
}
