use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CryptoErrorKind {
    DerivationFailed,
    EncryptionFailed,
    DecryptionFailed,
    InvalidKeyLength,
    InvalidNonceLength,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CryptoError {
    pub message: String,
    pub kind: CryptoErrorKind,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CryptoError({:?}): {}", self.kind, self.message)
    }
}

impl std::error::Error for CryptoError {}
