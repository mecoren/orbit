//! crypto_io — 同步 payload 加密/解密包装
//!
//! 在 AES-256-GCM 原语之上封装"nonce 前置"的 payload 格式，
//! 供 Push/Pull/附件同步统一使用。所有云端数据（结构化 data.json/meta.json/_meta.json
//! 以及附件 media/<sha256>）均用同一 Data Key 加密。
//!
//! ## payload 格式
//! ```text
//! [magic(4)="OSZS")[version(1)=0x01|0x02][nonce(12)][ciphertext+tag(16)]
//! ```
//! 其中明文先经 zstd level=3 压缩再 AES-256-GCM 加密。
//! 几百 K JSON 压缩后通常 30-50K，传输时间从 ~1s 降至 ~50ms。
//! 遗留 magic `"WSZS"` 仅读侧兼容（解包接受），写侧一律 `"OSZS"`。
//!
//! ## 版本语义（ADR 0010 决定 1/3）
//! - `0x01`：AAD 为空，全部存量云端密文即此格式。
//! - `0x02`：AAD = 云端逻辑对象路径（见 [`encrypt_bucket_payload`]），
//!   跨桶密文不可互换。**仅表桶载荷可写此版本，附件永不**（ADR 决定 5）。
//!
//! 版本门禁一律按**大小**判定而非 `!=`：`>` 支持上限是「未来版本」（提示升级
//! 应用，报 [`CloudSyncError::PayloadVersionMismatch`]），`<` 最低版本是「上古/
//! 损坏」；两者塌成一条错误会让升级用户误走密钥恢复流程。
//!
//! 与 `sync_crypto::bundle_io` 和 `full_sync_backup::encoder` 的加密格式保持独立：
//! - 全量备份用 `.orfullsync` 容器（含 magic header + 多文件 ZIP）
//! - 云端同步用本模块的 nonce 前置格式（裸 payload，适配 S3/WebDAV 直传）

use crate::cloud_sync::error::CloudSyncError;
use crate::crypto::aes_gcm::{aes_gcm_decrypt_aad, aes_gcm_encrypt_aad};
use crate::crypto::error::CryptoErrorKind;

/// AES-GCM nonce 长度（字节）
const NONCE_LEN: usize = 12;

/// Data Key 长度（字节，32 = AES-256）
const DATA_KEY_LEN: usize = 32;

/// payload magic header：ASCII "OSZS"（Orbit Sync Zstd，默认格式）
const MAGIC: &[u8; 4] = b"OSZS";

/// 遗留 payload magic：ASCII "WSZS"（读侧兼容，不再写入）
const LEGACY_MAGIC: &[u8; 4] = b"WSZS";

/// payload 版本号：AAD 为空（存量全部密文即此格式）
const PAYLOAD_VERSION: u8 = 0x01;

/// payload 版本号：AAD 绑定云端逻辑对象路径（ADR 0010，仅表桶载荷）
const PAYLOAD_VERSION_AAD: u8 = 0x02;

/// payload 头部总长度：magic(4) + version(1) = 5 字节
const HEADER_LEN: usize = 5;

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
    encrypt_payload_at(plaintext, data_key, None)
}

/// 加密表桶载荷，并按门禁决定是否把**云端逻辑对象路径**绑进 AAD
///
/// `path` 是不含 `base_path` 前缀的逻辑路径（`paths::table_bucket_path` 的产出），
/// 两端各自拼接前缀后仍得到同一 AAD——绑定关系与「同步到哪个分享根目录」无关。
///
/// `bind_aad = true` 产出 0x02；`false` 产出与存量逐字节同格式的 0x01。门禁取值
/// 见 [`crate::cloud_sync::meta::Manifest::all_devices_support_aad`]（ADR 0010 决定 2
/// 的两拍：旧设备未全部升级前不得绑定）。
///
/// 收益是把「存储端把 A 桶密文搬到 B 桶」从**明文校验**（pull 比对
/// `payload.table`/`payload.bucket`）升级为 **AEAD 校验**（搬运后 tag 直接解不开）。
/// **附件与清单不走此入口**（附件内容寻址自带校验，ADR 0010 决定 5）。
pub(crate) fn encrypt_bucket_payload(
    plaintext: &[u8],
    data_key: &[u8],
    path: &str,
    bind_aad: bool,
) -> Result<Vec<u8>, CloudSyncError> {
    match bind_aad {
        true => encrypt_payload_at(plaintext, data_key, Some(path)),
        false => encrypt_payload_at(plaintext, data_key, None),
    }
}

