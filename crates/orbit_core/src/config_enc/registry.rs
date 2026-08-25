//! config_enc::registry — 全局加密存储注册表
//!
//! 提供 `EncryptedConfigStorage` 的全局单例注册机制。
//! 应用启动时（Tauri setup / Flutter main）调用 `set_global_storage` 注册存储实例，
//! 核心层（如 `full_sync_backup_api`、`backup_prefs`）通过 `get_global_storage` 或
//! `try_with_global_storage` 检查是否可用，自动路由到加密读写或明文降级。
//!
//! 设计动机：核心层 API（如 `load_prefs(app_data_dir)`）不持有 `EncryptedConfigStorage`
//! 引用，但需要在加密可用时自动使用加密存储。全局注册表避免修改所有核心 API 签名。

use std::sync::OnceLock;

use crate::config_enc::storage::EncryptedConfigStorage;

/// 全局存储实例（启动时设置一次，此后只读）
static GLOBAL_STORAGE: OnceLock<EncryptedConfigStorage> = OnceLock::new();

/// 注册全局加密存储实例
///
/// 应在应用启动早期（Tauri setup / Flutter main）调用。
/// 重复调用会被忽略（返回 `Err`），首次设置的实例终身有效。
///
/// 传入 `None` 可显式标记"加密不可用"，但通常不调用本函数即可达到相同效果。
pub fn set_global_storage(storage: EncryptedConfigStorage) -> Result<(), EncryptedConfigStorage> {
    GLOBAL_STORAGE.set(storage)
}

/// 获取全局加密存储实例（若已注册）
pub fn get_global_storage() -> Option<&'static EncryptedConfigStorage> {
    GLOBAL_STORAGE.get()
}

/// 尝试用全局存储执行闭包；若未注册则返回 None
///
/// 便于核心层简洁地走"加密优先，明文降级"路径：
/// ```ignore
/// if let Some(result) = try_with_global_storage(|s| s.load::<T>("name")) {
///     return result.map_err(...)?;
/// }
/// // 降级到明文...
/// ```
pub fn try_with_global_storage<F, R>(f: F) -> Option<R>
where
    F: FnOnce(&EncryptedConfigStorage) -> R,
{
    GLOBAL_STORAGE.get().map(f)
}
