use pbkdf2::pbkdf2_hmac;
use sha2::Sha256;

use super::error::{CryptoError, CryptoErrorKind};

/// 外部来源 KDF 迭代次数下限（F33）
///
/// 取历史最小值 200k（而非当前 `ITERATIONS` 600k）：存量用户的云端
/// `crypto/config` 与 `.orfullsync` 备份可能仍写着 200k，下限抬高到 600k
/// 会把他们直接挡在门外。与 `sync_crypto::service::LEGACY_ITERATIONS`
/// 数值相同但语义不同（一个是「可接受下限」，一个是「已知待升级旧值」），
/// 故刻意不共用常量。
pub const MIN_KDF_ITERATIONS: u32 = 200_000;

/// 校验**不可信来源**的迭代次数（F33：AGENTS.md「PBKDF2 单调不降级」的实现处）
///
/// 调用点判据：iterations 来自云端 `crypto/config`（明文 JSON，存储端可改）、
/// `.orfullsync` 文件头或本地 meta 文件——攻击者把它们降到 1 次迭代，
/// 就等于把口令派生降级为可暴破。载荷本身有 GCM tag，因此这是纵深防御
/// 而非当场可利用的漏洞。
///
/// 不挂在 `derive_master_key` 上：v2 密钥方案用 `iterations=1` 做 salt
/// 域分离扩展（`sync_crypto::service::derive_data_key_v2`），那是 KDF 当
/// 哈希用、不涉及口令强度，全局下限会打断它。
pub fn ensure_kdf_strength(iterations: u32, source: &str) -> Result<(), CryptoError> {
    if iterations < MIN_KDF_ITERATIONS {
        return Err(CryptoError {
            message: format!(
                "{source} 声明的 PBKDF2 迭代次数 {iterations} 低于下限 {MIN_KDF_ITERATIONS}，\
                 拒绝派生（防密钥降级）"
            ),
            kind: CryptoErrorKind::DerivationFailed,
        });
    }
    Ok(())
}

/// PBKDF2-HMAC-SHA256 密钥派生
///
/// 与 Dart `KeyDerivation.deriveMasterKey` 行为完全一致。
pub fn derive_master_key(
    password: &str,
    salt: &[u8],
    iterations: u32,
    key_length: usize,
) -> Result<Vec<u8>, CryptoError> {
    if iterations == 0 {
        return Err(CryptoError {
            message: "iterations must be > 0".to_string(),
            kind: CryptoErrorKind::DerivationFailed,
        });
    }
    let mut out = vec![0u8; key_length];
    pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, iterations, &mut out);
    Ok(out)
}
