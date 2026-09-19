use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::sync::error::SyncError;

/// 远程文件信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteFile {
    pub name: String,
    pub size: u64,
    /// 最后修改时间（Unix 时间戳，秒）
    pub last_modified: i64,
    /// 并发令牌（ETag，已剥引号/弱校验前缀；服务端不提供则为 None）
    ///
    /// F26（2026-09-19 第五轮探查）：S3 `<ETag>` 与 WebDAV `<d:getetag/>`
    /// 都在列举响应里，此前整体丢弃，列举侧无法与条件写（CAS）共用同一份
    /// 「当前远端版本」快照。字段语义与 `download_with_token` 的令牌一致。
    pub etag: Option<String>,
}

/// 上传前置条件（乐观并发控制）
///
/// 清单用 `epoch` 做 CAS：写入前读到当前对象的并发令牌（ETag），
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

/// 归一化 ETag：剥掉服务端包裹的弱校验前缀与引号
///
/// S3 回 `"abc"`、WebDAV 回 `"abc"` 或 `W/"abc"`，条件请求头要求的是裸令牌
/// （`If-Match: "abc"` 由发送侧自行加引号）。空值返回 None（部分服务器对目录
/// 回空 getetag）。F26 起两协议的列举侧共用此口径，与 `download_with_token`
/// 的令牌保持同源。
pub(crate) fn normalize_etag(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let unquoted = trimmed
        .strip_prefix("W/")
        .unwrap_or(trimmed)
        .trim_matches('"');
    if unquoted.is_empty() {
        None
    } else {
        Some(unquoted.to_string())
    }
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
/// 三个条件写/探测方法都提供**退化默认实现**（无条件上传 / 下载探测存在性 /
/// 无令牌读取），使既有 mock 适配器无需改动即可编译；生产适配器覆盖实现。
#[async_trait]
pub trait SyncAdapter: Send + Sync {
    /// 列出远程目录下的所有文件（不过滤后缀，供备份列举使用）
    ///
    /// **两协议的「列出」深度不同，实现者须知道自己在承诺什么**（F32）：
    /// WebDAV 用 `PROPFIND Depth:1`，只回**直接子项**一层（更深的目录不递归，
    /// 且返回的 `RemoteFile.name` 是 basename、丢父级路径）；S3 用
    /// `ListObjectsV2 prefix=…`，按前缀**递归**列出所有后代 key（`name` 是
    /// 去掉前缀后的相对路径，可含 `/`）。当前云端布局（`backups/`、`tables/`、
    /// `assets/` 均为「base_path 下一层」）让两者结果重合；若将来引入二级
    /// 嵌套，WebDAV 侧会静默漏项——那时须改为递归 PROPFIND 或显式按目录列举，
    /// 而不是让调用方以为两协议等价。
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

    /// 列出云端所有附件的裸 hash 列表
    ///
    /// 用于附件 push/pull 差集与孤儿 GC：返回值必须与本地 `sys_attachments.hash`
    /// 同域（**裸 hash**，既无目录前缀也无同步后缀）。
    ///
    /// `assets_dir` 为附件对象所在目录的**完整云端路径**（`assets` 或
    /// `{base_path}/assets`），由调用方给全路径、适配器不再自拼前缀（F23）：
    /// 生产链路唯一调用方是 `BasePathAdapter`，它掌握 base_path。
    /// WebDAV 实现还须并集 `assets_parts/` 下的分片附件（把 `assets_dir` 末段
    /// `assets` 换成 `assets_parts`）——漏掉即分片附件在差集里永远缺席。
    async fn list_assets(&self, assets_dir: &str) -> Result<Vec<String>, SyncError>;

    // ========================================================================
    // 轻量存在性探测 / 并发令牌读取 / 条件写
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
