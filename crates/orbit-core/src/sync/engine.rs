//! engine — 云端适配器构造与配置校验
//!
//! 提供 S3/WebDAV 适配器构造能力，供云端备份（full_sync_backup_api）、
//! 云端增量同步（cloud_sync 经 BasePathAdapter）与连接测试复用。
//!
//! 注：v1 全量主流程式同步已移除；现行增量云同步见 crate::cloud_sync。

use serde::{Deserialize, Serialize};

use crate::s3::url::{endpoint_problem, infer_use_path_style};
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
    /// F80（2026-10-01 第六轮）：S3 STS 临时凭据的会话令牌（空 = 不使用）。
    /// 非空时签名纳入 `x-amz-security-token`（canonical/signed headers 与
    /// 实际请求头同步）。WebDAV 忽略此字段。
    #[serde(default)]
    pub session_token: String,
}

/// 创建同步适配器
pub fn create_adapter(config: &SyncConfig) -> Result<Box<dyn SyncAdapter>, SyncError> {
    // 兜底：`create_adapter` 也是备份/GC 等不经 `validate_config` 的入口，
    // 残缺 endpoint 必须在构造期拦下，不能让它拼出 `<bucket>.https` 这类
    // 不存在的主机再报「网络错误」（详见 `s3::url::endpoint_problem` 注释）
    if let Some(problem) = endpoint_problem(&config.endpoint) {
        return Err(SyncError::Config {
            field: "endpoint".to_string(),
            message: problem,
        });
    }
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
                session_token: config.session_token.clone(),
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
    // F80：全空白（空格/换行/制表符）与空串等价拒绝——纯空白的 endpoint 拼进
    // URL 产生的请求与服务端错误毫无关联，排查成本远高于配置期拦截
    if config.endpoint.trim().is_empty() {
        return Err(SyncError::Config {
            field: "endpoint".to_string(),
            message: "endpoint 不能为空".to_string(),
        });
    }
    // 结构自检（2026-11-10）：只填到 `https://` / `https` 这类残缺输入会被
    // virtual-hosted-style 拼成 `https://<bucket>.https/`，报错是「网络错误」
    // ——与真实配置毫无关系。配置期拦下并给出正确形态示例。
    if let Some(problem) = endpoint_problem(&config.endpoint) {
        return Err(SyncError::Config {
            field: "endpoint".to_string(),
            message: format!("endpoint 无效：{problem}"),
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
    // region 参与 SigV4 credential scope，漏填时所有签名请求必然 403，
    // 且错误是裸 XML 难以自助定位——配置阶段拦截给出可读提示（07 排查报告 P0-4）
    if config.adapter_type == "s3" && config.region.trim().is_empty() {
        return Err(SyncError::Config {
            field: "region".to_string(),
            message: "S3 region 不能为空（如 us-east-1 / cn-shenzhen / minio 默认 us-east-1）"
                .to_string(),
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
            session_token: String::new(),
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
            session_token: String::new(),
        }
    }

    #[test]
    fn validate_config_accepts_valid_s3() {
        assert!(validate_config(&valid_s3_config()).is_ok());
    }

    /// F80：全空白 endpoint 与空串等价拒绝——纯空白拼进 URL 的报错与
    /// 服务端无关，排查成本远高于配置期拦截
    #[test]
    fn validate_config_rejects_whitespace_only_endpoint() {
        let mut c = valid_s3_config();
        c.endpoint = "   	
"
        .to_string();
        let err = validate_config(&c).expect_err("全空白 endpoint 必须被拒");
        assert!(
            err.to_string().contains("endpoint"),
            "错误须指明字段: {err}"
        );
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

    #[test]
    fn validate_config_rejects_empty_region_for_s3() {
        // P0-4：region 参与 SigV4 credential scope，漏填时所有签名请求必然 403，
        // 配置阶段拦截（错误信息可读）优于运行期裸 XML 403
        let mut cfg = valid_s3_config();
        cfg.region = String::new();
        let err = validate_config(&cfg).unwrap_err();
        assert!(matches!(err, SyncError::Config { field, .. } if field == "region"));

        // 仅空白同样拒绝
        let mut cfg = valid_s3_config();
        cfg.region = "  ".to_string();
        assert!(validate_config(&cfg).is_err());
    }

    // ========================================================================
    // endpoint 残缺输入（2026-11-10 移动端实测）
    //
    // Endpoint 只填到 scheme（`https://` / `https` / `HTTPS://`）时，此前校验
    // 只看「非空」放行，virtual-hosted-style 拼出 `https://<bucket>.https/`，
    // 用户对着一个正确的 OSS 地址收到「网络错误: GET 请求失败」。
    // ========================================================================

    #[test]
    fn validate_config_rejects_truncated_endpoint() {
        for bad in [
            "https://",
            "https",
            "HTTPS://",
            "ftp://oss-cn-shenzhen.aliyuncs.com",
        ] {
            let mut cfg = valid_s3_config();
            cfg.endpoint = bad.to_string();
            let err = validate_config(&cfg).expect_err("残缺 endpoint 必须在配置期拦下");
            match err {
                SyncError::Config { field, message } => {
                    assert_eq!(field, "endpoint", "错误须指向 endpoint 字段（输入: {bad}）");
                    assert!(
                        message.contains("endpoint 无效"),
                        "提示须可自助修复，实际: {message}"
                    );
                }
                other => panic!("应为配置错误，实际: {other:?}"),
            }
        }
    }

    #[test]
    fn validate_config_accepts_oss_virtual_hosted_endpoint_with_trailing_slash() {
        // 移动端实测配方：OSS 默认域名 + 尾斜杠 + 大写 scheme 都算合法
        for ok in [
            "https://oss-cn-shenzhen.aliyuncs.com/",
            "https://oss-cn-shenzhen.aliyuncs.com",
            "HTTPS://oss-cn-shenzhen.aliyuncs.com/",
        ] {
            let mut cfg = valid_s3_config();
            cfg.endpoint = ok.to_string();
            assert!(validate_config(&cfg).is_ok(), "应通过校验: {ok}");
        }
    }

    #[test]
    fn create_adapter_rejects_truncated_endpoint_without_validate() {
        // 备份/GC 等入口可能不经 validate_config：构造层必须自己兜住，
        // 否则会带着 `https://<bucket>.https/` 出去发请求
        let mut cfg = valid_s3_config();
        cfg.endpoint = "https://".to_string();
        match create_adapter(&cfg) {
            Ok(_) => panic!("构造层必须拦下残缺 endpoint"),
            Err(err) => {
                assert!(matches!(err, SyncError::Config { field, .. } if field == "endpoint"));
            }
        }
    }
}