/// 加密实现：`path` 为 `Some` 时产出 0x02（AAD = 路径），否则 0x01（AAD 空）
fn encrypt_payload_at(
    plaintext: &[u8],
    data_key: &[u8],
    path: Option<&str>,
) -> Result<Vec<u8>, CloudSyncError> {
    validate_data_key(data_key)?;
    let aad = path.map(str::as_bytes).unwrap_or_default();
    let version = if path.is_some() {
        PAYLOAD_VERSION_AAD
    } else {
        PAYLOAD_VERSION
    };

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
    let nonce = derive_deterministic_nonce(data_key, &compressed, aad);
    let ciphertext = aes_gcm_encrypt_aad(data_key, &compressed, &nonce, aad)?;

    // 3. 拼接 payload：magic + version + nonce + ciphertext
    let mut payload = Vec::with_capacity(HEADER_LEN + NONCE_LEN + ciphertext.len());
    payload.extend_from_slice(MAGIC);
    payload.push(version);
    payload.extend_from_slice(&nonce);
    payload.extend_from_slice(&ciphertext);
    Ok(payload)
}

/// 确定性 nonce 派生（纯函数，供单测）
/// 口径澄清（N36 收口）：`full` 是 SHA-256 的 hex 字符串（64 个 ASCII 字符），
/// 取前 12 字节即 12 个 hex 字符 = 48-bit 熵，不是 AES-GCM 标准 96-bit 随机
/// nonce。生日界约 2^24，同步 payload 量级下可用，但不得误述为“96-bit 余量
/// 充足”。存量云端密文即按此格式落盘，任何改动（取原始字节/加长）都是格式
/// 演进，须走版本门禁，当前一行不改，只 pin 住现状。
///
/// `SHA256(data_key ‖ SHA256(compressed)hex ‖ len_be)[0..12]`
///
/// - data_key 参与哈希：key 不同 → nonce 全不同；攻击者无 key 时无法为
///   目标明文预计算 nonce，也无法构造碰撞对（nonce 碰撞 ⊇ SHA-256 碰撞）
/// - len 域分离：防不同长度输入因哈希缓冲区拼接歧义产生相同摘要
/// - 用压缩后明文的 SHA-256 而非明文本身：压缩后内容才是实际进入 AEAD
///   的明文，nonce 唯一性须按它保证；hex 拼接避免 `‖` 拼接歧义
/// - aad 参与派生：0x02 载荷下同一明文落到不同对象路径时 nonce 不同，
///   「同 key + 同 nonce 加密不同 AAD 消息」这条 GCM 禁忌因此不成立；
///   0x01 的 aad 恒为空串 → 派生结果与存量密文逐字节一致
fn derive_deterministic_nonce(data_key: &[u8], compressed: &[u8], aad: &[u8]) -> Vec<u8> {
    let inner = crate::crypto::sha256::sha256_hex(compressed);
    let len = (compressed.len() as u64).to_be_bytes();
    let mut input = Vec::with_capacity(data_key.len() + inner.len() + 8 + aad.len());
    input.extend_from_slice(data_key);
    input.extend_from_slice(inner.as_bytes());
    input.extend_from_slice(&len);
    input.extend_from_slice(aad);
    let full = crate::crypto::sha256::sha256_hex(&input);
    full.into_bytes()[..NONCE_LEN].to_vec()
}

/// 解密 payload：分离 magic/version/nonce/ciphertext → AES 解密 → zstd 解压
///
/// 输入：`[magic(4)][version(1)][nonce(12)][ciphertext+tag]`
/// 输出：明文字节
///
/// 只吃 0x01（无 AAD）载荷：清单、附件、同步包等非路径绑定对象走此入口。
pub fn decrypt_payload(payload: &[u8], data_key: &[u8]) -> Result<Vec<u8>, CloudSyncError> {
    decrypt_payload_at(payload, data_key, None)
}

/// 解密表桶载荷：0x01（存量、空 AAD）与 0x02（AAD = `path`）都能解开
///
/// 读侧兼容是**单向**的：本客户端能读未来版本客户端写的绑定密文，
/// 反之不行（旧客户端遇 0x02 报 `PayloadVersionMismatch`，见版本门禁）。
pub(crate) fn decrypt_bucket_payload(
    payload: &[u8],
    data_key: &[u8],
    path: &str,
) -> Result<Vec<u8>, CloudSyncError> {
    decrypt_payload_at(payload, data_key, Some(path))
}

