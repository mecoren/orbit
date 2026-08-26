pub mod error;
pub mod header;

pub use error::SyncBundleError;
pub use header::{
    BundleMode, HEADER_SIZE, MAGIC_VALUE, SyncBundleHeader, parse_header, write_header,
};

use crate::crypto::{aes_gcm_decrypt, aes_gcm_encrypt, random_bytes};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{Cursor, Read, Write};

/// 解包后的同步包内容
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleContent {
    pub header: SyncBundleHeader,
    pub manifest: serde_json::Value,
    pub table_data: BTreeMap<String, Vec<serde_json::Value>>,
    pub assets: BTreeMap<String, Vec<u8>>,
}

/// .waitsync 打包参数
pub struct CreateBundleParams {
    pub mode: BundleMode,
    /// 表名 → JSONL 字符串
    pub tables_data: BTreeMap<String, String>,
    /// 附件 hash → 二进制内容
    pub assets_data: BTreeMap<String, Vec<u8>>,
    pub device_id: String,
    pub device_name: String,
    pub lamport_clock: i64,
    pub last_synced_version: i64,
    /// 用于加密 ZIP 字节的 Data Key（32 字节）
    pub master_key: Vec<u8>,
}

/// 创建 .waitsync 包
///
/// 流程：
/// 1. 构建 manifest JSON
/// 2. ZIP 打包（manifest.json + data/*.jsonl + assets/*.bin + crypto/bundle_meta.json）
/// 3. AES-256-GCM 加密 ZIP 字节
/// 4. 拼接 52 字节头 + 密文（含 GCM tag）
pub fn create_bundle(params: CreateBundleParams) -> Result<Vec<u8>, SyncBundleError> {
    // 1. 构建 manifest
    let mut tables = serde_json::Map::new();
    for (table_name, jsonl) in &params.tables_data {
        let count = jsonl.trim().lines().filter(|l| !l.is_empty()).count();
        let mut entry = serde_json::Map::new();
        entry.insert("count".to_string(), serde_json::Value::Number(count.into()));
        tables.insert(table_name.clone(), serde_json::Value::Object(entry));
    }

    let manifest = serde_json::json!({
        "format_version": 1,
        "mode": match params.mode {
            BundleMode::Full => "full",
            BundleMode::Incremental => "incremental",
            BundleMode::Snapshot => "snapshot",
        },
        "created_at": chrono::Utc::now().to_rfc3339(),
        "source_device_id": params.device_id,
        "source_device_name": params.device_name,
        "lamport_clock": params.lamport_clock,
        "last_synced_version": params.last_synced_version,
        "tables": serde_json::Value::Object(tables),
        "assets": params.assets_data.keys().collect::<Vec<_>>(),
        "app_version": "0.3.7+1",
    });

    // 2. ZIP 打包
    let zip_bytes = build_zip(
        &manifest,
        &params.tables_data,
        &params.assets_data,
        &params.device_id,
    )
    .map_err(|e| SyncBundleError {
        message: format!("ZIP 打包失败: {e}"),
    })?;

    // 3. AES-256-GCM 加密（key, plaintext, nonce 顺序与现有签名一致）
    let nonce = random_bytes(12);
    let ciphertext =
        aes_gcm_encrypt(&params.master_key, &zip_bytes, &nonce).map_err(|e| SyncBundleError {
            message: format!("AES-GCM 加密失败: {e}"),
        })?;

    // 4. 提取 GCM tag（末尾 16 字节）并构建 header
    let tag_offset = ciphertext.len().saturating_sub(16);
    let gcm_tag = if ciphertext.len() >= 16 {
        ciphertext[tag_offset..].to_vec()
    } else {
        vec![0u8; 16]
    };

    let header = SyncBundleHeader {
        version: 1,
        mode: params.mode,
        has_assets: !params.assets_data.is_empty(),
        created_at_ms: chrono::Utc::now().timestamp_millis(),
        nonce: nonce.clone(),
        gcm_tag,
        payload_len: ciphertext.len() as i64,
    };

    let header_bytes = write_header(&header);
    let mut result = Vec::with_capacity(header_bytes.len() + ciphertext.len());
    result.extend_from_slice(&header_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

/// 构建 ZIP 字节（内存中）
fn build_zip(
    manifest: &serde_json::Value,
    tables_data: &BTreeMap<String, String>,
    assets_data: &BTreeMap<String, Vec<u8>>,
    device_id: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let buf = Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(buf);
    let options = zip::write::SimpleFileOptions::default();

    // manifest.json
    zip.start_file("manifest.json", options)?;
    zip.write_all(serde_json::to_string(manifest)?.as_bytes())?;

    // data/<table>.jsonl
    for (table_name, jsonl) in tables_data {
        zip.start_file(format!("data/{table_name}.jsonl"), options)?;
        zip.write_all(jsonl.as_bytes())?;
    }

    // assets/<hash>.bin
    for (hash, data) in assets_data {
        zip.start_file(format!("assets/{hash}.bin"), options)?;
        zip.write_all(data)?;
    }

    // crypto/bundle_meta.json
    zip.start_file("crypto/bundle_meta.json", options)?;
    let meta = serde_json::json!({ "source_device_id": device_id });
    zip.write_all(serde_json::to_string(&meta)?.as_bytes())?;

    let cursor = zip.finish()?;
    Ok(cursor.into_inner())
}

/// 解包 .waitsync 文件
pub fn extract_bundle(
    bundle_bytes: &[u8],
    master_key: &[u8],
) -> Result<BundleContent, SyncBundleError> {
    let header = parse_header(bundle_bytes)?;
    let ciphertext = &bundle_bytes[HEADER_SIZE..];

    // 边界校验：header.payload_len 与实际密文长度应一致。
    // 不一致通常意味着文件被截断/拼接错误，提前失败避免误导性的"密码错误"诊断。
    // 注：header.gcm_tag 字段未参与校验——AES-GCM tag 已包含在 ciphertext 末尾，
    //     header.gcm_tag 仅为冗余镜像（保留以维持 wire format 兼容性）。
    if header.payload_len != ciphertext.len() as i64 {
        return Err(SyncBundleError {
            message: format!(
                "payload_len 不匹配：header 声明 {} 字节，实际密文 {} 字节（文件可能损坏或被截断）",
                header.payload_len,
                ciphertext.len()
            ),
        });
    }

    // AES-256-GCM 解密（key, ciphertext_with_tag, nonce 顺序与现有签名一致）
    // 解密失败可能由两种原因导致，分别提示以便排查：
    //   1. KeyMismatch —— 同步密码错误，或本地 Data Key 与云端加密 Key 不一致
    //   2. 数据损坏 —— 文件被截断/篡改，或 nonce 不匹配
    // AES-GCM 的完整性校验（tag 比对失败）无法在解密阶段区分这两种情况，
    // 但 payload_len 校验已先行排除了"长度异常"类损坏。
    let plaintext = aes_gcm_decrypt(master_key, ciphertext, &header.nonce).map_err(|e| {
        let kind_str = match e.kind {
            crate::crypto::CryptoErrorKind::DecryptionFailed => "解密失败(DecryptionFailed)",
            crate::crypto::CryptoErrorKind::InvalidKeyLength => "密钥长度非法(InvalidKeyLength)",
            crate::crypto::CryptoErrorKind::InvalidNonceLength => {
                "nonce 长度非法(InvalidNonceLength)"
            }
            crate::crypto::CryptoErrorKind::EncryptionFailed => "加密失败(EncryptionFailed)",
            crate::crypto::CryptoErrorKind::DerivationFailed => "密钥派生失败(DerivationFailed)",
        };
        SyncBundleError {
            message: format!(
                "解密失败：同步密码可能不正确，或本地 Data Key 与云端加密 Key 不一致（{}）",
                kind_str
            ),
        }
    })?;

    // 解压 ZIP
    let cursor = Cursor::new(plaintext);
    let mut archive = zip::ZipArchive::new(cursor).map_err(|e| SyncBundleError {
        message: format!("ZIP 解压失败: {e}"),
    })?;

    let mut manifest: serde_json::Value = serde_json::Value::Null;
    let mut table_data: BTreeMap<String, Vec<serde_json::Value>> = BTreeMap::new();
    let mut assets: BTreeMap<String, Vec<u8>> = BTreeMap::new();

    for i in 0..archive.len() {
        let mut file = archive.by_index(i).map_err(|e| SyncBundleError {
            message: format!("读取 ZIP 条目失败: {e}"),
        })?;
        let name = file.name().to_string();

        let mut buf = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut buf).map_err(|e| SyncBundleError {
            message: format!("读取 ZIP 内容失败: {e}"),
        })?;

        if name == "manifest.json" {
            manifest = serde_json::from_slice(&buf).map_err(|e| SyncBundleError {
                message: format!("解析 manifest.json 失败: {e}"),
            })?;
        } else if name.starts_with("data/") && name.ends_with(".jsonl") {
            let table_name = name
                .strip_prefix("data/")
                .and_then(|s| s.strip_suffix(".jsonl"))
                .unwrap_or_default()
                .to_string();
            let content = String::from_utf8_lossy(&buf);
            // JSONL 逐行解析：损坏行跳过并记录日志，避免 Null 进入 merge 后被
            // 当作缺 uuid 的记录触发 "记录缺少 uuid 字段" 错误，掩盖真实损坏位置。
            let records: Vec<serde_json::Value> = content
                .trim()
                .lines()
                .filter(|l| !l.is_empty())
                .filter_map(|l| match serde_json::from_str::<serde_json::Value>(l) {
                    Ok(v) => Some(v),
                    Err(e) => {
                        log::warn!(
                            "[sync_bundle] 跳过损坏的 JSONL 行（表={}）：{} | 行内容前 80 字符: {:?}",
                            table_name,
                            e,
                            l.chars().take(80).collect::<String>()
                        );
                        None
                    }
                })
                .collect();
            table_data.insert(table_name, records);
        } else if name.starts_with("assets/") && name.ends_with(".bin") {
            let hash = name
                .strip_prefix("assets/")
                .and_then(|s| s.strip_suffix(".bin"))
                .unwrap_or_default()
                .to_string();
            assets.insert(hash, buf);
        }
    }

    Ok(BundleContent {
        header,
        manifest,
        table_data,
        assets,
    })
}
