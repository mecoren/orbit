//! asset_container — 附件云端容器（分块 AES-256-GCM，docs/13 §6.2 M3 / T1.1）
//!
//! 存量附件对象是 [`crate::cloud_sync::crypto_io::encrypt_payload`] 产出的
//! 整包 `OSZS` 载荷（zstd 压缩 + 单次 AES-GCM）——加密时必须持有整份明文与
//! 密文，50MB 附件因此稳定多出上百 MB 峰值。本模块提供的 `OSAC` 容器按
//! 4MiB 定长帧逐块加密/解密，**任何时刻内存只有一帧明文 + 一帧密文**，
//! 峰值与附件大小解耦。
//!
//! ## 文件布局
//!
//! ```text
//! [magic "OSAC" 4B][version 1B][chunk_plain BE u32 4B]
//! [total_plain BE u64 8B][chunk_count BE u32 4B][nonce_base 12B]
//! 重复 chunk_count 次：
//!   [seq BE u64 8B][ct_len BE u32 4B][ciphertext+tag 变长]
//! ```
//!
//! 头部不加密：只含解密所需的公开参数（帧大小/明文长度/nonce 基值），不含
//! 业务内容。帧数与明文长度一起写进头部，读侧据此**先校验再分配**，防伪造
//! 超大长度把内存打爆。
//!
//! ## nonce 派生与确定性
//!
//! `nonce_base = SHA256(data_key ‖ object_id ‖ "orbit-asset-container-v1")[0..12]`，
//! 每帧 nonce = `nonce_base` 的后 8 字节与帧序号异或。`object_id` 取附件
//! 的明文 sha256（即云端对象键），因此**同 key + 同内容 ⇒ 同容器字节**：
//! 重试/多设备重加密不会产生不同密文，内容寻址对象的幂等性得以保留。
//!
//! 帧序号同时进 AAD（`magic ‖ version ‖ seq ‖ total_plain`）：删帧、换序、
//! 跨对象拼接都会让 GCM tag 校验失败；截断则由「帧数/总长」与末尾整体
//! `sha256(明文) == object_id` 双重兜住。
//!
//! ## 与存量格式的关系
//!
//! - 新写一律 `OSAC`；
//! - 读侧按首 4 字节区分：`OSAC` 走本模块流式解密，其余走
//!   `decrypt_payload`（整包路径，旧对象仍可读）；
//! - 旧客户端读到 `OSAC` 会报「payload 格式不匹配」——属预期，与 ADR 0011
//!   的备份格式升级同口径，发布说明需标注。

use std::io::{Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::cloud_sync::error::CloudSyncError;

/// 容器 magic（ASCII "OSAC" = Orbit Sync Asset Container）
pub const MAGIC: [u8; 4] = *b"OSAC";

/// 容器版本：分块帧 + 确定性 nonce
pub const VERSION: u8 = 0x01;

/// 单帧明文上限（4 MiB）
///
/// 与备份 v2 的 `FRAME_PLAIN_MAX` 同档：一帧即一次加解密的粒度，4MiB 让
/// 「单帧驻留」的成本可控（往返加解密共约 8MiB 峰值），同时避免帧数过多。
pub const CHUNK_PLAIN_BYTES: usize = 4 * 1024 * 1024;

/// 读侧允许的帧明文上限（防伪造头部让读侧分配超大缓冲）
pub const MAX_CHUNK_PLAIN_BYTES: u32 = 16 * 1024 * 1024;

/// 单附件明文的硬上限（与 `asset_api::MAX_ATTACHMENT_BYTES` 同量级，
/// 这里再留一档余量；仅作防御，产品侧 50MB 限制在 asset_api）
pub const MAX_PLAINTEXT_BYTES: u64 = 512 * 1024 * 1024;

/// 头部固定长度：magic(4) + version(1) + chunk_plain(4) + total_plain(8)
/// + chunk_count(4) + nonce_base(12)
pub const HEADER_LEN: usize = 4 + 1 + 4 + 8 + 4 + 12;

/// AES-GCM tag 长度
const TAG_LEN: usize = 16;

/// 帧头长度：seq(8) + ct_len(4)
const FRAME_HEADER_LEN: usize = 12;

/// 加密结果：调用方据此声明上传长度与校验落库大小
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncryptedContainer {
    /// 明文（本地附件）字节数
    pub plaintext_bytes: u64,
    /// 容器（云端对象）字节数
    pub container_bytes: u64,
    /// 帧数
    pub chunk_count: u32,
}

/// 判断字节流是否为本模块容器（读侧分流用）
pub fn is_container(prefix: &[u8]) -> bool {
    prefix.len() >= MAGIC.len() && prefix[..MAGIC.len()] == MAGIC
}

/// 从文件读取首 4 字节判断容器形态（文件不存在/过短返回 false）
pub fn is_container_file(path: &Path) -> bool {
    let mut buf = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut buf))
        .map(|_| is_container(&buf))
        .unwrap_or(false)
}

