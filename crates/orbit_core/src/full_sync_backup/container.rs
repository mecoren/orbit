//! container — .waitfullsync 二进制容器读写
//!
//! 文件格式（共 36 字节头部 + 变长密文）：
//! ```text
//! 偏移  长度  字段              说明
//! 0     4     magic             "WFS1"（Wait Full Sync v1）
//! 4     16    salt              PBKDF2 盐（每次备份随机生成）
//! 20    12    nonce             AES-GCM nonce（每次备份随机生成）
//! 32    4     iterations        PBKDF2 迭代次数（BE u32，当前为 200000）
//! 36    变长  ciphertext        AES-256-GCM 密文 + 末尾 16B GCM tag
//! ```

use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};

/// .waitfullsync 文件头大小（字节）
pub const HEADER_SIZE: usize = 36;

/// magic 值 "WFS1"
pub const MAGIC: [u8; 4] = *b"WFS1";

/// PBKDF2 迭代次数（与 sync_crypto::service::ITERATIONS 一致）
pub const ITERATIONS: u32 = 200_000;

/// Salt 长度（字节）
pub const SALT_LEN: usize = 16;

/// Nonce 长度（字节）
pub const NONCE_LEN: usize = 12;

/// 解析后的 .waitfullsync 文件头
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FullSyncHeader {
    pub salt: [u8; SALT_LEN],
    pub nonce: [u8; NONCE_LEN],
    pub iterations: u32,
}

/// 拼接完整的 .waitfullsync 字节流
///
/// 输入：salt(16B) + nonce(12B) + iterations + ciphertext（含末尾 16B GCM tag）
/// 输出：[magic(4B)][salt(16B)][nonce(12B)][iterations BE u32(4B)][ciphertext]
pub fn build_container(header: &FullSyncHeader, ciphertext: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_SIZE + ciphertext.len());
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&header.salt);
    out.extend_from_slice(&header.nonce);
    out.extend_from_slice(&header.iterations.to_be_bytes());
    out.extend_from_slice(ciphertext);
    out
}

/// 从字节流解析文件头与密文
///
/// 校验 magic 与长度，返回 (header, ciphertext)
pub fn parse_container(data: &[u8]) -> FullSyncBackupResult<(FullSyncHeader, &[u8])> {
    if data.len() < HEADER_SIZE {
        return Err(FullSyncBackupError::HeaderTooShort {
            expected: HEADER_SIZE,
            actual: data.len(),
        });
    }

    let magic = [data[0], data[1], data[2], data[3]];
    if magic != MAGIC {
        return Err(FullSyncBackupError::MagicMismatch {
            expected: MAGIC,
            got: magic,
        });
    }

    let mut salt = [0u8; SALT_LEN];
    salt.copy_from_slice(&data[4..20]);
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&data[20..32]);
    let iterations = u32::from_be_bytes([data[32], data[33], data[34], data[35]]);

    let ciphertext = &data[HEADER_SIZE..];

    Ok((
        FullSyncHeader {
            salt,
            nonce,
            iterations,
        },
        ciphertext,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_then_parse_roundtrip() {
        let header = FullSyncHeader {
            salt: [1u8; SALT_LEN],
            nonce: [2u8; NONCE_LEN],
            iterations: 200_000,
        };
        let ciphertext = vec![3u8; 100];

        let container = build_container(&header, &ciphertext);
        assert_eq!(container.len(), HEADER_SIZE + 100);

        let (parsed_header, parsed_ct) = parse_container(&container).unwrap();
        assert_eq!(parsed_header, header);
        assert_eq!(parsed_ct, ciphertext.as_slice());
    }

    #[test]
    fn parse_rejects_too_short_data() {
        let short_data = vec![0u8; HEADER_SIZE - 1];
        let result = parse_container(&short_data);
        assert!(matches!(
            result,
            Err(FullSyncBackupError::HeaderTooShort { expected, actual })
            if expected == HEADER_SIZE && actual == HEADER_SIZE - 1
        ));
    }

    #[test]
    fn parse_rejects_invalid_magic() {
        let mut bad = vec![0u8; HEADER_SIZE + 10];
        bad[0..4].copy_from_slice(b"XXXX");
        let result = parse_container(&bad);
        assert!(matches!(
            result,
            Err(FullSyncBackupError::MagicMismatch { .. })
        ));
    }

    #[test]
    fn parse_accepts_empty_ciphertext() {
        let header = FullSyncHeader {
            salt: [0u8; SALT_LEN],
            nonce: [0u8; NONCE_LEN],
            iterations: 1,
        };
        let container = build_container(&header, &[]);
        let (parsed_header, parsed_ct) = parse_container(&container).unwrap();
        assert_eq!(parsed_header, header);
        assert!(parsed_ct.is_empty());
    }

    #[test]
    fn iterations_encoded_as_big_endian() {
        let header = FullSyncHeader {
            salt: [0u8; SALT_LEN],
            nonce: [0u8; NONCE_LEN],
            iterations: 0x12345678,
        };
        let container = build_container(&header, &[]);
        // 检查字节序：BE
        assert_eq!(&container[32..36], &[0x12, 0x34, 0x56, 0x78]);
    }
}
