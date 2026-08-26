//! CEK（Config Encryption Key）提供者
//!
//! CEK 是 32 字节随机密钥，用于加密本地配置文件。
//! 与同步密码派生的 Data Key 解耦：Data Key 依赖用户输入密码解锁，
//! 而 CEK 由 OS 安全存储保护，应用启动早期即可使用。
//!
//! 桌面端实现：KeyringCekProvider（在 desktop/src-tauri 中实现，使用 Tauri keyring）
//! 移动端实现：通过 FRB 回调到 Dart flutter_secure_storage
//! 测试实现：InMemoryCekProvider（内存 OnceLock）

use crate::config_enc::error::ConfigEncResult;
use crate::crypto::random::random_bytes;

/// CEK 长度（AES-256 需要 32 字节密钥）
pub const CEK_LEN: usize = 32;

/// CEK 提供者 trait
///
/// 实现方负责从 OS 安全存储读取或首次生成 CEK。
/// CEK 不应被持久化到普通文件，仅由 OS 安全存储保管。
pub trait CekProvider: Send + Sync {
    /// 获取或创建 CEK
    ///
    /// 首次调用时若 OS 安全存储中不存在 CEK，则生成新的 32 字节随机数并存储。
    /// 后续调用返回已存在的 CEK。
    fn get_or_create(&self) -> ConfigEncResult<[u8; CEK_LEN]>;

    /// 检查 CEK 是否可用（不创建）
    ///
    /// 用于启动时诊断：若返回 false，应用应降级为明文模式并提示用户。
    fn is_available(&self) -> bool;
}

/// 内存 CEK 提供者（仅供测试）
///
/// 首次访问时生成 CEK 并缓存于 OnceLock，跨调用复用同一 CEK。
pub struct InMemoryCekProvider {
    cek: std::sync::OnceLock<[u8; CEK_LEN]>,
}

impl InMemoryCekProvider {
    pub fn new() -> Self {
        Self {
            cek: std::sync::OnceLock::new(),
        }
    }

    /// 测试用：用指定 CEK 构造（用于跨实例共享同一 CEK 的测试场景）
    pub fn with_cek(cek: [u8; CEK_LEN]) -> Self {
        let lock = std::sync::OnceLock::new();
        let _ = lock.set(cek);
        Self { cek: lock }
    }
}

impl Default for InMemoryCekProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl CekProvider for InMemoryCekProvider {
    fn get_or_create(&self) -> ConfigEncResult<[u8; CEK_LEN]> {
        Ok(*self.cek.get_or_init(|| {
            let bytes = random_bytes(CEK_LEN);
            let mut arr = [0u8; CEK_LEN];
            arr.copy_from_slice(&bytes);
            arr
        }))
    }

    fn is_available(&self) -> bool {
        true
    }
}

/// 生成新 CEK（32 字节随机数）
pub fn generate_cek() -> [u8; CEK_LEN] {
    let bytes = random_bytes(CEK_LEN);
    let mut arr = [0u8; CEK_LEN];
    arr.copy_from_slice(&bytes);
    arr
}