/// 流式加密：`src` 明文 → `dst` 容器（分块 AES-256-GCM）
///
/// 峰值 = 一帧明文（≤4MiB）+ 一帧密文（≤4MiB+16B）。失败时删除 `dst`，
/// 不留半截容器（半截对象会被读侧按「帧数不足」拒绝，但仍应清理）。
pub fn encrypt_file_to_container(
    src: &Path,
    dst: &Path,
    data_key: &[u8],
    object_id: &str,
) -> Result<EncryptedContainer, CloudSyncError> {
    validate_key(data_key)?;
    let plaintext_bytes = std::fs::metadata(src)
        .map_err(|e| attachment_io("读取待加密附件元数据失败", e))?
        .len();
    if plaintext_bytes > MAX_PLAINTEXT_BYTES {
        return Err(CloudSyncError::Attachment {
            message: format!(
                "附件超过容器上限 {}MB（实际 {} 字节）",
                MAX_PLAINTEXT_BYTES / 1024 / 1024,
                plaintext_bytes
            ),
        });
    }
    let chunk_count = plaintext_bytes.div_ceil(CHUNK_PLAIN_BYTES as u64) as u32;
    let nonce_base = derive_nonce_base(data_key, object_id);

    let result = (|| -> Result<u64, CloudSyncError> {
        let mut reader =
            std::fs::File::open(src).map_err(|e| attachment_io("打开待加密附件失败", e))?;
        let mut writer =
            std::fs::File::create(dst).map_err(|e| attachment_io("创建附件容器临时文件失败", e))?;

        let header = Header {
            chunk_plain: CHUNK_PLAIN_BYTES as u32,
            total_plain: plaintext_bytes,
            chunk_count,
            nonce_base,
        };
        writer
            .write_all(&header.to_bytes())
            .map_err(|e| attachment_io("写入附件容器头失败", e))?;
        let mut written = HEADER_LEN as u64;

        let mut remaining = plaintext_bytes;
        let mut buf = vec![0u8; CHUNK_PLAIN_BYTES];
        for seq in 0..chunk_count as u64 {
            let plain_len = remaining.min(CHUNK_PLAIN_BYTES as u64) as usize;
            reader
                .read_exact(&mut buf[..plain_len])
                .map_err(|e| attachment_io("读取附件明文中途失败（文件可能被修改）", e))?;
            let nonce = frame_nonce(&nonce_base, seq);
            let aad = frame_aad(seq, plaintext_bytes);
            let ciphertext = crate::crypto::aes_gcm::aes_gcm_encrypt_aad(
                data_key,
                &buf[..plain_len],
                &nonce,
                &aad,
            )?;

            writer
                .write_all(&seq.to_be_bytes())
                .and_then(|_| writer.write_all(&(ciphertext.len() as u32).to_be_bytes()))
                .and_then(|_| writer.write_all(&ciphertext))
                .map_err(|e| attachment_io("写入附件容器帧失败", e))?;
            written += (FRAME_HEADER_LEN + ciphertext.len()) as u64;
            remaining -= plain_len as u64;
        }
        debug_assert_eq!(remaining, 0, "循环结束时明文必须恰好读完");
        writer
            .flush()
            .map_err(|e| attachment_io("刷新附件容器失败", e))?;
        Ok(written)
    })();

    match result {
        Ok(container_bytes) => Ok(EncryptedContainer {
            plaintext_bytes,
            container_bytes,
            chunk_count,
        }),
        Err(e) => {
            let _ = std::fs::remove_file(dst);
            Err(e)
        }
    }
}

