//! paths — 云端同步文件路径常量与构造函数
//!
//! 集中管理日常云同步（push/pull/attachments）的云端文件路径，避免路径字符串散落。
//!
//! ## 后缀规范
//! 除 `CRYPTO_CONFIG_PATH` 保持无扩展名（用户明确要求）外，其余日常云同步文件
//! 统一使用 `.waitsync` 扩展名，与项目记忆约束 "Sync bundles must use .waitsync" 对齐。
//!
//! ## 路径分布（base_path 之下）
//! ```text
//! crypto/config                          # 加密元数据（无扩展名）
//! _meta.waitsync                         # 全局索引
//! modules/{name}/data.waitsync           # 模块数据
//! modules/{name}/meta.waitsync           # 模块元数据
//! assets/{hash}.waitsync                 # 附件（< 8MiB 密文单对象）
//! assets_parts/{hash}/head.json         # 附件分片清单（S4，仅 WebDAV：
//!                                        #   ≥ 8MiB 密文分片形态；S3 走原生
//!                                        #   multipart，Complete 后对象仍落
//!                                        #   assets/{hash}.waitsync 原路径）
//! assets_parts/{hash}/{index:06}.bin     # 附件密文分片（5MiB/片）
//! ```

/// 加密元数据路径（保持不变，无扩展名）
///
/// 用户明确要求 `crypto/config` 路径不改名，避免破坏新设备加入流程。
/// 内容为 SyncCryptoMeta JSON（salt + encrypted_data_key + nonce + iterations）。
pub const CRYPTO_CONFIG_PATH: &str = "crypto/config";

/// 全局索引路径
pub const GLOBAL_META_PATH: &str = "_meta.waitsync";

/// 构造模块数据路径：`modules/{name}/data.waitsync`
pub fn module_data_path(name: &str) -> String {
    format!("modules/{name}/data.waitsync")
}

/// 构造模块元数据路径：`modules/{name}/meta.waitsync`
pub fn module_meta_path(name: &str) -> String {
    format!("modules/{name}/meta.waitsync")
}

/// 构造附件路径：`assets/{hash}.waitsync`
pub fn asset_path(hash: &str) -> String {
    format!("assets/{hash}.waitsync")
}

/// 判断同步错误是否表示「资源不存在」（404）
///
/// 委托给 `SyncError::is_not_found()`，保留此函数以维持调用方兼容。
pub fn is_not_found_error(err: &crate::sync::error::SyncError) -> bool {
    err.is_not_found()
}
