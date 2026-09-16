//! paths — 云端同步文件路径常量与构造函数
//!
//! 集中管理日常云同步（push/pull/attachments）的云端文件路径，避免路径字符串散落。
//!
//! ## 后缀规范（2026-09-16 起）
//! 除 `CRYPTO_CONFIG_PATH` 保持无扩展名（用户明确要求）外，其余日常云同步文件
//! 统一使用 `.orsync` 扩展名（默认格式）；全量备份包使用 `.orfullsync`（见
//! `full_sync_backup::backup_naming`）。`.waitsync` / 裸 hash 仅作读侧兼容。
//!
//! ## 路径分布（base_path 之下）
//! ```text
//! crypto/config                          # 加密元数据（无扩展名）
//! _meta.orsync                           # 全局索引
//! modules/{name}/data.orsync             # 模块数据
//! modules/{name}/meta.orsync             # 模块元数据
//! assets/{hash}.orsync                   # 附件（< 8MiB 密文单对象）
//! assets_parts/{hash}/head.json         # 附件分片清单（S4，仅 WebDAV：
//!                                        #   ≥ 8MiB 密文分片形态；S3 走原生
//!                                        #   multipart，Complete 后对象仍落
//!                                        #   assets/{hash}.orsync 原路径）
//! assets_parts/{hash}/{index:06}.bin     # 附件密文分片（5MiB/片）
//! ```

/// 加密元数据路径（保持不变，无扩展名）
///
/// 用户明确要求 `crypto/config` 路径不改名，避免破坏新设备加入流程。
/// 内容为 SyncCryptoMeta JSON（salt + encrypted_data_key + nonce + iterations）。
pub const CRYPTO_CONFIG_PATH: &str = "crypto/config";

/// 日常同步默认扩展名：`.orsync`
pub const SYNC_EXTENSION: &str = ".orsync";

/// 日常同步遗留扩展名：`.waitsync`（读侧兼容，不再写入）
pub const LEGACY_SYNC_EXTENSION: &str = ".waitsync";

/// 全局索引路径
pub const GLOBAL_META_PATH: &str = "_meta.orsync";

/// 遗留全局索引路径（读侧回退用）
pub const LEGACY_GLOBAL_META_PATH: &str = "_meta.waitsync";

/// 构造模块数据路径：`modules/{name}/data.orsync`
pub fn module_data_path(name: &str) -> String {
    format!("modules/{name}/data{SYNC_EXTENSION}")
}

/// 遗留模块数据路径：`modules/{name}/data.waitsync`（读侧回退用）
pub fn legacy_module_data_path(name: &str) -> String {
    format!("modules/{name}/data{LEGACY_SYNC_EXTENSION}")
}

/// 构造模块元数据路径：`modules/{name}/meta.orsync`
pub fn module_meta_path(name: &str) -> String {
    format!("modules/{name}/meta{SYNC_EXTENSION}")
}

/// 遗留模块元数据路径：`modules/{name}/meta.waitsync`（读侧回退用）
pub fn legacy_module_meta_path(name: &str) -> String {
    format!("modules/{name}/meta{LEGACY_SYNC_EXTENSION}")
}

/// 构造附件路径：`assets/{hash}.orsync`
pub fn asset_path(hash: &str) -> String {
    format!("assets/{hash}{SYNC_EXTENSION}")
}

/// 遗留附件路径：`assets/{hash}.waitsync`（读侧回退用）
pub fn legacy_asset_path(hash: &str) -> String {
    format!("assets/{hash}{LEGACY_SYNC_EXTENSION}")
}

/// 是否为同步载荷路径（新 `.orsync` 或遗留 `.waitsync` 均认可，读侧兼容）
pub fn is_sync_payload_name(name: &str) -> bool {
    name.ends_with(SYNC_EXTENSION) || name.ends_with(LEGACY_SYNC_EXTENSION)
}

/// 剥离同步载荷后缀（`.orsync` 优先，其次 `.waitsync`），供附件 hash 提取复用
pub fn strip_sync_extension(name: &str) -> &str {
    name.strip_suffix(SYNC_EXTENSION)
        .or_else(|| name.strip_suffix(LEGACY_SYNC_EXTENSION))
        .unwrap_or(name)
}

/// 判断同步错误是否表示「资源不存在」（404）
///
/// 委托给 `SyncError::is_not_found()`，保留此函数以维持调用方兼容。
pub fn is_not_found_error(err: &crate::sync::error::SyncError) -> bool {
    err.is_not_found()
}
