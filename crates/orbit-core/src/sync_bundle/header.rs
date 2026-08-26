use serde::{Deserialize, Serialize};

use super::error::SyncBundleError;

/// .waitsync 文件头大小（字节）
pub const HEADER_SIZE: usize = 52;
/// magic 值 "WSYN"（0x5753594E）
pub const MAGIC_VALUE: u32 = 0x5753594E;

/// 同步包模式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BundleMode {
    Full = 0x01,
    Incremental = 0x02,
    /// 合并快照（compaction 产物，替代多个历史 Full 包）
    Snapshot = 0x03,
}

impl BundleMode {
    pub fn from_value(v: u8) -> Result<BundleMode, SyncBundleError> {
        match v {
            0x01 => Ok(BundleMode::Full),
            0x02 => Ok(BundleMode::Incremental),
            0x03 => Ok(BundleMode::Snapshot),
            _ => Err(SyncBundleError {
                message: format!("Unknown BundleMode: 0x{:02X}", v),
            }),
        }
    }

    pub fn as_value(self) -> u8 {
        self as u8
    }
}

/// .waitsync 文件头结构
///
/// 字段偏移与 Dart `SyncBundleHeader` 完全一致：
/// 偏移  长度  字段
/// 0     4     magic (BE)
/// 4     2     version (BE)
/// 6     1     mode
/// 7     1     flags (bit0 = has_assets)
/// 8     8     created_at_ms (BE, Unix 毫秒)
/// 16    12    nonce
/// 28    16    gcm_tag
/// 44    8     payload_len (BE)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncBundleHeader {
    pub version: u16,
    pub mode: BundleMode,
    pub has_assets: bool,
    pub created_at_ms: i64,
    pub nonce: Vec<u8>,
    pub gcm_tag: Vec<u8>,
    pub payload_len: i64,
}

/// 序列化文件头为 52 字节
pub fn write_header(header: &SyncBundleHeader) -> Vec<u8> {
    let mut out = vec![0u8; HEADER_SIZE];
    // magic BE
    out[0..4].copy_from_slice(&MAGIC_VALUE.to_be_bytes());
    // version BE
    out[4..6].copy_from_slice(&header.version.to_be_bytes());
    // mode
    out[6] = header.mode.as_value();
    // flags
    out[7] = if header.has_assets { 1 } else { 0 };
    // created_at_ms BE
    out[8..16].copy_from_slice(&header.created_at_ms.to_be_bytes());
    // nonce (12 字节)
    out[16..28].copy_from_slice(&header.nonce);
    // gcm_tag (16 字节)
    out[28..44].copy_from_slice(&header.gcm_tag);
    // payload_len BE
    out[44..52].copy_from_slice(&header.payload_len.to_be_bytes());
    out
}

/// 从字节解析文件头
pub fn parse_header(data: &[u8]) -> Result<SyncBundleHeader, SyncBundleError> {
    if data.len() < HEADER_SIZE {
        return Err(SyncBundleError {
            message: format!(
                "Header too short: expected {} bytes, got {}",
                HEADER_SIZE,
                data.len()
            ),
        });
    }
    let magic = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
    if magic != MAGIC_VALUE {
        return Err(SyncBundleError {
            message: format!(
                "Invalid magic: expected 0x{:X}, got 0x{:X}",
                MAGIC_VALUE, magic
            ),
        });
    }
    let version = u16::from_be_bytes([data[4], data[5]]);
    let mode = BundleMode::from_value(data[6])?;
    let has_assets = (data[7] & 0x01) != 0;
    let created_at_ms = i64::from_be_bytes([
        data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15],
    ]);
    let nonce = data[16..28].to_vec();
    let gcm_tag = data[28..44].to_vec();
    let payload_len = i64::from_be_bytes([
        data[44], data[45], data[46], data[47], data[48], data[49], data[50], data[51],
    ]);
    Ok(SyncBundleHeader {
        version,
        mode,
        has_assets,
        created_at_ms,
        nonce,
        gcm_tag,
        payload_len,
    })
}