/// 流式解密：`src` 容器 → `dst` 明文（逐帧校验 + 末尾整体 sha256 校验）
///
/// `expected_hash` 是内容寻址键（明文 sha256）。返回明文字节数。
/// 任一步校验失败都删除 `dst`：调用方拿到 `Err` 时磁盘上不会留下
/// 「看起来完整」的损坏附件。
pub fn decrypt_container_to_file(
    src: &Path,
    dst: &Path,
    data_key: &[u8],
    expected_hash: &str,
) -> Result<u64, CloudSyncError> {
    validate_key(data_key)?;
    let result = decrypt_inner(src, dst, data_key, expected_hash);
    if result.is_err() {
        let _ = std::fs::remove_file(dst);
    }
    result
}

fn decrypt_inner(
    src: &Path,
    dst: &Path,
    data_key: &[u8],
    expected_hash: &str,
) -> Result<u64, CloudSyncError> {
    let mut reader = std::fs::File::open(src).map_err(|e| attachment_io("打开附件容器失败", e))?;
    let mut raw_header = [0u8; HEADER_LEN];
    reader.read_exact(&mut raw_header).map_err(|e| {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            CloudSyncError::Attachment {
                message: "附件容器过短，无法读取头部".to_string(),
            }
        } else {
            attachment_io("读取附件容器头失败", e)
        }
    })?;
    let header = Header::from_bytes(&raw_header)?;

    let mut writer =
        std::fs::File::create(dst).map_err(|e| attachment_io("创建附件临时明文失败", e))?;
    let mut hasher = Sha256::new();
    let mut written: u64 = 0;
    let mut remaining = header.total_plain;

    for expected_seq in 0..header.chunk_count as u64 {
        let mut frame_header = [0u8; FRAME_HEADER_LEN];
        reader.read_exact(&mut frame_header).map_err(|e| {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                CloudSyncError::Attachment {
                    message: format!(
                        "附件容器被截断：声明 {} 帧，实际在第 {} 帧结束",
                        header.chunk_count, expected_seq
                    ),
                }
            } else {
                attachment_io("读取附件容器帧头失败", e)
            }
        })?;
        let seq = u64::from_be_bytes(frame_header[..8].try_into().expect("帧头前 8 字节必为 u64"));
        if seq != expected_seq {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器帧序错误：期望第 {} 帧，实际 {}（疑似重排/拼接）",
                    expected_seq, seq
                ),
            });
        }
        let ct_len =
            u32::from_be_bytes(frame_header[8..].try_into().expect("帧头后 4 字节必为 u32"))
                as usize;
        let plain_len = remaining.min(header.chunk_plain as u64) as usize;
        if ct_len != plain_len + TAG_LEN {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器帧长度非法：第 {} 帧期望 {} 字节，实际 {}",
                    seq,
                    plain_len + TAG_LEN,
                    ct_len
                ),
            });
        }

        let mut ciphertext = vec![0u8; ct_len];
        reader.read_exact(&mut ciphertext).map_err(|e| {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                CloudSyncError::Attachment {
                    message: format!(
                        "附件容器被截断：第 {} 帧数据不完整（期望 {} 字节）",
                        seq, ct_len
                    ),
                }
            } else {
                attachment_io("读取附件容器帧失败", e)
            }
        })?;
        let nonce = frame_nonce(&header.nonce_base, seq);
        let aad = frame_aad(seq, header.total_plain);
        let plaintext =
            crate::crypto::aes_gcm::aes_gcm_decrypt_aad(data_key, &ciphertext, &nonce, &aad)?;

        writer
            .write_all(&plaintext)
            .map_err(|e| attachment_io("写入附件临时明文失败", e))?;
        hasher.update(&plaintext);
        written += plaintext.len() as u64;
        remaining -= plaintext.len() as u64;
    }

    // 尾部多余字节：说明容器被追加了别的内容，按损坏拒绝（不静默忽略）
    let mut probe = [0u8; 1];
    match reader.read(&mut probe) {
        Ok(0) => {}
        Ok(_) => {
            return Err(CloudSyncError::Attachment {
                message: "附件容器尾部存在多余数据（疑似拼接损坏）".to_string(),
            });
        }
        Err(e) => return Err(attachment_io("读取附件容器尾部失败", e)),
    }
    if remaining != 0 || written != header.total_plain {
        return Err(CloudSyncError::Attachment {
            message: format!(
                "附件容器明文长度不符：声明 {}，实际 {}",
                header.total_plain, written
            ),
        });
    }

    let actual: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    if !crate::crypto::sha256::constant_time_eq(&actual, expected_hash) {
        return Err(CloudSyncError::Attachment {
            message: format!(
                "附件内容哈希校验失败（期望 {}，实际 {}），疑似传输损坏，已丢弃",
                expected_hash, actual
            ),
        });
    }

    writer
        .flush()
        .map_err(|e| attachment_io("刷新附件临时明文失败", e))?;
    Ok(written)
}

