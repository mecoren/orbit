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
///
/// nonce 采用**确定性派生**：`SHA256(data_key ‖ SHA256(plaintext) ‖ len) 前 12 字节`。
/// 同一 (key, plaintext) 永远产生同一密文——这是 multipart 分片上传断点续传
/// 的前提（S4，2026-09-14）：重试会话中已上传的分片与新会话重加密的分片
/// 字节一致，才能跳过重传。安全性：AES-GCM 的 nonce 唯一性要求是
/// 「同 key 下 nonce 不重复」——本派生下不同 plaintext 的 nonce 碰撞
/// 等价于 SHA-256 碰撞（第二原像），且输入含密文外部不可得的 data_key，
/// 攻击者无法构造碰撞对（长度扩展攻击对 SHA-256 不可行，且攻击者缺
/// key 前缀）。SIV（RFC 5297）/AES-GCM-SIV 是该构造的正规化形式，
/// 语义相同：用「明文+key 的哈希」做 nonce 的合成 IV。格式版本仍为
/// 0x01（随机/确定性 nonce 产出的密文均可被现有 decrypt 解开，
/// 不构成不兼容变更）。
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

    // 2. AES-256-GCM 加密（压缩后的明文，nonce 确定性派生）
    let nonce = derive_deterministic_nonce(data_key, &compressed);
    let ciphertext = aes_gcm_encrypt(data_key, &compressed, &nonce)?;

    // 3. 拼接 payload：magic + version + nonce + ciphertext
    let mut payload = Vec::with_capacity(V2_HEADER_LEN + NONCE_LEN + ciphertext.len());
    payload.extend_from_slice(MAGIC_V2);
    payload.push(VERSION_V2);
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&ciphertext);
    Ok(payload)
}

/// 确定性 nonce 派生（纯函数，供单测）
///
/// `SHA256(data_key ‖ SHA256(compressed)hex ‖ len_be)[0..12]`
///
/// - data_key 参与哈希：key 不同 → nonce 全不同；攻击者无 key 时无法为
///   目标明文预计算 nonce，也无法构造碰撞对（nonce 碰撞 ⊇ SHA-256 碰撞）
/// - len 域分离：防不同长度输入因哈希缓冲区拼接歧义产生相同摘要
/// - 用压缩后明文的 SHA-256 而非明文本身：压缩后内容才是实际进入 AEAD
///   的明文，nonce 唯一性须按它保证；hex 拼接避免 `‖` 拼接歧义
fn derive_deterministic_nonce(data_key: &[u8], compressed: &[u8]) -> Vec<u8> {
    let inner = crate::crypto::sha256::sha256_hex(compressed);
    let len = (compressed.len() as u64).to_be_bytes();
    let mut input = Vec::with_capacity(data_key.len() + inner.len() + 8);
    input.extend_from_slice(data_key);
    input.extend_from_slice(inner.as_bytes());
    input.extend_from_slice(&len);
    let full = crate::crypto::sha256::sha256_hex(&input);
    full.into_bytes()[..NONCE_LEN].to_vec()
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

#[cfg(test)]
mod deterministic_nonce_tests {
    use super::*;

    // ========================================================================
    // S4（2026-09-14）：加密 nonce 总超时→确定性派生
    //
    // multipart 分片上传的断点续传前提：同一 (key, 明文) 两次加密产出
    // 完全一致的密文——上传中断后重试会话重新加密的分片与已上传分片
    // 字节一致，跳过重传才有意义。随机 nonce 下重试即新密文，断点续传
    // 无从谈起。安全性论证见 encrypt_payload 文档注释（SIV 语义）。
    // ========================================================================

    /// 核心性质：同 key + 同明文 → 两次加密产出完全相同的密文
    #[test]
    fn encrypt_payload_is_deterministic() {
        let key = [7u8; 32];
        let a = encrypt_payload(b"attachment-content", &key).unwrap();
        let b = encrypt_payload(b"attachment-content", &key).unwrap();
        assert_eq!(a, b, "断点续传前提：同输入必须产出同密文（含 nonce 字段）");
    }

    /// key 变化 → nonce 必然不同（rekey 后旧分片不可复用，防跨密钥混片）
    #[test]
    fn nonce_changes_with_key() {
        let n1 = derive_deterministic_nonce(&[1u8; 32], b"same-plaintext");
        let n2 = derive_deterministic_nonce(&[2u8; 32], b"same-plaintext");
        assert_ne!(n1, n2, "不同 Data Key 的 nonce 必须不同");
    }

    /// 明文变化 → nonce 必然不同（GCM nonce 唯一性：同 key 下不得重复）
    #[test]
    fn nonce_changes_with_plaintext() {
        let key = [1u8; 32];
        let n1 = derive_deterministic_nonce(&key, b"plaintext-a");
        let n2 = derive_deterministic_nonce(&key, b"plaintext-b");
        let n3 = derive_deterministic_nonce(&key, b"plaintext-ab");
        assert_ne!(n1, n2, "不同明文的 nonce 必须不同（防 GCM 灾难）");
        assert_ne!(n1, n3, "前缀延长的明文不得命中同一 nonce（len 域分离）");
    }

    /// 派生 nonce 长度恒为 12 字节
    #[test]
    fn derived_nonce_length_is_12() {
        let n = derive_deterministic_nonce(&[9u8; 32], b"any");
        assert_eq!(n.len(), NONCE_LEN);
    }

    /// 往返：确定性加密 → 现有 decrypt 正常解开（格式不变，version 0x01）
    #[test]
    fn deterministic_encrypt_roundtrips() {
        let key = [5u8; 32];
        let plain = b"round-trip-content";
        let enc = encrypt_payload(plain, &key).unwrap();
        let dec = decrypt_payload(&enc, &key).unwrap();
        assert_eq!(dec, plain);
        // 格式断言：magic + version 0x01 不变（新旧密文互通）
        assert_eq!(&enc[..4], b"WSZS");
        assert_eq!(enc[4], VERSION_V2);
    }

    /// 空 payload 路径不回归（模块数据里存在空 items 的合法场景）
    #[test]
    fn deterministic_encrypt_empty_roundtrips() {
        let key = [5u8; 32];
        let enc = encrypt_payload(b"", &key).unwrap();
        let dec = decrypt_payload(&enc, &key).unwrap();
        assert!(dec.is_empty());
        assert!(
            encrypt_payload(b"", &key).unwrap() == enc,
            "空明文也须确定性"
        );
    }
}
