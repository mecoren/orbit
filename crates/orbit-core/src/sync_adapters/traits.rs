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

/// 上传前置条件（乐观并发控制）
///
/// v2 清单用 `epoch` 做 CAS：写入前读到当前对象的并发令牌（ETag），
/// 写入时携带该令牌；远端已被其他设备改写则条件失败，调用方转为
/// 「拉取 → 合并 → 重试」。
///
/// 不支持条件写的服务端（部分 WebDAV 实现）会忽略该头并以 2xx 返回，
/// 此时由调用方的「写后回读校验」兜底（见 `cloud_sync::push`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadPrecondition {
    /// 无条件覆盖
    None,
    /// 仅当远端对象不存在时创建（`If-None-Match: *`）
    Absent,
    /// 仅当远端当前令牌等于给定值时覆盖（`If-Match: <token>`）
    Match(String),
}

/// 条件上传结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadOutcome {
    /// 写入成功
    Ok,
    /// 前置条件不满足：远端已被其他写入方改写，需重新读取后合并重试
    PreconditionFailed,
}

/// 同步适配器 trait — S3 和 WebDAV 的统一接口
///
/// ## 条件写与探测的默认实现
/// 三个 v2 新增方法都提供**退化默认实现**（无条件上传 / 下载探测存在性 /
/// 无令牌读取），使既有 mock 适配器无需改动即可编译；生产适配器覆盖实现。
#[async_trait]
pub trait SyncAdapter: Send + Sync {
    /// 列出远程目录下的一级文件
    async fn list_files(&self, base_path: &str) -> Result<Vec<RemoteFile>, SyncError>;

    /// 列出远程目录下的所有文件（不过滤后缀，供备份列举使用）
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
    /// 用于附件 GC：对比本地引用集合，识别云端孤儿附件。
    async fn list_assets(&self) -> Result<Vec<String>, SyncError>;

    // ========================================================================
    // v2 新增：轻量存在性探测 / 并发令牌读取 / 条件写
    // ========================================================================

    /// 轻量存在性探测（生产实现走 HEAD，避免为判断存在而下载整个对象）
    ///
    /// 默认实现退化为下载探测（mock 适配器无需改动）；生产适配器覆盖。
    async fn exists(&self, path: &str) -> Result<bool, SyncError> {
        match self.download(path).await {
            Ok(_) => Ok(true),
            Err(e) if e.is_not_found() => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// 读取对象内容与并发令牌（ETag）
    ///
    /// - `Ok(Some((bytes, token)))`：对象存在；`token` 为服务端并发令牌，
    ///   `None` 表示服务端未提供（调用方退化为写后回读校验）
    /// - `Ok(None)`：对象不存在
    ///
    /// 默认实现返回 `None` 令牌（mock 友好）。
    async fn download_with_token(
        &self,
        path: &str,
    ) -> Result<Option<(Vec<u8>, Option<String>)>, SyncError> {
        match self.download(path).await {
            Ok(bytes) => Ok(Some((bytes, None))),
            Err(e) if e.is_not_found() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// 带前置条件的上传
    ///
    /// 默认实现忽略前置条件直接上传（返回 `Ok(UploadOutcome::Ok)`）——
    /// 生产适配器覆盖为真正的条件请求，调用方对不支持条件写的服务端
    /// 以「写后回读校验」兜底。
    async fn upload_conditional(
        &self,
        path: &str,
        data: &[u8],
        _precondition: UploadPrecondition,
    ) -> Result<UploadOutcome, SyncError> {
        self.upload(path, data).await?;
        Ok(UploadOutcome::Ok)
    }
}
