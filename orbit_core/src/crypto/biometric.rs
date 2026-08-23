//! biometric — 生物识别密钥链解密
//!
//! 提供 `biometric_unlock_db_key`，将 Dart 侧 `BiometricService.unlockWithBiometric`
//! 的密钥链解密逻辑下沉到 Rust。
//!
//! 密钥链结构（与 Dart 侧一致）：
//! ```text
//! 指纹认证（local_auth 闸门，不参与密钥派生）
//!   └─► Secure Storage 取回 Biometric Key (32B 随机)
//!         └─► AES-256-GCM 解密 encrypted_db_key_bio → DB Key (32B)
//!               └─► db_key_to_hex → 64 字符 hex（供 SQLCipher PRAGMA key）
//! ```
//!
//! 与 master_auth 的区别：Biometric Key 是纯随机字节，不经过 PBKDF2 派生，
//! 因此解密时无需 salt/iterations，直接用 Biometric Key 作为 AES-256 密钥。

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};

use super::aes_gcm::aes_gcm_decrypt;
use super::error::{CryptoError, CryptoErrorKind};
use super::master_auth::db_key_to_hex;

/// Biometric Key 长度（字节，32 = AES-256）
const BIOMETRIC_KEY_LEN: usize = 32;

/// 使用 Biometric Key 解密 encrypted_db_key_bio，返回 DB Key hex 字符串
///
/// 纯计算函数（无 I/O），替代 Dart 侧 `BiometricService.unlockWithBiometric` 的解密编排。
/// Dart 侧仅用 `local_auth` 采集指纹闸门，通过后从 Secure Storage 读取三个 Base64 值传入本函数。
///
/// # 参数（均为 Base64 standard 编码，来自 Secure Storage）
/// - `encrypted_db_key_base64`：AES-256-GCM 密文（ciphertext || tag，48 字节解码后）
/// - `biometric_key_base64`：32 字节 Biometric Key
/// - `nonce_base64`：12 字节 nonce
///
/// # 返回
/// - `Ok(String)`：64 字符小写 hex 字符串（与 `unlock_master_auth` 输出格式一致，
///   供 `dbInitEncrypted(dbKeyHex)` 无差别消费）
/// - `Err(CryptoError)`：Base64 解码失败或 GCM tag 校验失败（密钥/数据损坏）
///
/// # 兼容性
/// 不改变存储格式，迁移前后对同一 Biometric Key 解密结果必须一致。
/// 与 Dart 侧 `cryptoAesGcmDecrypt` + `db_key_to_hex` 调用链完全等价。
pub fn biometric_unlock_db_key(
    encrypted_db_key_base64: &str,
    biometric_key_base64: &str,
    nonce_base64: &str,
) -> Result<String, CryptoError> {
    // 1. Base64 解码三个输入（与 unlock_master_auth 的解码模式一致）
    let biometric_key = BASE64
        .decode(biometric_key_base64)
        .map_err(|e| CryptoError {
            message: format!("decode biometric_key failed: {}", e),
            kind: CryptoErrorKind::InvalidKeyLength,
        })?;

    if biometric_key.len() != BIOMETRIC_KEY_LEN {
        return Err(CryptoError {
            message: format!(
                "biometric_key length mismatch: expected {}, got {}",
                BIOMETRIC_KEY_LEN,
                biometric_key.len()
            ),
            kind: CryptoErrorKind::InvalidKeyLength,
        });
    }

    let encrypted_db_key = BASE64
        .decode(encrypted_db_key_base64)
        .map_err(|e| CryptoError {
            message: format!("decode encrypted_db_key failed: {}", e),
            kind: CryptoErrorKind::InvalidKeyLength,
        })?;

    let nonce = BASE64.decode(nonce_base64).map_err(|e| CryptoError {
        message: format!("decode nonce failed: {}", e),
        kind: CryptoErrorKind::InvalidNonceLength,
    })?;

    // 2. AES-256-GCM 解密（内部校验 key=32, nonce=12，GCM tag 校验失败返回 DecryptionFailed）
    let db_key = aes_gcm_decrypt(&biometric_key, &encrypted_db_key, &nonce)?;

    // 3. 字节转 hex 字符串（复用 master_auth::db_key_to_hex，保证与主密码解锁路径输出格式一致）
    Ok(db_key_to_hex(&db_key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::aes_gcm::aes_gcm_encrypt;
    use crate::crypto::random::random_bytes;

    #[test]
    fn biometric_unlock_roundtrip() {
        // 模拟 Dart 侧 enableBiometricUnlock 的加密过程
        let biometric_key = random_bytes(BIOMETRIC_KEY_LEN);
        let db_key = random_bytes(32);
        let nonce = random_bytes(12);
        let encrypted_db_key = aes_gcm_encrypt(&biometric_key, &db_key, &nonce).unwrap();

        // 转 Base64（与 Secure Storage 存储格式一致）
        let enc_b64 = BASE64.encode(&encrypted_db_key);
        let key_b64 = BASE64.encode(&biometric_key);
        let nonce_b64 = BASE64.encode(&nonce);

        // 解密并验证
        let db_key_hex = biometric_unlock_db_key(&enc_b64, &key_b64, &nonce_b64).unwrap();
        let expected_hex = db_key_to_hex(&db_key);
        assert_eq!(db_key_hex, expected_hex);
        assert_eq!(db_key_hex.len(), 64);
    }

    #[test]
    fn biometric_unlock_wrong_key_fails() {
        let biometric_key = random_bytes(BIOMETRIC_KEY_LEN);
        let wrong_key = random_bytes(BIOMETRIC_KEY_LEN);
        let db_key = random_bytes(32);
        let nonce = random_bytes(12);
        let encrypted_db_key = aes_gcm_encrypt(&biometric_key, &db_key, &nonce).unwrap();

        let enc_b64 = BASE64.encode(&encrypted_db_key);
        let wrong_key_b64 = BASE64.encode(&wrong_key);
        let nonce_b64 = BASE64.encode(&nonce);

        // 错误的 Biometric Key 应导致 GCM tag 校验失败
        let result = biometric_unlock_db_key(&enc_b64, &wrong_key_b64, &nonce_b64);
        assert!(result.is_err());
    }

    #[test]
    fn biometric_unlock_wrong_length_key_rejected() {
        let short_key = random_bytes(16); // 错误长度
        let enc_b64 = BASE64.encode(b"fake");
        let key_b64 = BASE64.encode(&short_key);
        let nonce_b64 = BASE64.encode(b"fake");

        let result = biometric_unlock_db_key(&enc_b64, &key_b64, &nonce_b64);
        assert!(result.is_err());
    }

    #[test]
    fn biometric_unlock_invalid_base64_fails() {
        let result = biometric_unlock_db_key("!!!not-base64!!!", "AAEC", "AAEC");
        assert!(result.is_err());
    }
}