// ============================================================================
// 头部 / nonce / AAD
// ============================================================================

#[derive(Debug, Clone, Copy)]
struct Header {
    chunk_plain: u32,
    total_plain: u64,
    chunk_count: u32,
    nonce_base: [u8; 12],
}

impl Header {
    fn to_bytes(self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[..4].copy_from_slice(&MAGIC);
        out[4] = VERSION;
        out[5..9].copy_from_slice(&self.chunk_plain.to_be_bytes());
        out[9..17].copy_from_slice(&self.total_plain.to_be_bytes());
        out[17..21].copy_from_slice(&self.chunk_count.to_be_bytes());
        out[21..33].copy_from_slice(&self.nonce_base);
        out
    }

    fn from_bytes(raw: &[u8; HEADER_LEN]) -> Result<Self, CloudSyncError> {
        if !is_container(raw) {
            return Err(CloudSyncError::Crypto {
                message: format!(
                    "附件容器 magic 不匹配：期望 {:?}，实际 {:?}",
                    MAGIC,
                    &raw[..4]
                ),
            });
        }
        let version = raw[4];
        if version > VERSION {
            return Err(CloudSyncError::PayloadVersionMismatch {
                message: format!(
                    "附件容器版本 {:#04x} 高于本客户端支持的上限 {:#04x}，请升级应用后重试（云端数据未损坏）",
                    version, VERSION
                ),
            });
        }
        if version < VERSION {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器版本过旧或已损坏：version={:#04x}（本客户端支持 {:#04x}）",
                    version, VERSION
                ),
            });
        }
        let chunk_plain = u32::from_be_bytes(raw[5..9].try_into().expect("4 字节"));
        let total_plain = u64::from_be_bytes(raw[9..17].try_into().expect("8 字节"));
        let chunk_count = u32::from_be_bytes(raw[17..21].try_into().expect("4 字节"));
        let mut nonce_base = [0u8; 12];
        nonce_base.copy_from_slice(&raw[21..33]);

        if chunk_plain == 0 || chunk_plain > MAX_CHUNK_PLAIN_BYTES {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器帧大小非法：{}（允许 1..={}）",
                    chunk_plain, MAX_CHUNK_PLAIN_BYTES
                ),
            });
        }
        if total_plain > MAX_PLAINTEXT_BYTES {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器声明明文 {} 字节，超过上限 {} 字节",
                    total_plain, MAX_PLAINTEXT_BYTES
                ),
            });
        }
        let expected_count = total_plain.div_ceil(chunk_plain as u64);
        if chunk_count as u64 != expected_count {
            return Err(CloudSyncError::Attachment {
                message: format!(
                    "附件容器帧数非法：声明 {} 帧，按明文长度应为 {} 帧",
                    chunk_count, expected_count
                ),
            });
        }
        Ok(Self {
            chunk_plain,
            total_plain,
            chunk_count,
            nonce_base,
        })
    }
}

/// 确定性 nonce 基值：`SHA256(data_key ‖ object_id ‖ domain)[0..12]`
///
/// `object_id` 即附件明文 hash，同内容同 key 必得同一容器字节（重试/多设备
/// 重加密幂等）。用 hex 字符串前 12 字节与存量 payload 同口径（48-bit 有效
/// 熵，附件量级下够用；见 `crypto_io::derive_deterministic_nonce` 的口径澄清）。
fn derive_nonce_base(data_key: &[u8], object_id: &str) -> [u8; 12] {
    let mut input = Vec::with_capacity(data_key.len() + object_id.len() + 26);
    input.extend_from_slice(data_key);
    input.extend_from_slice(object_id.as_bytes());
    input.extend_from_slice(b"orbit-asset-container-v1");
    let full = crate::crypto::sha256::sha256_hex(&input);
    full.into_bytes()[..12].try_into().expect("12 字节固定长度")
}

