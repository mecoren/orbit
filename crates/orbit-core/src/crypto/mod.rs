pub mod aes_gcm;
pub mod biometric;
pub mod constant_time;
pub mod error;
pub mod key_derivation;
pub mod master_auth;
pub mod random;
pub mod sha256;

pub use aes_gcm::{aes_gcm_decrypt, aes_gcm_encrypt};
pub use constant_time::constant_time_equals;
pub use error::{CryptoError, CryptoErrorKind};
pub use key_derivation::derive_master_key;
pub use master_auth::{
    ITERATIONS as MASTER_AUTH_ITERATIONS, MasterAuthMeta, change_master_auth_password,
    db_key_to_hex, init_master_auth, is_legacy_v1_format, unlock_master_auth, verify_master_auth,
};
pub use random::random_bytes;
pub use sha256::sha256_hex;

/// 从附件哈希派生确定性 nonce（12 字节）
///
/// 与 Dart 侧 `_deriveAssetNonce` 完全一致：
/// hash 形如 "8f4e2a3b...e1f0.jpg"，取 hex 部分前 24 字符（=12 字节）。
/// 不足则右侧补 '0'。
///
/// **安全风险（仅 legacy 路径）**：本函数仅用于 `assets/{hash}.bin` 旧格式回退，
/// 新版本附件统一走 `encrypt_payload`（随机 nonce）。确定性 nonce + 同一 key 加密
/// 不同明文会触发 GCM catastrophic nonce reuse。当前实现遇到非 hex 字符时
/// `unwrap_or(0)` 会将不同 hash 坍缩为相同 nonce，加剧该风险。
///
/// 缓解措施：检测到非 hex 字符时记录告警日志（保持向后兼容的零填充行为，
/// 因为 hash 在正常流程中是 sha256 hex，不应出现非 hex 字符；
/// 一旦出现说明上游 content hash 计算异常，需要排查）。
pub fn derive_asset_nonce(hash: &str) -> [u8; 12] {
    let hex_part = hash.split('.').next().unwrap_or("");
    // 统一使用 String 避免生命周期问题
    let padded: String = if hex_part.len() >= 24 {
        hex_part[..24].to_string()
    } else {
        let mut s = hex_part.to_string();
        while s.len() < 24 {
            s.push('0');
        }
        s
    };

    let mut nonce = [0u8; 12];
    let mut invalid_hex_seen = false;
    for i in 0..12 {
        let start = i * 2;
        let end = start + 2;
        if end <= padded.len() {
            let chunk = &padded[start..end];
            // 检测非 hex 字符：u8::from_str_radix 对非 hex 字符返回 Err，
            // 旧实现 unwrap_or(0) 会将不同非 hex hash 坍缩为相同 nonce，
            // 这里保留 0 填充行为（向后兼容）但记录告警，便于上游排查 content hash 异常
            nonce[i] = match u8::from_str_radix(chunk, 16) {
                Ok(b) => b,
                Err(_) => {
                    invalid_hex_seen = true;
                    0
                }
            };
        }
    }
    if invalid_hex_seen {
        log::warn!(
            "[derive_asset_nonce] hash 含非 hex 字符（前 24 字符: {:?}），\
             nonce 可能发生坍缩导致 GCM nonce 复用风险。建议迁移该资产到 .waitsync 新格式",
            &padded
        );
    }
    nonce
}

/// 加密附件（确定性 nonce，基于 hash）
pub fn encrypt_asset(key: &[u8], plaintext: &[u8], hash: &str) -> Result<Vec<u8>, CryptoError> {
    let nonce = derive_asset_nonce(hash);
    aes_gcm_encrypt(key, plaintext, &nonce)
}

/// 解密附件（与 encrypt_asset 配对）
pub fn decrypt_asset(key: &[u8], ciphertext: &[u8], hash: &str) -> Result<Vec<u8>, CryptoError> {
    let nonce = derive_asset_nonce(hash);
    aes_gcm_decrypt(key, ciphertext, &nonce)
}

#[cfg(test)]
mod asset_tests {
    use super::*;

    #[test]
    fn derive_asset_nonce_truncates_long_hash() {
        let hash = "8f4e2a3b9c1d4e5f60718293a4b5c6d7.jpg";
        let nonce = derive_asset_nonce(hash);
        assert_eq!(nonce[0], 0x8f);
        assert_eq!(nonce[1], 0x4e);
        assert_eq!(nonce[11], 0x93);
    }

    #[test]
    fn derive_asset_nonce_pads_short_hash() {
        let hash = "abc";
        let nonce = derive_asset_nonce(hash);
        assert_eq!(nonce[0], 0xab);
        assert_eq!(nonce[1], 0xc0);
        assert_eq!(nonce[2], 0x00);
        assert_eq!(nonce[11], 0x00);
    }

    #[test]
    fn encrypt_decrypt_asset_roundtrip() {
        let key = [0x42u8; 32];
        let plaintext = b"binary asset content";
        let hash = "aabbccddeeff00112233445566778899.jpg";

        let ciphertext = encrypt_asset(&key, plaintext, hash).unwrap();
        let decrypted = decrypt_asset(&key, &ciphertext, hash).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn encrypt_asset_deterministic_same_hash_same_ciphertext() {
        let key = [0x42u8; 32];
        let plaintext = b"same content";
        let hash = "deadbeef00112233445566778899aabb.jpg";

        let c1 = encrypt_asset(&key, plaintext, hash).unwrap();
        let c2 = encrypt_asset(&key, plaintext, hash).unwrap();
        assert_eq!(c1, c2, "同一 hash 必须产生同一密文");
    }
}