fn decrypt_payload_at(
    payload: &[u8],
    data_key: &[u8],
    path: Option<&str>,
) -> Result<Vec<u8>, CloudSyncError> {
    validate_data_key(data_key)?;

    if payload.len() < HEADER_LEN + NONCE_LEN {
        return Err(CloudSyncError::PayloadTooShort);
    }
    // 读侧兼容：新 "OSZS" 与遗留 "WSZS" 均接受，写侧一律 "OSZS"
    if &payload[..4] != MAGIC && &payload[..4] != LEGACY_MAGIC {
        return Err(CloudSyncError::Crypto {
            message: format!(
                "payload 格式不匹配：期望 magic={:?}，实际 magic={:?}",
                MAGIC, &payload[..4]
            ),
        });
    }
    // 版本门禁按大小判定（ADR 0010 决定 1）：本入口能提供的 AAD 上下文
    // 决定了可接受的上限——无路径就无法解 0x02，此时报「版本过新」而非密钥错误
    let version = payload[4];
    let max_version = if path.is_some() {
        PAYLOAD_VERSION_AAD
    } else {
        PAYLOAD_VERSION
    };
    if version > max_version {
        return Err(CloudSyncError::PayloadVersionMismatch {
            message: format!(
                "云端载荷版本 {:#04x} 高于本客户端支持的上限 {:#04x}，请升级应用后重试（云端数据未损坏）",
                version, max_version
            ),
        });
    }
    if version < PAYLOAD_VERSION {
        return Err(CloudSyncError::Crypto {
            message: format!(
                "payload 版本过旧或已损坏：version={:#04x}（本客户端支持 {:#04x}~{:#04x}）",
                version, PAYLOAD_VERSION, max_version
            ),
        });
    }
    let aad = match version {
        PAYLOAD_VERSION_AAD => path.map(str::as_bytes).unwrap_or_default(),
        _ => b"".as_slice(),
    };

    let (header_and_nonce, ciphertext) = payload.split_at(HEADER_LEN + NONCE_LEN);
    let nonce = &header_and_nonce[HEADER_LEN..];
    let compressed =
        aes_gcm_decrypt_aad(data_key, ciphertext, nonce, aad).map_err(map_decrypt_error)?;

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
        let n1 = derive_deterministic_nonce(&[1u8; 32], b"same-plaintext", b"");
        let n2 = derive_deterministic_nonce(&[2u8; 32], b"same-plaintext", b"");
        assert_ne!(n1, n2, "不同 Data Key 的 nonce 必须不同");
    }

    /// 明文变化 → nonce 必然不同（GCM nonce 唯一性：同 key 下不得重复）
    #[test]
    fn nonce_changes_with_plaintext() {
        let key = [1u8; 32];
        let n1 = derive_deterministic_nonce(&key, b"plaintext-a", b"");
        let n2 = derive_deterministic_nonce(&key, b"plaintext-b", b"");
        let n3 = derive_deterministic_nonce(&key, b"plaintext-ab", b"");
        assert_ne!(n1, n2, "不同明文的 nonce 必须不同（防 GCM 灾难）");
        assert_ne!(n1, n3, "前缀延长的明文不得命中同一 nonce（len 域分离）");
    }

    /// 派生 nonce 长度恒为 12 字节，且为 hex ASCII（pin 住存量格式：改即不兼容）
    #[test]
    fn derived_nonce_length_is_12() {
        let n = derive_deterministic_nonce(&[9u8; 32], b"any", b"");
        assert_eq!(n.len(), NONCE_LEN);
        assert_eq!(NONCE_LEN, 12);
        assert!(
            n.iter().all(|b| b.is_ascii_hexdigit()),
            "存量 nonce 是 hex 字符串前 12 字符，须全为 hex ASCII"
        );
    }

    /// 空 AAD 时派生口径与存量密文逐字节一致（AAD 入参是纯增量，不改 0x01 格式）
    #[test]
    fn empty_aad_keeps_legacy_nonce() {
        let key = [3u8; 32];
        let compressed = b"payload";
        // 手工重算改动前的公式：SHA256(key ‖ sha256_hex(compressed) ‖ len_be) 前 12 hex
        let inner = crate::crypto::sha256::sha256_hex(compressed);
        let mut input = Vec::new();
        input.extend_from_slice(&key);
        input.extend_from_slice(inner.as_bytes());
        input.extend_from_slice(&(compressed.len() as u64).to_be_bytes());
        let expected = crate::crypto::sha256::sha256_hex(&input).into_bytes()[..NONCE_LEN].to_vec();
        assert_eq!(
            derive_deterministic_nonce(&key, compressed, b""),
            expected,
            "空 AAD 必须产出与存量云端密文相同的 nonce"
        );
        assert_ne!(
            derive_deterministic_nonce(&key, compressed, b"tables/todo_tasks/7.orsync"),
            expected,
            "绑定路径后同一明文在不同对象上不得复用 nonce"
        );
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
        assert_eq!(&enc[..4], b"OSZS");
        assert_eq!(enc[4], PAYLOAD_VERSION);
    }

    /// 遗留 magic "WSZS" 读侧兼容：旧密文仍可解开
    #[test]
    fn legacy_wszs_payload_still_decrypts() {
        let key = [5u8; 32];
        let enc = encrypt_payload(b"legacy-compat", &key).unwrap();
        let mut legacy = enc.clone();
        legacy[0..4].copy_from_slice(b"WSZS");
        let dec = decrypt_payload(&legacy, &key).unwrap();
        assert_eq!(dec, b"legacy-compat");
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

#[cfg(test)]
mod aad_binding_tests {
    use super::*;

    const PATH: &str = "tables/todo_tasks/7.orsync";

    fn key() -> [u8; 32] {
        [11u8; 32]
    }

    /// 绑定门禁：bind=true 产出 0x02，bind=false 与存量 0x01 逐字节同格式
    #[test]
    fn gate_selects_payload_version() {
        let bound = encrypt_bucket_payload(b"bucket", &key(), PATH, true).unwrap();
        let plain = encrypt_bucket_payload(b"bucket", &key(), PATH, false).unwrap();
        assert_eq!(bound[4], PAYLOAD_VERSION_AAD);
        assert_eq!(plain[4], PAYLOAD_VERSION);
        assert_eq!(
            plain,
            encrypt_payload(b"bucket", &key()).unwrap(),
            "门禁关闭时表桶加密必须与改动前完全一致（第二拍前零风险）"
        );
    }

    /// 同内容不同路径 → 密文不同（跨桶密文不可互换，ADR 0010 的立论本身）
    #[test]
    fn ciphertext_is_not_interchangeable_across_buckets() {
        let a = encrypt_bucket_payload(b"same", &key(), PATH, true).unwrap();
        let b = encrypt_bucket_payload(b"same", &key(), "tables/todo_tasks/8.orsync", true).unwrap();
        assert_ne!(a, b, "同一明文搬到别的桶必须产出不同密文");
    }

    /// AAD 不符即解密失败（存储端把 A 桶密文搬到 B 桶：tag 直接解不开）
    #[test]
    fn wrong_path_fails_to_decrypt() {
        let enc = encrypt_bucket_payload(b"bucket", &key(), PATH, true).unwrap();
        let err = decrypt_bucket_payload(&enc, &key(), "tables/labels/3.orsync").unwrap_err();
        // 与「密钥不对」「密文被改一位」同表现为 tag 失败 → 沿用既有 KeyMismatch
        // 口径（0x01 格式下存储端改一个比特也是这个结果，不是 AAD 引入的新歧义）
        assert!(
            matches!(err, CloudSyncError::KeyMismatch),
            "实际: {err:?}"
        );
    }

    /// 读侧兼容：存量 0x01 密文经绑定入口（多带一个 path）照样解开
    #[test]
    fn legacy_payload_still_decrypts_through_bucket_entry() {
        let plain = "存量分桶".as_bytes();
        let enc = encrypt_payload(plain, &key()).unwrap();
        assert_eq!(decrypt_bucket_payload(&enc, &key(), PATH).unwrap(), plain);
    }

    /// 旧客户端遇 0x02：报 PayloadVersionMismatch（升级应用），不得塌进 KeyMismatch
    /// （否则 UI 跳密钥恢复页，用户会去重导密钥包——数据其实完好）
    #[test]
    fn bound_payload_on_plain_entry_reports_version_mismatch() {
        let enc = encrypt_bucket_payload(b"bucket", &key(), PATH, true).unwrap();
        let err = decrypt_payload(&enc, &key()).unwrap_err();
        assert!(
            matches!(err, CloudSyncError::PayloadVersionMismatch { .. }),
            "实际: {err:?}"
        );
        assert_eq!(err.category_tag(), "payload_version");
        assert!(!err.is_key_mismatch_error());
        assert!(!err.is_password_error());
    }

    /// version=0 属上古/损坏，按格式错误处理（不是「版本过新」）
    #[test]
    fn zero_version_payload_is_reported_corrupt() {
        let mut enc = encrypt_payload(b"bucket", &key()).unwrap();
        enc[4] = 0x00;
        let err = decrypt_payload(&enc, &key()).unwrap_err();
        assert!(
            matches!(err, CloudSyncError::Crypto { .. }),
            "实际: {err:?}"
        );
    }
}
