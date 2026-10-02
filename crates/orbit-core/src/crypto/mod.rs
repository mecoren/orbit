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
pub use key_derivation::{MIN_KDF_ITERATIONS, derive_master_key, ensure_kdf_strength};
pub use master_auth::{
    ITERATIONS as MASTER_AUTH_ITERATIONS, MasterAuthMeta, change_master_auth_password,
    db_key_to_hex, init_master_auth, is_legacy_v1_format, unlock_master_auth, verify_master_auth,
};
pub use random::random_bytes;
pub use sha256::sha256_hex;
