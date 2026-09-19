use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};

use super::error::{CryptoError, CryptoErrorKind};

/// AES-256-GCM 加密（无 AAD）
///
/// 返回 ciphertext || tag（16 字节）拼接，与 Dart `GCMBlockCipher.process` 输出格式一致。
/// 这是 CryptoService 中 `_aesGcmEncrypt` 的 Rust 对应实现。
pub fn aes_gcm_encrypt(key: &[u8], plaintext: &[u8], nonce: &[u8]) -> Result<Vec<u8>, CryptoError> {
    aes_gcm_encrypt_aad(key, plaintext, nonce, b"")
}

/// AES-256-GCM 加密（带 AAD）
///
/// AAD（附加认证数据）参与 tag 计算但**不加密、不随载荷传输**：解密方必须
/// 提供逐字节相同的 AAD，否则 tag 校验失败。用途是把云端对象路径绑进密文，
/// 使「存储端把 A 桶密文搬到 B 桶」当场解不开（ADR 0010）。
pub fn aes_gcm_encrypt_aad(
    key: &[u8],
    plaintext: &[u8],
    nonce: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    check_lengths(key, nonce)?;
    let cipher = build_cipher(key);
    let mut buffer = plaintext.to_vec();
    cipher
        .encrypt_in_place(Nonce::from_slice(nonce), aad, &mut buffer)
        .map_err(|e| CryptoError {
            message: format!("encrypt failed: {}", e),
            kind: CryptoErrorKind::EncryptionFailed,
        })?;
    Ok(buffer)
}

/// AES-256-GCM 解密（无 AAD）
///
/// 输入 `ciphertext_with_tag` 必须是 ciphertext || tag 拼接格式。
pub fn aes_gcm_decrypt(
    key: &[u8],
    ciphertext_with_tag: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    aes_gcm_decrypt_aad(key, ciphertext_with_tag, nonce, b"")
}

/// AES-256-GCM 解密（带 AAD）——AAD 不一致与密钥不一致同样表现为解密失败
pub fn aes_gcm_decrypt_aad(
    key: &[u8],
    ciphertext_with_tag: &[u8],
    nonce: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    check_lengths(key, nonce)?;
    let cipher = build_cipher(key);
    let mut buffer = ciphertext_with_tag.to_vec();
    cipher
        .decrypt_in_place(Nonce::from_slice(nonce), aad, &mut buffer)
        .map_err(|e| CryptoError {
            message: format!("decrypt failed: {}", e),
            kind: CryptoErrorKind::DecryptionFailed,
        })?;
    Ok(buffer)
}

fn build_cipher(key: &[u8]) -> Aes256Gcm {
    Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key))
}

/// 长度前置校验：`Key::from_slice` / `Nonce::from_slice` 对错误长度直接 panic，
/// 调用方传入的是外部可影响的字节，必须先转成可恢复错误。
fn check_lengths(key: &[u8], nonce: &[u8]) -> Result<(), CryptoError> {
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
    Ok(())
}
