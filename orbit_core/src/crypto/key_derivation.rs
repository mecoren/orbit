use pbkdf2::pbkdf2_hmac;
use sha2::Sha256;

use super::error::{CryptoError, CryptoErrorKind};

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
