//! paths — 云端同步文件路径常量与构造函数
//!
//! 集中管理云同步的云端文件路径，避免路径字符串散落。
//!
//! ## 云端布局（初始版本）
//! 单清单 + 表级分桶布局，不保留旧路径回退（曾带来多段回退与每轮额外
//! HEAD/GET 请求，已整体移除）。
//!
//! ```text
//! {base_path}/
//! ├─ crypto/config                        # 加密元数据（无扩展名，跨设备分发 Key）
//! ├─ manifest.orsync                      # 唯一真相源：epoch + 表分桶索引 + 墓碑水位线
//! ├─ tables/{table}/{bucket:02}.orsync    # 表级行分桶（内容寻址式差量上传单元）
//! ├─ tombstones/{table}/{YYYY-MM}.orsync  # 墓碑按本地时区月份分桶（可安全回收）
//! └─ assets/{hash}.orsync                 # 附件内容寻址（≥8MiB 走既有分片/续传通道）
//! ```

/// 加密元数据路径（保持不变，无扩展名）
///
/// 用户明确要求 `crypto/config` 路径不改名，避免破坏新设备加入流程。
/// 内容为 SyncCryptoMeta JSON（salt + encrypted_data_key + nonce + iterations）。
pub const CRYPTO_CONFIG_PATH: &str = "crypto/config";

/// 同步载荷扩展名（唯一格式）
pub const SYNC_EXTENSION: &str = ".orsync";

/// 云端清单路径（唯一真相源）
pub const MANIFEST_PATH: &str = "manifest.orsync";

/// 上一版清单路径（回滚点辅助）
///
/// 每次成功写入新清单前，把上一版清单密文原样另存一份。语义边界：
/// 分桶对象是**按桶号覆盖写**的，因此本文件只能恢复「本次未被覆盖的桶」
/// 的索引视图；它提供的是清单级诊断/辅助回滚，而非完整时间点快照
/// （完整快照由 `.orfullsync` 全量备份承担）。
pub const MANIFEST_PREV_PATH: &str = "manifest.prev.orsync";

/// 表分桶目录前缀
pub const TABLES_DIR: &str = "tables";

/// 墓碑分桶目录前缀
pub const TOMBSTONES_DIR: &str = "tombstones";

/// 附件目录前缀
pub const ASSETS_DIR: &str = "assets";

/// 构造表分桶路径：`tables/{table}/{bucket:02}.orsync`
///
/// `bucket` 为 uuid 稳定哈希取模得到的桶号（见 `chunk::bucket_of_uuid`），
/// 两位零填充便于对象存储按 key 字典序列举。
pub fn table_bucket_path(table: &str, bucket: u32) -> String {
    format!("{TABLES_DIR}/{table}/{bucket:02}{SYNC_EXTENSION}")
}

/// 构造墓碑分桶路径：`tombstones/{table}/{YYYY-MM}.orsync`
///
/// 分桶键为墓碑删除时间（本地时区）的年月字符串，供水位线安全回收。
pub fn tombstone_bucket_path(table: &str, bucket: &str) -> String {
    format!("{TOMBSTONES_DIR}/{table}/{bucket}{SYNC_EXTENSION}")
}

/// 构造附件路径：`assets/{hash}.orsync`
pub fn asset_path(hash: &str) -> String {
    format!("{ASSETS_DIR}/{hash}{SYNC_EXTENSION}")
}

/// 是否为同步载荷路径（仅认 `.orsync`）
pub fn is_sync_payload_name(name: &str) -> bool {
    name.ends_with(SYNC_EXTENSION)
}

/// 剥离同步载荷后缀，供附件 hash 提取复用（无后缀时原样返回）
pub fn strip_sync_extension(name: &str) -> &str {
    name.strip_suffix(SYNC_EXTENSION).unwrap_or(name)
}

/// 判断同步错误是否表示「资源不存在」（404）
///
/// 委托给 `SyncError::is_not_found()`，保留此函数以维持调用方兼容。
pub fn is_not_found_error(err: &crate::sync::error::SyncError) -> bool {
    err.is_not_found()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_bucket_path_is_zero_padded() {
        assert_eq!(
            table_bucket_path("todo_tasks", 7),
            "tables/todo_tasks/07.orsync"
        );
        assert_eq!(
            table_bucket_path("todo_tasks", 63),
            "tables/todo_tasks/63.orsync"
        );
    }

    #[test]
    fn tombstone_bucket_path_uses_month_key() {
        assert_eq!(
            tombstone_bucket_path("todo_tasks", "2026-09"),
            "tombstones/todo_tasks/2026-09.orsync"
        );
    }

    #[test]
    fn manifest_and_asset_paths_are_stable() {
        assert_eq!(MANIFEST_PATH, "manifest.orsync");
        assert_eq!(asset_path("abc123"), "assets/abc123.orsync");
        assert_eq!(CRYPTO_CONFIG_PATH, "crypto/config");
    }

    #[test]
    fn strip_sync_extension_removes_only_known_suffix() {
        assert_eq!(strip_sync_extension("abc.orsync"), "abc");
        assert_eq!(strip_sync_extension("abc"), "abc");
        assert_eq!(strip_sync_extension("abc.waitsync"), "abc.waitsync");
    }

    #[test]
    fn is_sync_payload_name_matches_orsync_only() {
        assert!(is_sync_payload_name("manifest.orsync"));
        assert!(is_sync_payload_name("assets/x.orsync"));
        assert!(!is_sync_payload_name("assets/x.waitsync"));
        assert!(!is_sync_payload_name("assets/x"));
    }
}
