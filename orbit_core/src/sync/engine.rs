//! engine — 云端备份适配器构造与配置校验
//!
//! 提供 S3/WebDAV 适配器构造能力，供云端备份（full_sync_backup_api）和
//! 同步诊断（sync_diag_api）复用。
//!
//! 云端同步（原 full_sync 主流程）已移除，待未来实现。

use serde::{Deserialize, Serialize};

use crate::s3::url::infer_use_path_style;
use crate::sync::error::SyncError;
use crate::sync_adapters::s3_adapter::{S3Adapter, S3Config};
use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_adapters::webdav_adapter::{WebDavAdapter, WebDavConfig};

/// 同步配置（从 Dart/TS 传入的 JSON 反序列化）
///
/// 云端备份与云端同步共用此配置结构。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncConfig {
    pub adapter_type: String,
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub access_key: String,
    pub secret_key: String,
    pub base_path: String,
    pub device_id: String,
    pub device_name: String,
    /// 请求超时秒数（0 = 默认 30s）
    #[serde(default)]
    pub timeout_secs: u64,
    /// 跳过 TLS 证书校验（自签名证书场景）
    #[serde(default)]
    pub skip_tls_verify: bool,
}

/// 创建同步适配器
pub fn create_adapter(config: &SyncConfig) -> Result<Box<dyn SyncAdapter>, SyncError> {
    match config.adapter_type.as_str() {
        "s3" => {
            let s3_config = S3Config {
                endpoint: config.endpoint.clone(),
                bucket: config.bucket.clone(),
                region: config.region.clone(),
                access_key: config.access_key.clone(),
                secret_key: config.secret_key.clone(),
                // AWS 官方域名与阿里云 OSS 用 virtual-hosted-style，其余（MinIO/自建）用 path-style
                use_path_style: infer_use_path_style(&config.endpoint),
                timeout_secs: config.timeout_secs,
                skip_tls_verify: config.skip_tls_verify,
            };
            Ok(Box::new(S3Adapter::new(s3_config)?))
        }
        "webdav" => {
            let webdav_config = WebDavConfig {
                server_url: config.endpoint.clone(),
                username: config.access_key.clone(),
                password: config.secret_key.clone(),
                timeout_secs: config.timeout_secs,
                skip_tls_verify: config.skip_tls_verify,
            };
            Ok(Box::new(WebDavAdapter::new(webdav_config)?))
        }
        _ => Err(SyncError::Config {
            field: "adapter_type".to_string(),
            message: format!("不支持的适配器类型: {}", config.adapter_type),
        }),
    }
}

/// 校验同步配置
pub fn validate_config(config: &SyncConfig) -> Result<(), SyncError> {
    if config.endpoint.is_empty() {
        return Err(SyncError::Config {
            field: "endpoint".to_string(),
            message: "endpoint 不能为空".to_string(),
        });
    }
    if config.device_id.is_empty() {
        return Err(SyncError::Config {
            field: "device_id".to_string(),
            message: "device_id 不能为空".to_string(),
        });
    }
    if config.adapter_type == "s3" && config.bucket.is_empty() {
        return Err(SyncError::Config {
            field: "bucket".to_string(),
            message: "S3 bucket 不能为空".to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造合法的 S3 配置
    fn valid_s3_config() -> SyncConfig {
        SyncConfig {
            adapter_type: "s3".to_string(),
            endpoint: "https://s3.amazonaws.com".to_string(),
            bucket: "my-bucket".to_string(),
            region: "us-east-1".to_string(),
            access_key: "ak".to_string(),
            secret_key: "sk".to_string(),
            base_path: "wait-home".to_string(),
            device_id: "device-001".to_string(),
            device_name: "Test".to_string(),
            timeout_secs: 0,
            skip_tls_verify: false,
        }
    }

    /// 构造合法的 WebDAV 配置
    fn valid_webdav_config() -> SyncConfig {
        SyncConfig {
            adapter_type: "webdav".to_string(),
            endpoint: "https://dav.example.com/path".to_string(),
            bucket: String::new(),
            region: String::new(),
            access_key: "user".to_string(),
            secret_key: "pass".to_string(),
            base_path: "wait-home".to_string(),
            device_id: "device-002".to_string(),
            device_name: "Test".to_string(),
            timeout_secs: 0,
            skip_tls_verify: false,
        }
    }

    #[test]
    fn validate_config_accepts_valid_s3() {
        assert!(validate_config(&valid_s3_config()).is_ok());
    }

    #[test]
    fn validate_config_accepts_valid_webdav() {
        assert!(validate_config(&valid_webdav_config()).is_ok());
    }

    #[test]
    fn validate_config_rejects_empty_endpoint() {
        let mut cfg = valid_s3_config();
        cfg.endpoint = String::new();
        let err = validate_config(&cfg).unwrap_err();
        assert!(matches!(err, SyncError::Config { field, .. } if field == "endpoint"));
    }

    #[test]
    fn validate_config_rejects_empty_device_id() {
        let mut cfg = valid_s3_config();
        cfg.device_id = String::new();
        let err = validate_config(&cfg).unwrap_err();
        assert!(matches!(err, SyncError::Config { field, .. } if field == "device_id"));
    }

    #[test]
    fn validate_config_rejects_empty_bucket_for_s3() {
        let mut cfg = valid_s3_config();
        cfg.bucket = String::new();
        let err = validate_config(&cfg).unwrap_err();
        assert!(matches!(err, SyncError::Config { field, .. } if field == "bucket"));
    }

    #[test]
    fn validate_config_allows_empty_bucket_for_webdav() {
        // WebDAV 不需要 bucket，空值应通过校验
        let cfg = valid_webdav_config();
        assert!(validate_config(&cfg).is_ok());
    }
}