/// 帧 nonce：基值后 8 字节与帧序号异或（序号唯一 ⇒ nonce 唯一）
fn frame_nonce(base: &[u8; 12], seq: u64) -> [u8; 12] {
    let mut nonce = *base;
    let seq_bytes = seq.to_be_bytes();
    for i in 0..8 {
        nonce[4 + i] ^= seq_bytes[i];
    }
    nonce
}

/// 帧 AAD：magic + version + 帧序号 + 明文总长（防重排/截断/跨对象拼接）
fn frame_aad(seq: u64, total_plain: u64) -> Vec<u8> {
    let mut aad = Vec::with_capacity(4 + 1 + 8 + 8);
    aad.extend_from_slice(&MAGIC);
    aad.push(VERSION);
    aad.extend_from_slice(&seq.to_be_bytes());
    aad.extend_from_slice(&total_plain.to_be_bytes());
    aad
}

fn validate_key(data_key: &[u8]) -> Result<(), CloudSyncError> {
    if data_key.len() != 32 {
        return Err(CloudSyncError::Crypto {
            message: format!("Data Key 长度必须为 32 字节，实际 {} 字节", data_key.len()),
        });
    }
    Ok(())
}

fn attachment_io(context: &str, err: std::io::Error) -> CloudSyncError {
    CloudSyncError::Attachment {
        message: format!("{context}: {err}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> tempfile::TempDir {
        tempfile::TempDir::new().unwrap()
    }

    fn write_src(dir: &Path, name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn roundtrip(bytes: &[u8]) {
        let dir = tmp();
        let src = write_src(dir.path(), "src.bin", bytes);
        let container = dir.path().join("c.bin");
        let out = dir.path().join("out.bin");
        let key = [7u8; 32];
        let hash = crate::crypto::sha256::sha256_hex(bytes);

        let info = encrypt_file_to_container(&src, &container, &key, &hash).unwrap();
        assert_eq!(info.plaintext_bytes, bytes.len() as u64);
        assert_eq!(
            info.container_bytes,
            std::fs::metadata(&container).unwrap().len()
        );
        assert!(is_container_file(&container));

        let n = decrypt_container_to_file(&container, &out, &key, &hash).unwrap();
        assert_eq!(n, bytes.len() as u64);
        assert_eq!(std::fs::read(&out).unwrap(), bytes);
    }

    #[test]
    fn roundtrip_empty_attachment() {
        roundtrip(b"");
    }

    #[test]
    fn roundtrip_exact_and_cross_chunk_boundaries() {
        roundtrip(b"small-payload");
        // 恰好一帧 / 一帧多 1 字节 / 两帧整
        roundtrip(&vec![1u8; CHUNK_PLAIN_BYTES]);
        roundtrip(&vec![2u8; CHUNK_PLAIN_BYTES + 1]);
        roundtrip(&vec![3u8; CHUNK_PLAIN_BYTES * 2]);
    }

    #[test]
    fn encryption_is_deterministic_for_same_key_and_content() {
        let dir = tmp();
        let bytes = vec![9u8; 4096];
        let src = write_src(dir.path(), "src.bin", &bytes);
        let hash = crate::crypto::sha256::sha256_hex(&bytes);
        let a = dir.path().join("a.bin");
        let b = dir.path().join("b.bin");
        encrypt_file_to_container(&src, &a, &[3u8; 32], &hash).unwrap();
        encrypt_file_to_container(&src, &b, &[3u8; 32], &hash).unwrap();
        assert_eq!(
            std::fs::read(&a).unwrap(),
            std::fs::read(&b).unwrap(),
            "同 key + 同内容必须产出同容器字节（断点续传/多设备幂等前提）"
        );

        // 不同 key / 不同 object_id → 密文不同（防跨对象 nonce 复用）
        let c = dir.path().join("c.bin");
        encrypt_file_to_container(&src, &c, &[4u8; 32], &hash).unwrap();
        assert_ne!(std::fs::read(&a).unwrap(), std::fs::read(&c).unwrap());
        let d = dir.path().join("d.bin");
        let other_id = crate::crypto::sha256::sha256_hex(b"other");
        encrypt_file_to_container(&src, &d, &[3u8; 32], &other_id).unwrap();
        assert_ne!(std::fs::read(&a).unwrap(), std::fs::read(&d).unwrap());
    }

    #[test]
    fn tampered_frame_is_rejected_and_partial_output_removed() {
        let dir = tmp();
        let bytes = vec![5u8; 8192];
        let src = write_src(dir.path(), "src.bin", &bytes);
        let hash = crate::crypto::sha256::sha256_hex(&bytes);
        let container = dir.path().join("c.bin");
        encrypt_file_to_container(&src, &container, &[1u8; 32], &hash).unwrap();

        let mut raw = std::fs::read(&container).unwrap();
        let last = raw.len() - 1;
        raw[last] ^= 0x01;
        std::fs::write(&container, &raw).unwrap();

        let out = dir.path().join("out.bin");
        let err = decrypt_container_to_file(&container, &out, &[1u8; 32], &hash).unwrap_err();
        assert!(
            matches!(err, CloudSyncError::Crypto { .. }),
            "实际: {err:?}"
        );
        assert!(!out.exists(), "失败时不得留下半截明文");
    }

    #[test]
    fn truncated_container_is_rejected() {
        let dir = tmp();
        let bytes = vec![6u8; CHUNK_PLAIN_BYTES + 100];
        let src = write_src(dir.path(), "src.bin", &bytes);
        let hash = crate::crypto::sha256::sha256_hex(&bytes);
        let container = dir.path().join("c.bin");
        encrypt_file_to_container(&src, &container, &[1u8; 32], &hash).unwrap();

        // 裁掉最后一帧的一半：帧数声明仍在，read_exact 应报截断
        let mut raw = std::fs::read(&container).unwrap();
        let cut = raw.len() - 10;
        raw.truncate(cut);
        std::fs::write(&container, &raw).unwrap();

        let out = dir.path().join("out.bin");
        let err = decrypt_container_to_file(&container, &out, &[1u8; 32], &hash).unwrap_err();
        assert!(err.to_string().contains("截断"), "实际: {err}");
        assert!(!out.exists());
    }

    #[test]
    fn wrong_hash_is_rejected_after_full_decrypt() {
        // 容器本身完好但对象键与明文不符：末尾整体校验必须拒绝
        let dir = tmp();
        let bytes = b"honest-content".to_vec();
        let src = write_src(dir.path(), "src.bin", &bytes);
        let hash = crate::crypto::sha256::sha256_hex(&bytes);
        let container = dir.path().join("c.bin");
        encrypt_file_to_container(&src, &container, &[1u8; 32], &hash).unwrap();

        let out = dir.path().join("out.bin");
        let wrong = crate::crypto::sha256::sha256_hex(b"another-content");
        let err = decrypt_container_to_file(&container, &out, &[1u8; 32], &wrong).unwrap_err();
        assert!(err.to_string().contains("哈希校验失败"), "实际: {err}");
        assert!(!out.exists());
    }

    #[test]
    fn future_version_is_reported_as_upgrade_not_key_error() {
        let dir = tmp();
        let src = write_src(dir.path(), "src.bin", b"x");
        let hash = crate::crypto::sha256::sha256_hex(b"x");
        let container = dir.path().join("c.bin");
        encrypt_file_to_container(&src, &container, &[1u8; 32], &hash).unwrap();
        let mut raw = std::fs::read(&container).unwrap();
        raw[4] = 0x7f;
        std::fs::write(&container, &raw).unwrap();

        let out = dir.path().join("out.bin");
        let err = decrypt_container_to_file(&container, &out, &[1u8; 32], &hash).unwrap_err();
        assert!(
            matches!(err, CloudSyncError::PayloadVersionMismatch { .. }),
            "版本过新必须引导升级，不得塌成密钥错误: {err:?}"
        );
        assert_eq!(err.category_tag(), "payload_version");
    }

    #[test]
    fn legacy_oszs_payload_is_not_mistaken_for_container() {
        assert!(!is_container(b"OSZS"));
        assert!(is_container(b"OSAC"));
        assert!(!is_container(b"OSA"));
    }
}
