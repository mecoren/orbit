use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::sync::error::SyncError;

/// 同步适配器类型
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum AdapterType {
    S3,
    WebDAV,
}

/// 远程文件信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteFile {
    pub name: String,
    pub size: u64,
    /// 最后修改时间（Unix 时间戳，秒）
    pub last_modified: i64,
    pub lamport_version: i64,
}

/// 同步适配器 trait — S3 和 WebDAV 的统一接口
#[async_trait]
pub trait SyncAdapter: Send + Sync {
    /// 列出远程目录下的 .waitsync 文件
    async fn list_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError>;

    /// v7: 列出远程目录下的所有文件（不过滤后缀）
    ///
    /// 与 `list_files` 的区别：不做 `.waitsync` 后缀过滤，返回目录下所有文件。
    /// 供备份列举（`.waitfullsync` 备份文件）等需要非同步后缀的场景使用。
    /// 默认实现返回空 Vec（向后兼容），各 adapter 应覆盖此方法。
    async fn list_all_files(&self, _base_path: &str) -> Result<Vec<RemoteFile>, SyncError> {
        Ok(Vec::new())
    }

    /// 下载文件
    async fn download(&self, path: &str) -> Result<Vec<u8>, SyncError>;

    /// 上传文件
    async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError>;

    /// 删除文件
    async fn delete(&self, path: &str) -> Result<(), SyncError>;

    /// 上传附件（内容寻址，文件名 = hash）
    async fn upload_asset(&self, hash: &str, data: &[u8]) -> Result<(), SyncError>;

    /// 下载附件
    async fn download_asset(&self, hash: &str) -> Result<Vec<u8>, SyncError>;

    /// 检查附件是否存在
    async fn asset_exists(&self, hash: &str) -> Result<bool, SyncError>;

    /// 列出云端所有附件的 hash 列表
    ///
    /// 用于 compaction 后的附件 GC：对比本地引用集合，删除云端孤儿附件。
    async fn list_assets(&self) -> Result<Vec<String>, SyncError>;
}
