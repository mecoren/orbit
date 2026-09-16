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

    for i in 0..archive.len() {
        let mut file = archive
            .by_index(i)
            .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
        let name = file.name().to_string();

        let mut buf = String::with_capacity(file.size() as usize);
        file.read_to_string(&mut buf)
            .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;

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
}
