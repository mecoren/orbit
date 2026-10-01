//! decoder — AES-256-GCM 解密 + ZIP 解压
//!
//! 解码 `.orfullsync` 文件（兼容遗留 `.waitfullsync`）：
//! 1. 解析 36 字节头部（magic + salt + nonce + iterations）
//! 2. PBKDF2 派生 master_key
//! 3. AES-256-GCM 解密密文（GCM tag 验证失败即密码错误）
//! 4. ZIP 解压得到 manifest + business/*.json + system/schema_version.json
//!
//! 注意：本模块只负责解密与解压，**不**执行数据库写入。
//! 全量覆盖恢复（DELETE + INSERT）在 `api::full_sync_backup_api` 中实现。

use std::collections::BTreeMap;
use std::io::Read;

use crate::crypto::{aes_gcm_decrypt, derive_master_key};
use crate::full_sync_backup::container::parse_container;
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};
use crate::full_sync_backup::manifest::BackupManifest;

/// 单个 ZIP 条目解压后的字节上限（512 MiB）
///
/// F65：备份文件是**外部输入**（云存储对象 / 其他设备拷贝 / 手工放置），
/// ZIP 中央目录里声明的 `size` 属于随文件一起进来的元数据，不可信。
/// 单表全部记录序列化后的 JSON 正常在 MiB 量级，512 MiB 已远超真实用量。
const MAX_ENTRY_BYTES: u64 = 512 * 1024 * 1024;

/// 全部条目解压后的累计字节上限（2 GiB）
///
/// 单独设总量上限是为了防「每个条目都不越界、但条目数极多」的 ZIP 炸弹形态。
const MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// 解码结果
#[derive(Debug, Clone)]
pub struct DecodedBackup {
    /// 备份清单
    pub manifest: BackupManifest,
    /// 业务表数据：表名 → JSON 字符串
    pub table_data: BTreeMap<String, String>,
    /// schema_version JSON 字符串
    pub schema_version_json: String,
}

