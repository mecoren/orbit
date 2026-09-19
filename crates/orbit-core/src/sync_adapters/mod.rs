pub mod http_client;
pub mod s3_adapter;
pub mod traits;
pub mod webdav_adapter;

pub use traits::{RemoteFile, SyncAdapter};
