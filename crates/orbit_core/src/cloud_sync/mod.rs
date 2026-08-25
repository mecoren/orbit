//! cloud_sync — 云端增量同步引擎
//!
//! 在现有同步基础设施（`SyncAdapter` + `SyncCryptoService`）之上实现模块级增量同步：
//! - 按 14 个业务大类做模块级指纹（sha256 of canonical JSON）增量上传
//! - Pull 时按 `uuid` 做 item 级 LWW（Last-Writer-Wins）合并
//! - 附件走 `media/<sha256>` 内容寻址去重，全部用 Data Key AES-256-GCM 加密
//!
//! 模块分层：
//! ```text
//! cloud_sync/
//! ├── mod.rs          本文件：模块导出 + SyncEngine 主结构（M1.12）
//! ├── error.rs        CloudSyncError
//! ├── modules.rs      14 个 SyncModuleDef 静态注册表
//! ├── fingerprint.rs  canonical JSON + sha256 指纹（M1.3）
//! ├── crypto_io.rs    encrypt_payload / decrypt_payload（M1.4）
//! ├── meta.rs         GlobalMeta / ModuleMeta 读写（M1.5）
//! ├── state.rs        SyncStateStore（sync_state.json）（M1.6）
//! ├── progress.rs     SyncProgress 事件 + ProgressSender（M1.7）
//! ├── push.rs         push_all() 流程（M1.8）
//! ├── pull.rs         pull_all() 流程（M1.9）
//! ├── merge.rs        merge_items() LWW 合并 + 墓碑应用（M1.10）
//! └── attachments.rs  附件同步（push/pull，Semaphore 4 并发）（M1.11）
//! ```
//!
//! 设计参考：BeeCount 的 webdav/s3 模块级同步（transactions_sync_manager.dart）。

pub mod attachments;
pub mod crypto_io;
pub mod db_loader;
pub mod engine;
pub mod error;
pub mod fingerprint;
pub mod merge;
pub mod meta;
pub mod modules;
pub mod paths;
pub mod progress;
pub mod pull;
pub mod push;
pub mod state;

pub use attachments::{sync_attachments_pull, sync_attachments_push, AttachmentSyncResult};
pub use crypto_io::{decrypt_payload, encrypt_payload};
pub use engine::{SyncEngine, SyncResult};
pub use error::CloudSyncError;
pub use fingerprint::compute_fingerprint;
pub use merge::{merge_items, MergeResult};
pub use meta::{GlobalMeta, ModuleData, ModuleMetaEntry, TombstoneEntry};
pub use modules::{SyncModuleDef, SYNC_MODULES, find_module};
pub use progress::{NoopProgressSender, ProgressSender, SyncProgress};
pub use pull::{download_attachment, pull_all, PullResult};
pub use push::{push_all, upload_attachment, PushResult};
pub use state::{ModuleSyncState, SyncState, SyncStateStore};
