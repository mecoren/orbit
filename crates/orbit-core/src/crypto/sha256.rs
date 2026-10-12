use sha2::{Digest, Sha256};

/// SHA-256 哈希，返回 hex 字符串
///
/// 与 `s3::signing::sha256_hex` 实现一致，
/// 提供通用密码学入口（不绑定 S3 语义）。
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    result.iter().map(|b| format!("{:02x}", b)).collect()
}

/// 校验是否为合法 sha256 hex 摘要（64 位小写十六进制）
///
/// 附件内容寻址链路的入口纵深防御：hash 会直接作为本地文件名
/// （`{attachments_dir}/{hash}`）与云端对象键使用，格式非法意味着
/// 内容寻址假设被破坏或输入被篡改（路径分隔符、超长、非 hex 等形态）。
/// 内容正确性仍由下载侧 `sha256(decrypted) == hash` 背书校验兜底，
/// 本函数负责在使用 hash 前先拦格式（N51，2026-10-12）。
pub fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_empty_string() {
        // RFC 6234 test vector
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn sha256_abc() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn is_sha256_hex_accepts_canonical_digest() {
        assert!(is_sha256_hex(&sha256_hex(b"abc")));
    }

    #[test]
    fn is_sha256_hex_rejects_malformed() {
        let digest = sha256_hex(b"abc");
        // 大写 hex 不合法（sha256_hex 只产小写）
        assert!(!is_sha256_hex(&digest.to_uppercase()));
        // 长度不足 / 超长
        assert!(!is_sha256_hex(&digest[..63]));
        assert!(!is_sha256_hex(&format!("{}0", digest)));
        // 非 hex 字符
        assert!(!is_sha256_hex(&digest.replace('a', "g")));
        // 路径分隔符注入等 N51 关心的形态
        assert!(!is_sha256_hex("../../etc/passwd"));
        assert!(!is_sha256_hex(""));
    }
}