/// 解码 `.orfullsync` 字节流（兼容遗留 `.waitfullsync`）
///
/// 输入：完整的 .orfullsync 文件字节 + 同步密码
/// 输出：解码后的 manifest + table_data + schema_version_json
///
/// 失败场景：
/// - 文件头过短 / magic 不匹配 → `HeaderTooShort` / `MagicMismatch`
/// - 同步密码错误 → `WrongSyncPassword`（AES-GCM tag 验证失败）
/// - ZIP 解压失败 → `Zip`
/// - manifest 解析失败 → `Serde`
pub fn decode_backup(bytes: &[u8], sync_password: &str) -> FullSyncBackupResult<DecodedBackup> {
    // 1. 解析容器头部与密文
    let (header, ciphertext) = parse_container(bytes)?;

    // 2. PBKDF2 派生 master_key
    // F33：iterations 取自下载的备份文件头（云端对象可被存储端改写），先验强度下限
    crate::crypto::ensure_kdf_strength(header.iterations, "备份文件头")?;
    let master_key = derive_master_key(sync_password, &header.salt, header.iterations, 32)?;

    // 3. AES-256-GCM 解密
    //    GCM tag 验证失败 → CryptoError::DecryptionFailed → FullSyncBackupError::WrongSyncPassword
    let zip_bytes = aes_gcm_decrypt(&master_key, ciphertext, &header.nonce)
        .map_err(|_| FullSyncBackupError::WrongSyncPassword)?;

    // 4. ZIP 解压
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive =
        zip::ZipArchive::new(cursor).map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;

    let mut manifest: Option<BackupManifest> = None;
    let mut table_data: BTreeMap<String, String> = BTreeMap::new();
    let mut schema_version_json: Option<String> = None;
    // F65：解压总量累计（双上限中的第二个）
    let mut total_bytes: u64 = 0;

    for i in 0..archive.len() {
        let mut file = archive
            .by_index(i)
            .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
        let name = file.name().to_string();

        let buf = read_entry_bounded(
            &mut file,
            &name,
            MAX_ENTRY_BYTES,
            &mut total_bytes,
            MAX_TOTAL_BYTES,
        )?;

        if name == "manifest.json" {
            manifest = Some(BackupManifest::from_json(&buf)?);
        } else if let Some(table_name) = name
            .strip_prefix("business/")
            .and_then(|s| s.strip_suffix(".json"))
        {
            table_data.insert(table_name.to_string(), buf);
        } else if name == "system/schema_version.json" {
            schema_version_json = Some(buf);
        }
        // 其他文件（如 crypto/bundle_meta.json）忽略
    }

    let manifest = manifest.ok_or_else(|| {
        FullSyncBackupError::InvalidFormat("ZIP 中缺少 manifest.json".to_string())
    })?;
    let schema_version_json = schema_version_json.unwrap_or_else(|| r#"{"version":0}"#.to_string());

    Ok(DecodedBackup {
        manifest,
        table_data,
        schema_version_json,
    })
}

/// 从 ZIP 条目读取文本内容（带双重上限）
///
/// F65：原实现是
/// ```ignore
/// let mut buf = String::with_capacity(file.size() as usize); // ← 用声明的 size 预分配
/// file.read_to_string(&mut buf)?;                             // ← 无任何上限
/// ```
/// 两处都把外部文件的自述当成可信：`size` 被伪造成 8 GiB 时，第一行就发起一次
/// 8 GiB 的分配（`with_capacity` 失败即 panic / 进程中止）；即便 size 报得小，
/// 第二行也会一路读到内存耗尽。备份文件可经云存储或他人拷贝获得，
/// 因此在导入路径上按「按需增长 + 越界即中止」处理。
///
/// - 单条目：最多读 `max_entry_bytes + 1` 字节，多读的 1 字节用于判定越界；
/// - 总量：`total_bytes` 由调用方跨条目累加，防止多条各自不越界但总量失控。
fn read_entry_bounded<R: std::io::Read>(
    reader: R,
    name: &str,
    max_entry_bytes: u64,
    total_bytes: &mut u64,
    max_total_bytes: u64,
) -> FullSyncBackupResult<String> {
    // 不用 `Vec::with_capacity(声明 length)`：声明值不可信，交给 Vec 的
    // 均摊增长（读到的字节数才是真实用量，且被 take 上限封顶）。
    let mut raw: Vec<u8> = Vec::new();
    reader
        .take(max_entry_bytes + 1)
        .read_to_end(&mut raw)
        .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;

    if raw.len() as u64 > max_entry_bytes {
        return Err(FullSyncBackupError::InvalidFormat(format!(
            "备份内条目 {} 解压后超过单条上限 {} MiB，已中止（文件可能已损坏，或非本应用产出）",
            name,
            max_entry_bytes / (1024 * 1024)
        )));
    }

    *total_bytes = total_bytes.saturating_add(raw.len() as u64);
    if *total_bytes > max_total_bytes {
        return Err(FullSyncBackupError::InvalidFormat(format!(
            "备份解压总量超过上限 {} MiB，已中止（疑似 ZIP 炸弹或文件损坏）",
            max_total_bytes / (1024 * 1024)
        )));
    }

    String::from_utf8(raw).map_err(|e| {
        FullSyncBackupError::InvalidFormat(format!("备份内条目 {} 不是合法 UTF-8: {}", name, e))
    })
}

#[cfg(test)]
mod tests {
    use super::super::encoder::{EncodeParams, encode_backup};
    use super::*;
    use chrono::Utc;

    fn sample_manifest() -> BackupManifest {
        let mut counts = BTreeMap::new();
        counts.insert("rec_books".to_string(), 2);
        counts.insert("todo_tasks".to_string(), 1);
        BackupManifest::new(
            "dev-001".to_string(),
            Some("Test Device".to_string()),
            1,
            counts,
            Utc::now().timestamp(),
            "0.3.7".to_string(),
        )
    }

    fn sample_table_data() -> BTreeMap<String, String> {
        let mut data = BTreeMap::new();
        data.insert(
            "rec_books".to_string(),
            r#"[{"id":1,"title":"Book A"},{"id":2,"title":"Book B"}]"#.to_string(),
        );
        data.insert(
            "todo_tasks".to_string(),
            r#"[{"id":1,"title":"Task A","done":false}]"#.to_string(),
        );
        data
    }

    #[test]
    fn encode_then_decode_roundtrip() {
        let manifest = sample_manifest();
        let table_data = sample_table_data();
        let original = EncodeParams {
            sync_password: "correct_password",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        };

        let encoded = encode_backup(original).unwrap();
        let decoded = decode_backup(&encoded.bytes, "correct_password").unwrap();

        assert_eq!(decoded.manifest, manifest);
        assert_eq!(decoded.table_data, table_data);
        assert_eq!(decoded.schema_version_json, r#"{"version":1}"#);
    }

    #[test]
    fn decode_with_wrong_password_returns_wrong_sync_password() {
        let manifest = sample_manifest();
        let table_data = sample_table_data();
        let encoded = encode_backup(EncodeParams {
            sync_password: "correct_password",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        let result = decode_backup(&encoded.bytes, "wrong_password");
        assert!(matches!(
            result,
            Err(FullSyncBackupError::WrongSyncPassword)
        ));
    }

    #[test]
    fn decode_invalid_magic_fails() {
        let bad_bytes = vec![0u8; 100]; // 全零字节，magic 不匹配
        let result = decode_backup(&bad_bytes, "any_password");
        assert!(matches!(
            result,
            Err(FullSyncBackupError::MagicMismatch { .. })
        ));
    }

    #[test]
    fn decode_too_short_data_fails() {
        let short_data = vec![0u8; 10];
        let result = decode_backup(&short_data, "any_password");
        assert!(matches!(
            result,
            Err(FullSyncBackupError::HeaderTooShort { .. })
        ));
    }

    #[test]
    fn decode_empty_table_data() {
        let manifest = BackupManifest::new(
            "dev".to_string(),
            None,
            1,
            BTreeMap::new(),
            Utc::now().timestamp(),
            "0.3.7".to_string(),
        );
        let encoded = encode_backup(EncodeParams {
            sync_password: "pw",
            manifest: &manifest,
            table_data: &BTreeMap::new(),
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        let decoded = decode_backup(&encoded.bytes, "pw").unwrap();
        assert_eq!(decoded.manifest, manifest);
        assert!(decoded.table_data.is_empty());
    }

    #[test]
    fn decode_preserves_table_order_alphabetically() {
        // BTreeMap 保证字母序，解码后也应保持字母序
        let mut manifest_counts = BTreeMap::new();
        manifest_counts.insert("zebra".to_string(), 1);
        manifest_counts.insert("alpha".to_string(), 1);
        manifest_counts.insert("middle".to_string(), 1);

        let manifest = BackupManifest::new(
            "dev".to_string(),
            None,
            1,
            manifest_counts,
            Utc::now().timestamp(),
            "0.3.7".to_string(),
        );

        let mut table_data = BTreeMap::new();
        table_data.insert("zebra".to_string(), r#"[{"id":1}]"#.to_string());
        table_data.insert("alpha".to_string(), r#"[{"id":1}]"#.to_string());
        table_data.insert("middle".to_string(), r#"[{"id":1}]"#.to_string());

        let encoded = encode_backup(EncodeParams {
            sync_password: "pw",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        let decoded = decode_backup(&encoded.bytes, "pw").unwrap();
        let keys: Vec<&String> = decoded.table_data.keys().collect();
        assert_eq!(keys, vec!["alpha", "middle", "zebra"]);
    }

    // ─────────── F65：解压上限 ───────────

    /// 单条目超限即报错（用 16 字节的小阈值验逻辑，避免真造 512 MiB 夹具；
    /// 生产阈值由 `MAX_ENTRY_BYTES` 常量给出，调用点与其一致）
    #[test]
    fn read_entry_bounded_rejects_entry_over_limit() {
        let mut total = 0u64;
        let payload = vec![b'a'; 17];
        let result = read_entry_bounded(
            std::io::Cursor::new(payload),
            "business/huge.json",
            16,
            &mut total,
            1024,
        );

        match result {
            Err(FullSyncBackupError::InvalidFormat(msg)) => {
                assert!(msg.contains("单条上限"), "错误信息应点明单条上限: {msg}");
                assert!(
                    msg.contains("business/huge.json"),
                    "错误信息应带上条目名便于定位: {msg}"
                );
            }
            other => panic!("应因单条目超限被拒，实际: {other:?}"),
        }
        // 越界条目不得计入总量（否则会连带污染后续判定）
        assert_eq!(total, 0, "越界条目不应计入累计字节");
    }

    /// 恰好等于上限应放行（边界：多读的 1 字节用于判定越界，不能误伤等长条目）
    #[test]
    fn read_entry_bounded_accepts_exact_limit() {
        let mut total = 0u64;
        let out = read_entry_bounded(
            std::io::Cursor::new(vec![b'a'; 16]),
            "business/exact.json",
            16,
            &mut total,
            1024,
        )
        .expect("等于上限应放行");
        assert_eq!(out.len(), 16);
        assert_eq!(total, 16);
    }

    /// 各条目均未越界但累计超限 → 报错（ZIP 炸弹形态）
    #[test]
    fn read_entry_bounded_rejects_total_over_limit() {
        let mut total = 0u64;
        assert!(
            read_entry_bounded(
                std::io::Cursor::new(vec![b'a'; 8]),
                "a.json",
                64,
                &mut total,
                10
            )
            .is_ok(),
            "首个条目累计 8 字节未超 10 字节上限"
        );

        match read_entry_bounded(
            std::io::Cursor::new(vec![b'a'; 8]),
            "b.json",
            64,
            &mut total,
            10,
        ) {
            Err(FullSyncBackupError::InvalidFormat(msg)) => {
                assert!(msg.contains("总量"), "错误信息应点明总量上限: {msg}");
            }
            other => panic!("应因累计总量超限被拒，实际: {other:?}"),
        }
    }

    /// 非 UTF-8 内容给出可读错误（原实现由 `read_to_string` 抛 Zip 错误）
    #[test]
    fn read_entry_bounded_rejects_invalid_utf8() {
        let mut total = 0u64;
        let result = read_entry_bounded(
            std::io::Cursor::new(vec![0xff, 0xfe, 0xfd]),
            "business/bin.json",
            64,
            &mut total,
            1024,
        );
        match result {
            Err(FullSyncBackupError::InvalidFormat(msg)) => {
                assert!(msg.contains("UTF-8"), "错误信息应点明编码问题: {msg}");
            }
            other => panic!("非法 UTF-8 应被拒，实际: {other:?}"),
        }
    }
}
