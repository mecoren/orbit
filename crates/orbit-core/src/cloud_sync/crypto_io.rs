//! crypto_io — 同步 payload 加密/解密包装
//!
//! 在 AES-256-GCM 原语之上封装"nonce 前置"的 payload 格式，
//! 供 Push/Pull/附件同步统一使用。所有云端数据（结构化 data.json/meta.json/_meta.json
//! 以及附件 media/<sha256>）均用同一 Data Key 加密。
//!
//! ## payload 格式
//! ```text
//! [magic(4)="WSZS")[version(1)=0x01][nonce(12)][ciphertext+tag(16)]
//! ```
//! 其中明文先经 zstd level=3 压缩再 AES-256-GCM 加密。
//! 几百 K JSON 压缩后通常 30-50K，传输时间从 ~1s 降至 ~50ms。
//!
//! 与 `sync_crypto::bundle_io` 和 `full_sync_backup::encoder` 的加密格式保持独立：
//! - 全量备份用 `.waitfullsync` 容器（含 magic header + 多文件 ZIP）
//! - 云端同步用本模块的 nonce 前置格式（裸 payload，适配 S3/WebDAV 直传）

use crate::cloud_sync::error::CloudSyncError;
use crate::crypto::aes_gcm::{aes_gcm_decrypt, aes_gcm_encrypt};
use crate::crypto::error::CryptoErrorKind;
use crate::crypto::random::random_bytes;

/// AES-GCM nonce 长度（字节）
const NONCE_LEN: usize = 12;

/// Data Key 长度（字节，32 = AES-256）
const DATA_KEY_LEN: usize = 32;

/// payload magic header：ASCII "WSZS"（Wait Sync Zstd）
const MAGIC_V2: &[u8; 4] = b"WSZS";

/// payload 版本号
const VERSION_V2: u8 = 0x01;

/// payload 头部总长度：magic(4) + version(1) = 5 字节
const V2_HEADER_LEN: usize = 5;

/// zstd 压缩级别（level=3：速度与压缩率平衡，100K JSON 压缩 < 5ms）
const ZSTD_LEVEL: i32 = 3;

/// 加密 payload（zstd 压缩 + AES-256-GCM 加密 + magic header 前置）
///
/// 输入：明文字节 + Data Key（32 字节）
/// 输出：`[magic(4)][version(1)][nonce(12)][ciphertext+tag]`
///
/// 性能：100K 明文压缩 + 加密 < 10ms；几百 K JSON 压缩率约 8-10 倍
pub fn encrypt_payload(plaintext: &[u8], data_key: &[u8]) -> Result<Vec<u8>, CloudSyncError> {
    validate_data_key(data_key)?;

    // 1. zstd 压缩明文（level=3，速度优先）
    //    空明文压缩后比原数据稍大（zstd 头开销），因此空数据跳过压缩
    let compressed: Vec<u8> = if plaintext.is_empty() {
        Vec::new()
    } else {
        zstd::encode_all(plaintext, ZSTD_LEVEL).map_err(|e| CloudSyncError::Crypto {
            message: format!("zstd 压缩失败: {}", e),
        })?
    };

    // 2. AES-256-GCM 加密（压缩后的明文）
    let nonce = random_bytes(NONCE_LEN);
    let ciphertext = aes_gcm_encrypt(data_key, &compressed, &nonce)?;

    // 3. 拼接 payload：magic + version + nonce + ciphertext
    let mut payload = Vec::with_capacity(V2_HEADER_LEN + NONCE_LEN + ciphertext.len());
    payload.extend_from_slice(MAGIC_V2);
    payload.push(VERSION_V2);
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&ciphertext);
    Ok(payload)
}

/// 解密 payload：分离 magic/version/nonce/ciphertext → AES 解密 → zstd 解压
///
/// 输入：`[magic(4)][version(1)][nonce(12)][ciphertext+tag]`
/// 输出：明文字节
pub fn decrypt_payload(payload: &[u8], data_key: &[u8]) -> Result<Vec<u8>, CloudSyncError> {
    validate_data_key(data_key)?;

    if payload.len() < V2_HEADER_LEN + NONCE_LEN {
        return Err(CloudSyncError::PayloadTooShort);
    }
    // 校验 magic header 与版本号，不匹配则视为格式错误
    if &payload[..4] != MAGIC_V2 || payload[4] != VERSION_V2 {
        return Err(CloudSyncError::Crypto {
            message: format!(
                "payload 格式不匹配：期望 magic={:?} version={}，实际 magic={:?} version={}",
                MAGIC_V2,
                VERSION_V2,
                &payload[..4.min(payload.len())],
                payload.get(4).copied().unwrap_or(0),
            ),
        });
    }

    let (header_and_nonce, ciphertext) = payload.split_at(V2_HEADER_LEN + NONCE_LEN);
    let nonce = &header_and_nonce[V2_HEADER_LEN..];
    let compressed = aes_gcm_decrypt(data_key, ciphertext, nonce).map_err(map_decrypt_error)?;

    // 空明文（压缩前）的特殊处理：压缩后为空 Vec
    if compressed.is_empty() {
        return Ok(Vec::new());
    }

    // zstd 解压
    let plaintext =
        zstd::decode_all(compressed.as_slice()).map_err(|e| CloudSyncError::Crypto {
            message: format!("zstd 解压失败: {}", e),
        })?;
    Ok(plaintext)
}

/// 校验 Data Key 长度
fn validate_data_key(data_key: &[u8]) -> Result<(), CloudSyncError> {
    if data_key.len() != DATA_KEY_LEN {
        return Err(CloudSyncError::Crypto {
            message: format!(
                "Data Key 长度必须为 {} 字节，实际 {} 字节",
                DATA_KEY_LEN,
                data_key.len()
            ),
        });
    }
    Ok(())
}

/// 将 AES-GCM 解密错误转换为 CloudSyncError
///
/// `DecryptionFailed` 表示 Data Key 与密文不匹配（本地 Data Key 与云端加密用的
/// Data Key 不一致），转为 `KeyMismatch` 让 UI 跳转恢复页（而非解锁页）。
///
/// 历史问题：原先映射为 `CryptoLocked`，UI 据此跳解锁页引导用户重输同步密码。
/// 但密码本身正确（本地 meta 与 sync_password 匹配），错的是 Data Key。
/// 重输密码会循环回同一错误，必须改走"以本机为准重加密重传"或"以云端为准放弃本地"
/// 的恢复流程。
///
/// 其他错误（如 key/nonce 长度异常）保持为 `Crypto { .. }`。
fn map_decrypt_error(e: crate::crypto::error::CryptoError) -> CloudSyncError {
    match e.kind {
        CryptoErrorKind::DecryptionFailed => {
            log::info!(
                "[decrypt_payload] AES-GCM 解密失败：Data Key 与云端密文不匹配，\
                 返回 KeyMismatch 引导 UI 走恢复流程（而非解锁页）"
            );
            CloudSyncError::KeyMismatch
        }
        _ => CloudSyncError::Crypto { message: e.message },
    }
}
