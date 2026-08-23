use aes_gcm::aead::KeyInit;
use aes_gcm::{Aes256Gcm, Key, Nonce, aead::Aead};

use super::error::{CryptoError, CryptoErrorKind};

/// AES-256-GCM 加密
///
/// 返回 ciphertext || tag（16 字节）拼接，与 Dart `GCMBlockCipher.process` 输出格式一致。
/// 这是 CryptoService 中 `_aesGcmEncrypt` 的 Rust 对应实现。
pub fn aes_gcm_encrypt(key: &[u8], plaintext: &[u8], nonce: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if key.len() != 32 {
        return Err(CryptoError {
            message: format!("key must be 32 bytes, got {}", key.len()),
            kind: CryptoErrorKind::InvalidKeyLength,
        });
    }
    if nonce.len() != 12 {
        return Err(CryptoError {
            message: format!("nonce must be 12 bytes, got {}", nonce.len()),
            kind: CryptoErrorKind::InvalidNonceLength,
        });
    }
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher
        .encrypt(Nonce::from_slice(nonce), plaintext)
        .map_err(|e| CryptoError {
            message: format!("encrypt failed: {}", e),
            kind: CryptoErrorKind::EncryptionFailed,
        })
}

/// AES-256-GCM 解密
///
/// 输入 `ciphertext_with_tag` 必须是 ciphertext || tag 拼接格式。
pub fn aes_gcm_decrypt(
    key: &[u8],
    ciphertext_with_tag: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if key.len() != 32 {
        return Err(CryptoError {
            message: format!("key must be 32 bytes, got {}", key.len()),
            kind: CryptoErrorKind::InvalidKeyLength,
        });
    }
    if nonce.len() != 12 {
        return Err(CryptoError {
            message: format!("nonce must be 12 bytes, got {}", nonce.len()),
            kind: CryptoErrorKind::InvalidNonceLength,
        });
    }
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(nonce), ciphertext_with_tag)
        .map_err(|e| CryptoError {
            message: format!("decrypt failed: {}", e),
            kind: CryptoErrorKind::DecryptionFailed,
        })
}
