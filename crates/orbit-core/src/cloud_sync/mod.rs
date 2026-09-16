//! cloud_sync — 云端增量同步引擎
//!
//! 在现有同步基础设施（`SyncAdapter` + `SyncCryptoService`）之上实现模块级增量同步：
//! - 按模块做模块级指纹（sha256 of canonical JSON）增量上传（Orbit MVP 单模块 todos，
//!   覆盖全部可同步业务表，见 modules.rs 与 db::sync_registry 的不变量测试）
//! - Pull 时按 `uuid` 做 item 级 LWW（Last-Writer-Wins）合并
//! - 附件走 `assets/<sha256>.orsync` 内容寻址去重，全部用 Data Key AES-256-GCM 加密
//!
//! 模块分层：
//! ```text
//! cloud_sync/
//! ├── mod.rs          本文件：模块导出
//! ├── engine.rs       SyncEngine 主结构：三模式编排 + 互斥锁 + with_retry（M1.12）
//! ├── error.rs        CloudSyncError
//! ├── modules.rs      SyncModuleDef 静态注册表
//! ├── fingerprint.rs  canonical JSON + sha256 指纹（M1.3）
//! ├── crypto_io.rs    encrypt_payload / decrypt_payload（M1.4）
//! ├── meta.rs         GlobalMeta / ModuleMeta 读写（M1.5）
//! ├── state.rs        SyncStateStore（sync_state.json）（M1.6）
//! ├── progress.rs     SyncProgress 事件 + ProgressSender（M1.7）
//! ├── push.rs         push_all() 流程（M1.8）
//! ├── pull.rs         pull_all() 流程（M1.9）
//! ├── merge.rs        merge_items() LWW 合并 + 墓碑应用（M1.10）
//! └── attachments.rs  附件同步（push/pull，4 路并发）（M1.11）
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

pub use attachments::{AttachmentSyncResult, sync_attachments_pull, sync_attachments_push};
pub use crypto_io::{decrypt_payload, encrypt_payload};
pub use engine::{SyncEngine, SyncResult};
pub use error::CloudSyncError;
pub use fingerprint::compute_fingerprint;
pub use merge::{MergeResult, merge_items};
pub use meta::{GlobalMeta, ModuleData, ModuleMetaEntry, TombstoneEntry};
pub use modules::{SYNC_MODULES, SyncModuleDef, find_module};
pub use progress::{NoopProgressSender, ProgressSender, SyncProgress};
pub use pull::{PullResult, pull_all};
pub use push::{PushResult, push_all};
pub use state::{ModuleSyncState, SyncState, SyncStateStore};
