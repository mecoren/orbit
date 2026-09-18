//! cloud_sync — 云端差量同步引擎
//!
//! ## 设计
//! 「表级分桶 + 单一清单 + 版本前置」：
//! - 数据按表切分为稳定哈希分桶（[`chunk`]），只上传/下载变化的桶
//! - 云端只有一份 [`meta::Manifest`]（`manifest.orsync`）承载
//!   `epoch` + 桶索引 + 墓碑水位线，是唯一真相源
//! - 清单写入带前置条件（`If-Match` / `If-None-Match`），配合写后回读校验，
//!   多设备并发写从"静默覆盖"变为"可检测冲突并自动收敛"（[`push`]）
//! - 墓碑按本地时区月份分桶（[`meta::TombstoneBucketPayload`]），
//!   按设备水位线安全回收（[`gc`]）
//!
//! ## 云端布局
//! ```text
//! {base_path}/
//! ├─ crypto/config                           # 加密元数据（跨设备分发 Data Key）
//! ├─ manifest.orsync                         # 唯一真相源（加密）
//! ├─ tables/{table}/{bucket:02}.orsync       # 表级分桶（加密）
//! ├─ tombstones/{table}/{YYYY-MM}.orsync     # 墓碑分桶（加密）
//! └─ assets/{hash}.orsync                    # 附件内容寻址（≥8MiB 走分片续传）
//! ```
//!
//! ## 模块分层
//! ```text
//! cloud_sync/
//! ├── mod.rs          本文件：模块导出
//! ├── chunk.rs        分桶切分与指纹（稳定哈希分桶）
//! ├── meta.rs         Manifest / 桶索引 / 墓碑结构
//! ├── state.rs        本地账本（epoch + 远端桶索引快照）
//! ├── engine.rs       SyncEngine 编排：三模式 + 互斥锁 + 重试
//! ├── push.rs         差量上传 + 清单 CAS
//! ├── pull.rs         清单驱动差量下载 + 合并
//! ├── merge.rs        单表 LWW 合并 + 墓碑裁决
//! ├── gc.rs          墓碑水位线回收 + 孤儿分桶清理
//! ├── db_loader.rs    按表加载（数据 / uuid 映射 / 墓碑分桶）
//! ├── fingerprint.rs  canonical JSON + sha256 指纹
//! ├── crypto_io.rs    encrypt_payload / decrypt_payload
//! ├── paths.rs        路径构造
//! ├── progress.rs     SyncProgress 事件
//! ├── attachments.rs 附件同步（内容寻址 + 分片）
//! └── modules.rs      同步模块注册表（与白名单一致性断言）
//! ```

pub mod attachments;
pub mod chunk;
pub mod crypto_io;
pub mod db_loader;
pub mod engine;
pub mod error;
pub mod fingerprint;
pub mod gc;
pub mod merge;
pub mod meta;
pub mod modules;
pub mod paths;
pub mod progress;
pub mod pull;
pub mod push;
pub mod state;

pub use attachments::{AttachmentSyncResult, sync_attachments_pull, sync_attachments_push};
pub use chunk::{
    ChunkPayload, TABLE_BUCKET_COUNT, TableChunk, bucket_of_uuid, split_table_items,
};
pub use crypto_io::{decrypt_payload, encrypt_payload};
pub use engine::{SyncEngine, SyncResult};
pub use error::CloudSyncError;
pub use fingerprint::compute_fingerprint;
pub use gc::{
    GcResult, collect_garbage, delete_expired_buckets, prune_expired_tombstones,
};
pub use merge::{MergeResult, merge_table_items};
pub use meta::{
    ChunkRef, LAYOUT_VERSION, Manifest, TableIndex, TombstoneBucketRef, TombstoneEntry,
    TombstoneIndex,
};
pub use modules::{SYNC_MODULES, SyncModuleDef, find_module};
pub use progress::{NoopProgressSender, ProgressSender, SyncProgress};
pub use pull::{PullResult, pull_all};
pub use push::{PushResult, push_all};
pub use state::{SyncState, SyncStateStore};
