use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncBundleError {
    pub message: String,
}

impl std::fmt::Display for SyncBundleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SyncBundleError: {}", self.message)
    }
}

impl std::error::Error for SyncBundleError {}
