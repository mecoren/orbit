//! encoder — ZIP 打包 + AES-256-GCM 加密
//!
//! 将 manifest + 业务表 JSON + schema_version 打包为 ZIP 字节流，
//! 然后用 PBKDF2 派生 master_key，AES-256-GCM 加密 ZIP 字节流，
//! 最后拼接为 `.waitfullsync` 容器格式。
//!
//! 全内存操作，不向磁盘写中间文件，避免敏感数据残留。

use std::collections::BTreeMap;
use std::io::{Cursor, Write};

#[cfg(test)]
use chrono::Utc;

use crate::crypto::{aes_gcm_encrypt, derive_master_key, random_bytes};
use crate::full_sync_backup::container::{
    FullSyncHeader, ITERATIONS, NONCE_LEN, SALT_LEN, build_container,
};
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};
use crate::full_sync_backup::manifest::BackupManifest;

/// 编码输入参数
pub struct EncodeParams<'a> {
    /// 同步密码（用于 PBKDF2 派生 master_key）
    pub sync_password: &'a str,
    /// 备份清单
    pub manifest: &'a BackupManifest,
    /// 业务表数据：表名 → JSON 字符串
    pub table_data: &'a BTreeMap<String, String>,
    /// schema_version JSON 字符串
    pub schema_version_json: &'a str,
}

/// 编码结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodeResult {
    /// 完整的 .waitfullsync 字节流
    pub bytes: Vec<u8>,
    /// 文件总大小（字节）
    pub size: usize,
}

/// 编码备份：ZIP 打包 + AES-GCM 加密 + 容器封装
pub fn encode_backup(params: EncodeParams) -> FullSyncBackupResult<EncodeResult> {
    // 1. 构建 ZIP 字节流
    let zip_bytes = build_zip_bytes(
        params.manifest,
        params.table_data,
        params.schema_version_json,
    )?;

    // 2. 生成随机 salt(16B) + nonce(12B)
    let salt = random_bytes(SALT_LEN);
    let nonce = random_bytes(NONCE_LEN);

    // 3. PBKDF2 派生 master_key（32 字节，AES-256）
    let master_key = derive_master_key(params.sync_password, &salt, ITERATIONS, 32)?;

    // 4. AES-256-GCM 加密 ZIP 字节流（密文 + 末尾 16B GCM tag）
    let ciphertext = aes_gcm_encrypt(&master_key, &zip_bytes, &nonce)?;

    // 5. 拼接容器：[magic][salt][nonce][iterations][ciphertext]
    let header = FullSyncHeader {
        salt: salt.try_into().map_err(|_| {
            FullSyncBackupError::InvalidFormat(format!("salt 长度错误：期望 {} 字节", SALT_LEN))
        })?,
        nonce: nonce.try_into().map_err(|_| {
            FullSyncBackupError::InvalidFormat(format!("nonce 长度错误：期望 {} 字节", NONCE_LEN))
        })?,
        iterations: ITERATIONS,
    };
    let bytes = build_container(&header, &ciphertext);

    let size = bytes.len();
    Ok(EncodeResult { bytes, size })
}

/// 构建 ZIP 字节流
///
/// ZIP 结构：
/// - manifest.json：备份清单
/// - business/<table>.json：业务表数据（每张表一个 JSON 数组文件）
/// - system/schema_version.json：schema 版本号
fn build_zip_bytes(
    manifest: &BackupManifest,
    table_data: &BTreeMap<String, String>,
    schema_version_json: &str,
) -> FullSyncBackupResult<Vec<u8>> {
    let buf = Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(buf);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    // manifest.json 必须最先写入
    let manifest_json = manifest.to_json()?;
    zip.start_file("manifest.json", options)
        .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
    zip.write_all(manifest_json.as_bytes())?;

    // business/<table>.json
    for (table_name, json_str) in table_data {
        let entry = format!("business/{}.json", table_name);
        zip.start_file(&entry, options)
            .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
        zip.write_all(json_str.as_bytes())?;
    }

    // system/schema_version.json
    zip.start_file("system/schema_version.json", options)
        .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
    zip.write_all(schema_version_json.as_bytes())?;

    let cursor = zip
        .finish()
        .map_err(|e| FullSyncBackupError::Zip(e.to_string()))?;
    Ok(cursor.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn encode_backup_produces_valid_container() {
        let manifest = sample_manifest();
        let table_data = sample_table_data();
        let params = EncodeParams {
            sync_password: "test_password",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        };

        let result = encode_backup(params).unwrap();

        // 容器至少 36 字节头 + 一些密文
        assert!(result.size > 36, "编码结果应至少包含 36 字节头");
        assert_eq!(result.bytes.len(), result.size);

        // magic 应为 "WFS1"
        assert_eq!(&result.bytes[0..4], b"WFS1");
    }

    #[test]
    fn encode_backup_with_empty_tables() {
        let manifest = BackupManifest::new(
            "dev".to_string(),
            None,
            1,
            BTreeMap::new(),
            Utc::now().timestamp(),
            "0.3.7".to_string(),
        );
        let params = EncodeParams {
            sync_password: "pw",
            manifest: &manifest,
            table_data: &BTreeMap::new(),
            schema_version_json: r#"{"version":1}"#,
        };

        let result = encode_backup(params).unwrap();
        assert!(result.size > 36);
    }

    #[test]
    fn encode_backup_different_passwords_produce_different_output() {
        let manifest = sample_manifest();
        let table_data = sample_table_data();

        let result1 = encode_backup(EncodeParams {
            sync_password: "password1",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        let result2 = encode_backup(EncodeParams {
            sync_password: "password2",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        // 不同密码应产生不同密文（极大概率）
        assert_ne!(result1.bytes, result2.bytes, "不同密码应产生不同密文");
    }

    #[test]
    fn encode_backup_same_password_produces_different_output_due_to_random_salt() {
        // 即使密码相同，每次编码的 salt/nonce 是随机的，输出应不同
        let manifest = sample_manifest();
        let table_data = sample_table_data();

        let result1 = encode_backup(EncodeParams {
            sync_password: "same_password",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        let result2 = encode_backup(EncodeParams {
            sync_password: "same_password",
            manifest: &manifest,
            table_data: &table_data,
            schema_version_json: r#"{"version":1}"#,
        })
        .unwrap();

        assert_ne!(
            result1.bytes, result2.bytes,
            "相同密码也应因随机 salt/nonce 产生不同密文"
        );
    }
}
