//! asset_api — 任务附件业务 API（07 排查报告后续批次：附件功能）
//!
//! 附件以 sha256 内容寻址：文件字节写 `{attachments_dir}/{hash}`，元数据入
//! `sys_attachments`（hash 主键，本地账本不进同步白名单），任务关联入
//! `todo_task_attachments`（随 todos 模块同步——同步的是"哪个任务挂了哪个
//! hash"的引用关系，二进制走 cloud_sync/attachments 的 assets/ 通道）。
//!
//! 流程：
//! - `add_task_attachment` / `add_task_attachment_from_path`：算 hash → 原子
//!   落盘 → upsert sys_attachments → 建任务关联（已挂载同 hash 则幂等返回）
//!   → emit 事件（触发 on-change push）→ 超出磁盘缓存上限时 LRU 逐出最久
//!   未访问的已上传附件
//! - `get_task_attachments`：关联 join 元数据（原始文件名/mime/大小）
//! - `read_task_attachment`：读本地文件字节（小图预览用；读取即刷新
//!   last_accessed_at，LRU 新鲜度依据）
//! - `export_task_attachment`：流式导出到指定路径（大文件/系统程序打开用），
//!   峰值只与复制缓冲有关，与附件大小无关（M3/T1.1）
//! - `remove_task_attachment`：软删关联；无任何任务引用的 hash 触发本地 GC
//!   （删文件 + 删账本行；云端对象留给下次同步的 push 侧自然对账，不做
//!   云端删除——多设备引用计数不可靠，宁可多留不误删）
//!
//! 磁盘缓存上限 + LRU（多设备安全口径）：
//! - 上限 `MAX_CACHE_BYTES`（2GB）：挂载新附件后超出即逐出「本地已缓存且
//!   已上传云端」中最久未访问者（is_uploaded=0 的 pending 源绝不逐出，
//!   删了会让每轮 push 读不到文件持续报错）；
//! - 逐出只删本地文件 + 清 is_local_cached 标志，**账本行保留**——pull
//!   差集按 is_local_cached=0 判定缺失，有活跃引用的附件下次同步自然重拉，
//!   云端视角与未逐出完全一致；
//! - 有活跃任务引用的附件同样参与逐出（引用的是 hash 不是文件，重拉即
//!   恢复；保持上限硬约束的语义简单性）。

use sqlx::SqlitePool;

use crate::db::repository::attachment_repo;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::Attachment;

/// 任务附件视图：关联记录 + 附件元数据
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TaskAttachmentView {
    pub link_id: i64,
    pub link_uuid: String,
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    /// 本地是否已缓存（0 = 尚未从云端拉回，UI 置灰/隐藏打开入口）
    pub is_local_cached: i32,
}

/// 附件上限（单任务 20 个 × 单文件 50MB，与 01 文档数据安全口径对齐 MS To Do 的 25MB 略放宽）
pub const MAX_ATTACHMENTS_PER_TASK: usize = 20;
pub const MAX_ATTACHMENT_BYTES: i64 = 50 * 1024 * 1024;
/// 附件磁盘缓存总上限（2GB：20 任务档日常远够；超出走 LRU 逐出重拉兜底）
pub const MAX_ATTACHMENT_CACHE_BYTES: i64 = 2 * 1024 * 1024 * 1024;

/// 上传并挂载附件到任务（字节入参：剪贴板/拖放等已在内存里的内容）
///
/// 幂等：同任务重复挂同 hash 直接返回已有关联（不重复计费上限）。
/// 文件写入用 fs_util::write_atomic（tmp+rename，防半截文件被内容寻址"背书"）。
///
/// 大文件（文件选择器路径）请用 [`add_task_attachment_from_path`]——本入口
/// 要求调用方已持有完整字节，峰值与文件大小线性相关。
pub async fn add_task_attachment(
    pool: &SqlitePool,
    attachments_dir: &str,
    task_id: i64,
    file_name: &str,
    mime_type: &str,
    data: &[u8],
) -> CoreResult<TaskAttachmentView> {
    if data.is_empty() {
        return Err(CoreError::Other("附件内容为空".to_string()));
    }
    if data.len() as i64 > MAX_ATTACHMENT_BYTES {
        return Err(oversize_error());
    }

    let hash = crate::crypto::sha256::sha256_hex(data);
    let now = crate::db::clock::next_ms();

    // 1. 原子落盘（已存在同 hash 内容寻址文件则跳过——幂等）
    std::fs::create_dir_all(attachments_dir)
        .map_err(|e| CoreError::Other(format!("创建附件目录失败: {}", e)))?;
    let file_path = std::path::Path::new(attachments_dir).join(&hash);
    if !file_path.exists() {
        crate::fs_util::write_atomic(&file_path, data)
            .map_err(|e| CoreError::Other(format!("附件落盘失败: {}", e)))?;
    }

    finish_add_attachment(
        pool,
        attachments_dir,
        task_id,
        file_name,
        mime_type,
        &hash,
        data.len() as i64,
        now,
    )
    .await
}

/// 从本地文件流式上传并挂载附件（UI 选文件→挂载的主路径，M3/T1.1）
///
/// 与 [`add_task_attachment`] 的区别只在**内存口径**：这里按 256KiB 块边读边
/// 算 SHA-256、边写同目录临时文件，峰值与文件大小无关（不再 `fs::read` 整文件
/// 后由 core 再持一份）。落位仍是「临时文件 → rename 到 `{attachments_dir}/{hash}`」，
/// 内容寻址与幂等语义逐字不变。
///
/// 校验口径：读前按元数据先拦空文件/超限（避免为明显非法文件白读一遍），
/// 读中累计再拦一次（文件可能在 stat 与读之间被替换成更大内容）。
pub async fn add_task_attachment_from_path(
    pool: &SqlitePool,
    attachments_dir: &str,
    task_id: i64,
    file_name: &str,
    mime_type: &str,
    source_path: &std::path::Path,
) -> CoreResult<TaskAttachmentView> {
    let meta = std::fs::metadata(source_path)
        .map_err(|e| CoreError::NotFound(format!("读取附件源文件失败: {}", e)))?;
    if !meta.is_file() {
        return Err(CoreError::Other("附件源路径不是常规文件".to_string()));
    }
    if meta.len() == 0 {
        return Err(CoreError::Other("附件内容为空".to_string()));
    }
    if meta.len() as i64 > MAX_ATTACHMENT_BYTES {
        return Err(oversize_error());
    }

    std::fs::create_dir_all(attachments_dir)
        .map_err(|e| CoreError::Other(format!("创建附件目录失败: {}", e)))?;
    let now = crate::db::clock::next_ms();

    // 1. 流式：算 hash + 写临时文件（双保险上限在循环内再拦一次）
    let (hash, size_bytes, tmp_path) = stream_hash_and_copy(source_path, attachments_dir)?;

    // 2. 内容寻址落位：同 hash 已存在则丢弃临时文件（去重）
    let target = std::path::Path::new(attachments_dir).join(&hash);
    if target.exists() {
        let _ = std::fs::remove_file(&tmp_path);
    } else if let Err(e) = crate::fs_util::replace_atomic(&tmp_path, &target) {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(CoreError::Other(format!("附件落盘失败: {}", e)));
    }

    finish_add_attachment(
        pool,
        attachments_dir,
        task_id,
        file_name,
        mime_type,
        &hash,
        size_bytes,
        now,
    )
    .await
}

fn oversize_error() -> CoreError {
    CoreError::Other(format!(
        "附件超过单文件上限 {}MB",
        MAX_ATTACHMENT_BYTES / 1024 / 1024
    ))
}

/// 流式「算 SHA-256 + 复制到附件目录临时文件」
///
/// 返回 `(hash, 实际字节数, 临时文件路径)`；调用方负责 rename 或删除。
/// 读中超过上限立即中止并清理临时文件（源文件可能被并发替换，stat 的
/// 大小不可作为最终依据）。
fn stream_hash_and_copy(
    source_path: &std::path::Path,
    attachments_dir: &str,
) -> CoreResult<(String, i64, std::path::PathBuf)> {
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};

    const COPY_BUF: usize = 256 * 1024;

    let mut reader = std::fs::File::open(source_path)
        .map_err(|e| CoreError::Other(format!("打开附件源文件失败: {}", e)))?;
    let tmp_path = crate::fs_util::temp_sibling(
        &std::path::Path::new(attachments_dir).join("incoming"),
        "upload",
    );
    let mut writer = std::fs::File::create(&tmp_path)
        .map_err(|e| CoreError::Other(format!("创建附件临时文件失败: {}", e)))?;

    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; COPY_BUF];
    let mut total: i64 = 0;
    let result = (|| -> CoreResult<()> {
        loop {
            let n = reader
                .read(&mut buf)
                .map_err(|e| CoreError::Other(format!("读取附件源文件失败: {}", e)))?;
            if n == 0 {
                break;
            }
            total += n as i64;
            if total > MAX_ATTACHMENT_BYTES {
                return Err(oversize_error());
            }
            hasher.update(&buf[..n]);
            writer
                .write_all(&buf[..n])
                .map_err(|e| CoreError::Other(format!("写入附件临时文件失败: {}", e)))?;
        }
        writer
            .flush()
            .map_err(|e| CoreError::Other(format!("写入附件临时文件失败: {}", e)))?;
        Ok(())
    })();

    if let Err(e) = result {
        drop(writer);
        let _ = std::fs::remove_file(&tmp_path);
        return Err(e);
    }
    drop(writer);
    if total == 0 {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(CoreError::Other("附件内容为空".to_string()));
    }

    let hash = hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<String>();
    Ok((hash, total, tmp_path))
}

/// 落盘之后的公共收尾：upsert 账本 → 建关联（幂等）→ emit → 缓存上限 → 历史
#[allow(clippy::too_many_arguments)]
async fn finish_add_attachment(
    pool: &SqlitePool,
    attachments_dir: &str,
    task_id: i64,
    file_name: &str,
    mime_type: &str,
    hash: &str,
    size_bytes: i64,
    now: i64,
) -> CoreResult<TaskAttachmentView> {
    // 单事务：账本行与任务关联行必须原子落库
    //
    // 启动期附件 GC 判「无引用」只看 `todo_task_attachments`：两个写分处不同
    // 事务时，GC 会撞进「账本已写、关联未写」的窗口，把刚上传的文件当孤儿删掉。
    let mut tx = pool.begin().await?;

    // 0. 任务存在性校验（外键只防孤儿，报错信息要可读）
    let task_exists: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE id = ? AND is_deleted = 0")
            .bind(task_id)
            .fetch_one(&mut *tx)
            .await?;
    if task_exists.0 == 0 {
        return Err(CoreError::NotFound(format!("任务 {} 不存在", task_id)));
    }

    let file_path = std::path::Path::new(attachments_dir).join(hash);

    // 2. upsert 附件元数据（本地账本；is_uploaded=0 等同步 push 上传）
    attachment_repo::upsert_in_tx(
        &mut tx,
        &Attachment {
            hash: hash.to_string(),
            original_name: file_name.to_string(),
            mime_type: mime_type.to_string(),
            size_bytes,
            local_path: Some(file_path.to_string_lossy().to_string()),
            is_uploaded: 0,
            is_local_cached: 1,
            created_at: now,
            last_accessed_at: now,
        },
    )
    .await?;

    // 3. 建任务关联（幂等：同任务已有同 hash 直接返回）
    let existing: Option<(i64, String)> = sqlx::query_as(
        "SELECT id, uuid FROM todo_task_attachments WHERE task_id = ? AND hash = ? AND is_deleted = 0",
    )
    .bind(task_id)
    .bind(hash)
    .fetch_optional(&mut *tx)
    .await?;
    let mut new_link: Option<(i64, String)> = None;
    let link = match existing {
        Some((id, uuid)) => (id, uuid),
        None => {
            // 上限校验（仅新挂载时）
            let count: (i64,) = sqlx::query_as(
                "SELECT COUNT(*) FROM todo_task_attachments WHERE task_id = ? AND is_deleted = 0",
            )
            .bind(task_id)
            .fetch_one(&mut *tx)
            .await?;
            if count.0 as usize >= MAX_ATTACHMENTS_PER_TASK {
                return Err(CoreError::Other(format!(
                    "单任务附件数已达上限 {}",
                    MAX_ATTACHMENTS_PER_TASK
                )));
            }

            let link_uuid = uuid::Uuid::new_v4().to_string();
            let link_id: (i64,) = sqlx::query_as(
                "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
                 VALUES (?, ?, ?, 0, ?, ?, 1) RETURNING id",
            )
            .bind(&link_uuid)
            .bind(task_id)
            .bind(hash)
            .bind(now)
            .bind(now)
            .fetch_one(&mut *tx)
            .await?;
            new_link = Some((link_id.0, link_uuid.clone()));
            (link_id.0, link_uuid)
        }
    };

    tx.commit().await?;

    // 4. 提交后才发事件 / 清缓存 / 记历史：事件不能早于数据可见（订阅方会读旧值）；
    //    缓存上限与历史轨迹失败不回滚挂载结果（与原实现同口径）
    if let Some((link_id, link_uuid)) = new_link {
        emit_attachment_event(
            "todo_task_attachments",
            link_id,
            &link_uuid,
            DbOp::Insert,
            now,
        );
        // 新挂载落盘后检查磁盘缓存总上限（幂等路径无新增字节不触发）
        enforce_attachment_cache_limit(pool, attachments_dir).await?;
        // 历史轨迹仅新挂载记（幂等重复挂同 hash 不重复记），target=文件名
        crate::api::business_api::log_target_activity(pool, task_id, "attachment_add", file_name)
            .await;
    }

    Ok(TaskAttachmentView {
        link_id: link.0,
        link_uuid: link.1,
        hash: hash.to_string(),
        original_name: file_name.to_string(),
        mime_type: mime_type.to_string(),
        size_bytes,
        is_local_cached: 1,
    })
}

/// 列出任务的全部附件（含本地缓存状态）
// bounded-by-data: 单任务附件数上限 MAX_ATTACHMENTS_PER_TASK（20），与任务总数无关
pub async fn get_task_attachments(
    pool: &SqlitePool,
    task_id: i64,
) -> CoreResult<Vec<TaskAttachmentView>> {
    let rows: Vec<(i64, String, String, String, String, i64, i32)> = sqlx::query_as(
        "SELECT ta.id, ta.uuid, ta.hash,
                COALESCE(a.original_name, ta.hash), COALESCE(a.mime_type, ''),
                COALESCE(a.size_bytes, 0), COALESCE(a.is_local_cached, 0)
         FROM todo_task_attachments ta
         LEFT JOIN sys_attachments a ON a.hash = ta.hash
         WHERE ta.task_id = ? AND ta.is_deleted = 0
         ORDER BY ta.created_at, ta.id",
    )
    .bind(task_id)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(
            |(link_id, link_uuid, hash, original_name, mime_type, size_bytes, is_local_cached)| {
                TaskAttachmentView {
                    link_id,
                    link_uuid,
                    hash,
                    original_name,
                    mime_type,
                    size_bytes,
                    is_local_cached,
                }
            },
        )
        .collect())
}

/// 读取附件本地文件字节
///
/// `is_local_cached = 0`（云端有但本机未拉回）时返回 NotFound，UI 引导
/// 等待下次同步拉取。
///
/// 峰值与文件大小线性相关，只适合小文件（图片预览）。大文件/交给系统程序
/// 打开的场景用 [`export_task_attachment`] 流式导出到目标路径。
pub async fn read_task_attachment(
    pool: &SqlitePool,
    attachments_dir: &str,
    hash: &str,
) -> CoreResult<Vec<u8>> {
    // N51（2026-10-12）纵深防御：hash 将被拼成本地文件路径
    // （`{attachments_dir}/{hash}`），格式非法即拒绝。DB 账本查找本身
    // 已拦掉大部分非法输入，这里守住入口契约，避免后续重构旁路。
    if !crate::crypto::sha256::is_sha256_hex(hash) {
        return Err(CoreError::Other(format!(
            "附件 hash 格式非法（需 64 位小写 sha256 hex）: {}",
            hash
        )));
    }
    let meta = attachment_repo::get_by_hash(pool, hash)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("附件 {} 不存在", hash)))?;
    if meta.is_local_cached == 0 {
        return Err(CoreError::NotFound(
            "附件尚未从云端同步到本机，请稍后重试".to_string(),
        ));
    }
    let path = std::path::Path::new(attachments_dir).join(hash);
    let bytes =
        std::fs::read(&path).map_err(|e| CoreError::Other(format!("读取附件失败: {}", e)))?;
    // 读取即访问：刷新 LRU 新鲜度（不 await 失败也无关紧要——仅排序键失真）
    let _ = attachment_repo::touch_last_accessed(pool, hash).await;
    Ok(bytes)
}

/// 流式导出附件到指定路径（大文件预览/交给系统程序打开，M3/T1.1）
///
/// 与 [`read_task_attachment`] 的区别：这里不把内容带进调用方内存，而是按
/// 256KiB 块复制到 `target_path`（先写同目录临时文件再原子替换），峰值与
/// 附件大小无关。返回写入字节数。
///
/// `target_path` 由壳层决定（通常是 app cache 下的预览文件）；同名目标会被
/// 覆盖（重新导出同内容），失败时不会留下半截文件。
pub async fn export_task_attachment(
    pool: &SqlitePool,
    attachments_dir: &str,
    hash: &str,
    target_path: &std::path::Path,
) -> CoreResult<i64> {
    if !crate::crypto::sha256::is_sha256_hex(hash) {
        return Err(CoreError::Other(format!(
            "附件 hash 格式非法（需 64 位小写 sha256 hex）: {}",
            hash
        )));
    }
    let meta = attachment_repo::get_by_hash(pool, hash)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("附件 {} 不存在", hash)))?;
    if meta.is_local_cached == 0 {
        return Err(CoreError::NotFound(
            "附件尚未从云端同步到本机，请稍后重试".to_string(),
        ));
    }
    let src = std::path::Path::new(attachments_dir).join(hash);
    let written = crate::fs_util::copy_file_atomic(&src, target_path, 256 * 1024)
        .map_err(|e| CoreError::Other(format!("导出附件失败: {}", e)))?;
    let _ = attachment_repo::touch_last_accessed(pool, hash).await;
    Ok(written as i64)
}

/// 卸下任务附件（软删关联行）
///
/// 不直接删二进制与账本：其他任务可能引用同 hash，且本机删除与云端对账
/// 交给 push/pull 的自然 diff。本地 GC（无引用的 hash 清文件+账本）由
/// `gc_local_attachments` 在合适的时机（如同步完成后/启动时）调用。
pub async fn remove_task_attachment(pool: &SqlitePool, link_id: i64) -> CoreResult<()> {
    let now = crate::db::clock::next_ms();
    let link: Option<(i64, String, i64, String)> = sqlx::query_as(
        "SELECT ta.id, ta.uuid, ta.task_id, COALESCE(a.original_name, ta.hash)
         FROM todo_task_attachments ta
         LEFT JOIN sys_attachments a ON a.hash = ta.hash
         WHERE ta.id = ? AND ta.is_deleted = 0",
    )
    .bind(link_id)
    .fetch_optional(pool)
    .await?;
    let Some((id, link_uuid, task_id, name)) = link else {
        return Ok(()); // 幂等：已删/不存在
    };
    sqlx::query(
        "UPDATE todo_task_attachments
         SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1
         WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;
    emit_attachment_event("todo_task_attachments", id, &link_uuid, DbOp::Update, now);
    crate::api::business_api::log_target_activity(pool, task_id, "attachment_delete", &name).await;
    Ok(())
}

/// 磁盘缓存上限执行：超出 MAX_ATTACHMENT_CACHE_BYTES 时 LRU 逐出
///
/// 逐出对象 = 本地已缓存且已上传云端（is_uploaded=1）中最久未访问者；
/// 只删文件 + 清 is_local_cached（账本行保留，pull 差集自然重拉）。
/// 全部候选逐完仍超限（如大量未上传附件挤占）时静默容忍——未上传的
/// pending 源受保护优先于上限，等下轮上传后再收。
/// 返回逐出个数。
pub async fn enforce_attachment_cache_limit(
    pool: &SqlitePool,
    attachments_dir: &str,
) -> CoreResult<usize> {
    evict_over_limit(pool, attachments_dir, MAX_ATTACHMENT_CACHE_BYTES).await
}

/// 上限执行核心（带参档：测试注小上限，产品路径走 2GB 常量）
async fn evict_over_limit(
    pool: &SqlitePool,
    attachments_dir: &str,
    max_bytes: i64,
) -> CoreResult<usize> {
    let total = attachment_repo::cached_total_bytes(pool).await?;
    if total <= max_bytes {
        return Ok(0);
    }
    let overflow = total - max_bytes;
    let candidates = attachment_repo::get_lru_evictable(pool, overflow).await?;
    let mut evicted = 0;
    for att in candidates {
        attachment_repo::evict_local_cache(pool, attachments_dir, &att.hash).await?;
        evicted += 1;
    }
    if evicted > 0 {
        log::info!(
            "[attachments] 磁盘缓存 {}MB 超上限 {}MB，LRU 逐出 {} 个已上传附件",
            total / 1024 / 1024,
            max_bytes / 1024 / 1024,
            evicted
        );
    }
    Ok(evicted)
}

/// 本地附件 GC：清理无任何任务引用的附件文件与账本行
///
/// 返回清理数量。多设备安全：本机判定"无引用"只代表本机视角，
/// 云端 assets/ 对象不删（其他设备可能仍挂载着该 hash），由同步的
/// push/pull diff 自然对账——宁可多留一个孤儿对象，不做误删。
// bounded-by-lifecycle: 引用集与账本行是本次 GC 的临时集合，函数返回即释放
//
// 规模 = 附件/关联行数（必须全量比对才能判孤儿），不是常驻容器；与「列表页常驻
// 全表」的风险不同，这里没有跨调用存活的持有者。
pub async fn gc_local_attachments(pool: &SqlitePool, attachments_dir: &str) -> CoreResult<usize> {
    // 1. 收集仍被引用的 hash
    let active: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT hash FROM todo_task_attachments WHERE is_deleted = 0")
            .fetch_all(pool)
            .await?;
    let active_set: std::collections::HashSet<String> = active.into_iter().map(|(h,)| h).collect();

    // 2. 遍历账本行，无引用的删文件 + 删行
    let all: Vec<Attachment> = sqlx::query_as(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments",
    )
    .fetch_all(pool)
    .await?;

    let mut cleaned = 0;
    for att in all {
        if active_set.contains(&att.hash) {
            continue;
        }
        attachment_repo::delete_by_hash(pool, &att.hash).await?;
        let path = std::path::Path::new(attachments_dir).join(&att.hash);
        std::fs::remove_file(&path).ok(); // 文件不存在也继续
        cleaned += 1;
    }
    Ok(cleaned)
}

/// 未使用附件视图（诊断页「清除未使用附件」入口的清单行）
///
/// 只读聚合 DTO：不 emit db-change、不进同步白名单（`sys_attachments` 是本地账本表）。
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct UnusedAttachmentView {
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub is_uploaded: i32,
    pub is_local_cached: i32,
    pub created_at: i64,
}

/// 列出无任何存活任务引用（`todo_task_attachments.is_deleted = 0`）的附件账本行
///
/// 口径与 [`gc_local_attachments`] 同源：被软删的关联不计引用（卸载后即可清理）；
/// **回收站里尚未彻底删除的任务其关联行仍存活**，附件仍算「使用中」（任务可能
/// 被恢复）。按体积降序，让 UI 优先展示占空间的大文件。
// bounded-by-data: `ta.hash = a.hash` 命中单个 hash 的引用行（附件在单任务内的引用数
// 受 MAX_ATTACHMENTS_PER_TASK 约束），不是全表扫描
pub async fn list_unused_attachments(pool: &SqlitePool) -> CoreResult<Vec<UnusedAttachmentView>> {
    let rows = sqlx::query_as::<_, UnusedAttachmentView>(
        "SELECT a.hash, a.original_name, a.mime_type, a.size_bytes,
                a.is_uploaded, a.is_local_cached, a.created_at
         FROM sys_attachments a
         WHERE NOT EXISTS (
             SELECT 1 FROM todo_task_attachments ta
             WHERE ta.hash = a.hash AND ta.is_deleted = 0
         )
         ORDER BY a.size_bytes DESC, a.created_at DESC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 按 hash 物理删除未使用附件（本地文件 + 账本行；云端对象不删）
///
/// **执行时复核**：每条 hash 用一条 `DELETE ... WHERE NOT EXISTS(存活链行)` 原子
/// 复核并删除——清单加载后被重新挂载的附件（`is_deleted = 0` 链行存在）不会命中，
/// 避免前端过期清单误删活跃附件；账本行本就不存在时同样不命中（幂等）。
/// 仅当账本行确被删除才动本地文件。返回实际清理的账本条数。
///
/// 云端 `assets/` 对象保留：本机「无引用」只是本机视角，多设备引用计数不可靠
/// （与 GC 同一多设备安全口径，pull 差集自然对账）。写路径但不 emit db-change：
/// `sys_attachments` 不在同步白名单，且被清理的 hash 已无存活关联行。
pub async fn delete_unused_attachments(
    pool: &SqlitePool,
    attachments_dir: &str,
    hashes: &[String],
) -> CoreResult<usize> {
    let mut cleaned = 0;
    for hash in hashes {
        // hash 是本地文件名：与 read/export 同口径校验，拒绝异常形态拼出越界路径
        if !crate::crypto::sha256::is_sha256_hex(hash) {
            continue;
        }
        let res = sqlx::query(
            "DELETE FROM sys_attachments
             WHERE hash = ?
               AND NOT EXISTS (
                   SELECT 1 FROM todo_task_attachments
                   WHERE hash = ? AND is_deleted = 0
               )",
        )
        .bind(hash)
        .bind(hash)
        .execute(pool)
        .await?;
        if res.rows_affected() == 0 {
            continue;
        }
        let path = std::path::Path::new(attachments_dir).join(hash);
        if let Err(e) = std::fs::remove_file(&path) {
            // 文件被占用/权限不足时不中断（账本行已删，文件成孤儿）；留可观测日志
            if e.kind() != std::io::ErrorKind::NotFound {
                log::warn!("[attachments] 删除未使用附件文件失败 {}: {}", hash, e);
            }
        }
        cleaned += 1;
    }
    Ok(cleaned)
}

/// emit DbEvent 辅助（与 todo_api::emit_todo_event 同构）
fn emit_attachment_event(table: &str, id: i64, uuid: &str, op: DbOp, timestamp: i64) {
    EVENT_BUS.emit(DbEvent {
        table: table.into(),
        op,
        record_id: id,
        record_uuid: uuid.to_string(),
        payload: None,
        device_id: String::new(),
        timestamp,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn create_task(pool: &SqlitePool) -> i64 {
        let (id,): (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, version) VALUES ('t-1', '测试任务', 1) RETURNING id",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        id
    }

    fn tmp_dir(tag: &str) -> String {
        let dir =
            std::env::temp_dir().join(format!("orbit-att-test-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.to_string_lossy().to_string()
    }

    #[tokio::test]
    async fn add_then_list_then_read_roundtrip() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("roundtrip");

        let view = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "报告.pdf",
            "application/pdf",
            b"pdf-bytes",
        )
        .await
        .unwrap();
        assert!(!view.hash.is_empty());
        assert_eq!(view.original_name, "报告.pdf");
        assert_eq!(view.size_bytes, 9);

        let list = get_task_attachments(&pool, task_id).await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].hash, view.hash);
        assert_eq!(list[0].original_name, "报告.pdf");

        let bytes = read_task_attachment(&pool, &dir, &view.hash).await.unwrap();
        assert_eq!(bytes, b"pdf-bytes");
    }

    /// 关联插入被拒（单任务上限）时账本行必须回滚
    ///
    /// 「账本有行、无关联」会被启动期附件 GC 判成孤儿并连文件一起删掉；
    /// 挂载收尾（账本 upsert + 关联插入）在同一事务里就是为了堵这个窗口。
    #[tokio::test]
    async fn add_attachment_rolls_back_ledger_when_link_rejected() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("rollback");

        for i in 0..MAX_ATTACHMENTS_PER_TASK {
            add_task_attachment(
                &pool,
                &dir,
                task_id,
                &format!("f{i}.txt"),
                "text/plain",
                format!("body-{i}").as_bytes(),
            )
            .await
            .unwrap();
        }

        let err = add_task_attachment(&pool, &dir, task_id, "over.txt", "text/plain", b"over")
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("上限"),
            "应被单任务上限拒绝: {err}"
        );

        let over_hash = crate::crypto::sha256::sha256_hex(b"over");
        assert!(
            attachment_repo::get_by_hash(&pool, &over_hash)
                .await
                .unwrap()
                .is_none(),
            "关联被拒时账本行必须随事务回滚"
        );
        assert_eq!(
            get_task_attachments(&pool, task_id).await.unwrap().len(),
            MAX_ATTACHMENTS_PER_TASK,
            "已成功挂载的附件不受影响"
        );
    }

    /// 附件挂/卸落任务历史（target=文件名）；幂等重复挂不重复记
    #[tokio::test]
    async fn attachment_add_remove_logged_to_history() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("history");
        let view = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "报告.pdf",
            "application/pdf",
            b"pdf-bytes",
        )
        .await
        .unwrap();
        add_task_attachment(
            &pool,
            &dir,
            task_id,
            "报告.pdf",
            "application/pdf",
            b"pdf-bytes",
        )
        .await
        .unwrap();

        let rows = crate::api::activity_log_api::list_task_activity(&pool, task_id, None)
            .await
            .unwrap();
        let adds: Vec<_> = rows
            .iter()
            .filter(|r| r.action == "attachment_add")
            .collect();
        assert_eq!(adds.len(), 1, "幂等重复挂不应多记");
        let v: serde_json::Value = serde_json::from_str(&adds[0].detail).unwrap();
        assert_eq!(v["target"], "报告.pdf");

        remove_task_attachment(&pool, view.link_id).await.unwrap();
        let rows = crate::api::activity_log_api::list_task_activity(&pool, task_id, None)
            .await
            .unwrap();
        let del = rows
            .iter()
            .find(|r| r.action == "attachment_delete")
            .expect("卸附件应有轨迹");
        let v: serde_json::Value = serde_json::from_str(&del.detail).unwrap();
        assert_eq!(v["target"], "报告.pdf");
    }

    #[tokio::test]
    async fn same_hash_same_task_is_idempotent() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("idempotent");

        let v1 = add_task_attachment(&pool, &dir, task_id, "a.png", "image/png", b"same-content")
            .await
            .unwrap();
        let v2 = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "b-different-name.png",
            "image/png",
            b"same-content",
        )
        .await
        .unwrap();
        // 同任务同内容 → 幂等返回同一关联（不计上限）
        assert_eq!(v1.link_id, v2.link_id);
        assert_eq!(v1.hash, v2.hash);

        let list = get_task_attachments(&pool, task_id).await.unwrap();
        assert_eq!(list.len(), 1);
    }

    #[tokio::test]
    async fn content_addressing_dedupes_across_tasks() {
        let pool = setup_db().await;
        let t1 = create_task(&pool).await;
        let (t2,): (i64,) = sqlx::query_as(
            "INSERT INTO todo_tasks (uuid, title, version) VALUES ('t-2', '任务二', 1) RETURNING id",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let dir = tmp_dir("dedup");

        let v1 = add_task_attachment(&pool, &dir, t1, "x.jpg", "image/jpeg", b"shared-bytes")
            .await
            .unwrap();
        let v2 = add_task_attachment(&pool, &dir, t2, "y.jpg", "image/jpeg", b"shared-bytes")
            .await
            .unwrap();
        // 跨任务内容寻址去重：同 hash 文件只一份，但两个任务各有自己的关联行
        assert_eq!(v1.hash, v2.hash);
        assert_ne!(v1.link_id, v2.link_id);
        assert_eq!(
            std::fs::read(std::path::Path::new(&dir).join(&v1.hash)).unwrap(),
            b"shared-bytes"
        );
    }

    #[tokio::test]
    async fn remove_then_gc_clears_orphan_but_keeps_active() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("gc");

        let keep = add_task_attachment(&pool, &dir, task_id, "keep.txt", "text/plain", b"keep-me")
            .await
            .unwrap();
        let drop = add_task_attachment(&pool, &dir, task_id, "drop.txt", "text/plain", b"drop-me")
            .await
            .unwrap();

        remove_task_attachment(&pool, drop.link_id).await.unwrap();
        let list = get_task_attachments(&pool, task_id).await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].hash, keep.hash);

        let cleaned = gc_local_attachments(&pool, &dir).await.unwrap();
        assert_eq!(cleaned, 1, "无引用的附件应被清理");
        assert!(
            std::path::Path::new(&dir).join(&keep.hash).exists(),
            "活跃附件文件必须保留"
        );
        assert!(
            !std::path::Path::new(&dir).join(&drop.hash).exists(),
            "孤儿附件文件应删除"
        );
    }

    // ---------- 未使用附件（诊断页清理入口，口径与 gc 同源）----------

    /// 清单只含无存活引用的账本行，按体积降序；仍被引用的附件不出现
    #[tokio::test]
    async fn list_unused_attachments_only_returns_unreferenced() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("unused-list");

        let keep = add_task_attachment(&pool, &dir, task_id, "keep.txt", "text/plain", b"keep")
            .await
            .unwrap();
        let small = add_task_attachment(&pool, &dir, task_id, "small.txt", "text/plain", b"drop")
            .await
            .unwrap();
        let big = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "big.txt",
            "text/plain",
            b"a-much-longer-detached-payload",
        )
        .await
        .unwrap();
        remove_task_attachment(&pool, small.link_id).await.unwrap();
        remove_task_attachment(&pool, big.link_id).await.unwrap();

        let list = list_unused_attachments(&pool).await.unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].hash, big.hash, "按体积降序，大文件在前");
        assert_eq!(list[1].hash, small.hash);
        assert_eq!(list[0].original_name, "big.txt");
        assert_eq!(
            list[0].size_bytes,
            "a-much-longer-detached-payload".len() as i64
        );
        assert_eq!(list[0].is_local_cached, 1);
        assert!(
            !list.iter().any(|a| a.hash == keep.hash),
            "仍被引用的附件不属于未使用"
        );
    }

    /// 删除未使用附件：本地文件 + 账本行一并清除，重复调用幂等
    #[tokio::test]
    async fn delete_unused_attachments_removes_file_and_ledger() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("unused-delete");
        let v = add_task_attachment(&pool, &dir, task_id, "old.txt", "text/plain", b"old-bytes")
            .await
            .unwrap();
        remove_task_attachment(&pool, v.link_id).await.unwrap();

        let n = delete_unused_attachments(&pool, &dir, std::slice::from_ref(&v.hash))
            .await
            .unwrap();
        assert_eq!(n, 1);
        assert!(
            attachment_repo::get_by_hash(&pool, &v.hash)
                .await
                .unwrap()
                .is_none(),
            "账本行应删除"
        );
        assert!(
            !std::path::Path::new(&dir).join(&v.hash).exists(),
            "本地文件应删除"
        );
        let again = delete_unused_attachments(&pool, &dir, std::slice::from_ref(&v.hash))
            .await
            .unwrap();
        assert_eq!(again, 0, "重复清理幂等");
    }

    /// 执行时复核存活引用：清单加载后又被重新挂载的 hash 必须跳过
    #[tokio::test]
    async fn delete_unused_attachments_skips_relinked_hash() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("unused-relink");
        let v = add_task_attachment(&pool, &dir, task_id, "back.txt", "text/plain", b"come-back")
            .await
            .unwrap();
        remove_task_attachment(&pool, v.link_id).await.unwrap();
        // 前端拿到清单后，用户又把同内容挂回任务
        add_task_attachment(&pool, &dir, task_id, "back.txt", "text/plain", b"come-back")
            .await
            .unwrap();

        let n = delete_unused_attachments(&pool, &dir, std::slice::from_ref(&v.hash))
            .await
            .unwrap();
        assert_eq!(n, 0, "复核发现已被重新引用，跳过不删");
        assert!(
            attachment_repo::get_by_hash(&pool, &v.hash)
                .await
                .unwrap()
                .is_some(),
            "账本行必须保留"
        );
        assert!(std::path::Path::new(&dir).join(&v.hash).exists());
    }

    #[tokio::test]
    async fn per_task_limit_enforced() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("limit");

        for i in 0..MAX_ATTACHMENTS_PER_TASK {
            add_task_attachment(
                &pool,
                &dir,
                task_id,
                &format!("f{}.txt", i),
                "text/plain",
                format!("content-{}", i).as_bytes(),
            )
            .await
            .unwrap();
        }
        let err =
            add_task_attachment(&pool, &dir, task_id, "over.txt", "text/plain", b"overflow").await;
        assert!(err.is_err(), "超过单任务上限必须拒绝");
    }

    #[tokio::test]
    async fn oversize_file_rejected() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("oversize");

        let big = vec![0u8; (MAX_ATTACHMENT_BYTES + 1) as usize];
        let err = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "big.bin",
            "application/octet-stream",
            &big,
        )
        .await;
        assert!(err.is_err(), "超过单文件大小上限必须拒绝");
    }

    #[tokio::test]
    async fn read_uncached_attachment_returns_not_found() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("uncached");

        let view = add_task_attachment(&pool, &dir, task_id, "f.txt", "text/plain", b"data")
            .await
            .unwrap();
        // 模拟"本机未拉回云端附件"：清缓存标志
        sqlx::query("UPDATE sys_attachments SET is_local_cached = 0 WHERE hash = ?")
            .bind(&view.hash)
            .execute(&pool)
            .await
            .unwrap();
        let err = read_task_attachment(&pool, &dir, &view.hash).await;
        assert!(err.is_err(), "未缓存附件应返回 NotFound 引导等待同步");
    }

    #[tokio::test]
    async fn read_rejects_malformed_hash() {
        // N51（2026-10-12）：hash 是本地文件名，路径分隔符等非法形态在入口处拒绝
        let pool = setup_db().await;
        let err = read_task_attachment(&pool, "unused", "../../etc/passwd")
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("格式非法"),
            "非法 hash 应在入口处被拒，实际: {}",
            err
        );
    }

    // ---------- 磁盘缓存上限 + LRU 逐出（多设备安全口径）----------

    /// 造一个已缓存附件并手工指定 is_uploaded / last_accessed_at（测试注入）
    async fn seed_attachment(
        pool: &SqlitePool,
        dir: &str,
        tag: &str,
        bytes: &[u8],
        uploaded: i32,
        accessed_at: i64,
    ) -> String {
        let hash = crate::crypto::sha256::sha256_hex(bytes);
        let path = std::path::Path::new(dir).join(&hash);
        crate::fs_util::write_atomic(&path, bytes).unwrap();
        attachment_repo::upsert(
            pool,
            &Attachment {
                hash: hash.clone(),
                original_name: format!("{}.bin", tag),
                mime_type: "application/octet-stream".to_string(),
                size_bytes: bytes.len() as i64,
                local_path: Some(path.to_string_lossy().to_string()),
                is_uploaded: uploaded,
                is_local_cached: 1,
                created_at: accessed_at,
                last_accessed_at: accessed_at,
            },
        )
        .await
        .unwrap();
        hash
    }

    #[tokio::test]
    async fn lru_evicts_oldest_uploaded_keeps_pending_and_ledger() {
        let pool = setup_db().await;
        let dir = tmp_dir("lru");
        // 三个已上传附件（访问时间 old < mid < new）+ 一个未上传 pending 源
        let old = seed_attachment(&pool, &dir, "old", &[1u8; 40], 1, 1_000).await;
        let mid = seed_attachment(&pool, &dir, "mid", &[2u8; 30], 1, 2_000).await;
        let new = seed_attachment(&pool, &dir, "new", &[3u8; 20], 1, 3_000).await;
        let pending = seed_attachment(&pool, &dir, "pending", &[4u8; 10], 0, 4_000).await;
        // 总 100B，上限 50B：需逐出 ≥50B 的已上传附件 → old(40)+mid(30) 被逐，
        // new(20) 留下后总 30B ≤ 50B；pending(10) 受保护不动
        let evicted = evict_over_limit(&pool, &dir, 50).await.unwrap();
        assert_eq!(evicted, 2, "最久未访问的 old+mid 应被逐出");
        assert!(
            !std::path::Path::new(&dir).join(&old).exists()
                && !std::path::Path::new(&dir).join(&mid).exists(),
            "被逐出的本地文件应删除"
        );
        assert!(
            std::path::Path::new(&dir).join(&new).exists(),
            "最近访问的 new 应保留"
        );
        assert!(
            std::path::Path::new(&dir).join(&pending).exists(),
            "未上传的 pending 源绝不逐出（云端唯一副本）"
        );
        // 账本行保留（多设备安全：元数据不丢，pull 差集可自然重拉）
        for h in [&old, &mid] {
            let row: (i32,) =
                sqlx::query_as("SELECT is_local_cached FROM sys_attachments WHERE hash = ?")
                    .bind(h)
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            assert_eq!(row.0, 0, "逐出后账本行保留且缓存标志清零");
        }
        let total = attachment_repo::cached_total_bytes(&pool).await.unwrap();
        assert_eq!(total, 30, "逐出后缓存总量 = new(20)+pending(10)");
    }

    #[tokio::test]
    async fn read_refreshes_lru_order() {
        let pool = setup_db().await;
        let dir = tmp_dir("lru-touch");
        let stale = seed_attachment(&pool, &dir, "stale", &[1u8; 40], 1, 1_000).await;
        let fresh = seed_attachment(&pool, &dir, "fresh", &[2u8; 20], 1, 2_000).await;
        // 读 stale 抬访问时间到当前——它从最旧变最新
        read_task_attachment(&pool, &dir, &stale).await.unwrap();
        // 总 60B 上限 50B：应逐 fresh（20B）而非刚读过的 stale
        let evicted = evict_over_limit(&pool, &dir, 50).await.unwrap();
        assert_eq!(evicted, 1);
        assert!(
            !std::path::Path::new(&dir).join(&fresh).exists(),
            "最久未访问的 fresh 应被逐出"
        );
        assert!(
            std::path::Path::new(&dir).join(&stale).exists(),
            "刚读取过的 stale 应因 touch 幸存"
        );
    }

    #[tokio::test]
    async fn under_limit_is_noop() {
        let pool = setup_db().await;
        let dir = tmp_dir("lru-noop");
        seed_attachment(&pool, &dir, "a", &[1u8; 30], 1, 1_000).await;
        let evicted = evict_over_limit(&pool, &dir, 100).await.unwrap();
        assert_eq!(evicted, 0, "未超上限不逐出");
        assert_eq!(
            attachment_repo::cached_total_bytes(&pool).await.unwrap(),
            30
        );
    }

    // ==================================================================
    // M3/T1.1：路径入参流式写入 与 流式导出
    // ==================================================================

    #[tokio::test]
    async fn from_path_streams_and_matches_bytes_entrypoint() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("from-path");
        let payload = vec![7u8; 1024 * 1024];

        // 源文件放在附件目录之外（模拟用户下载目录）
        let src_dir = tempfile::TempDir::new().unwrap();
        let src = src_dir.path().join("report.pdf");
        std::fs::write(&src, &payload).unwrap();

        let view = add_task_attachment_from_path(
            &pool,
            &dir,
            task_id,
            "report.pdf",
            "application/pdf",
            &src,
        )
        .await
        .unwrap();

        let expected_hash = crate::crypto::sha256::sha256_hex(&payload);
        assert_eq!(view.hash, expected_hash);
        assert_eq!(view.size_bytes, payload.len() as i64);
        assert_eq!(
            std::fs::read(std::path::Path::new(&dir).join(&view.hash)).unwrap(),
            payload,
            "内容寻址落盘内容必须与源文件逐字节一致"
        );
        // 临时文件不得残留（rename 成功即清理）
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "附件目录不得残留临时文件");

        // 与字节入口同内容同 hash → 幂等（同任务不重复挂载）
        let again = add_task_attachment(
            &pool,
            &dir,
            task_id,
            "report-renamed.pdf",
            "application/pdf",
            &payload,
        )
        .await
        .unwrap();
        assert_eq!(again.link_id, view.link_id);
    }

    #[tokio::test]
    async fn from_path_rejects_empty_and_missing_source() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("from-path-invalid");
        let src_dir = tempfile::TempDir::new().unwrap();
        let empty = src_dir.path().join("empty.bin");
        std::fs::write(&empty, b"").unwrap();

        let err = add_task_attachment_from_path(
            &pool,
            &dir,
            task_id,
            "empty.bin",
            "application/octet-stream",
            &empty,
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("为空"), "实际: {err}");

        let missing = src_dir.path().join("nope.bin");
        let err = add_task_attachment_from_path(
            &pool,
            &dir,
            task_id,
            "nope.bin",
            "application/octet-stream",
            &missing,
        )
        .await
        .unwrap_err();
        assert!(
            err.to_string().contains("读取附件源文件失败"),
            "实际: {err}"
        );
    }

    #[tokio::test]
    async fn export_streams_to_target_and_refreshes_lru() {
        let pool = setup_db().await;
        let task_id = create_task(&pool).await;
        let dir = tmp_dir("export");
        let payload = vec![3u8; 300 * 1024];
        let view = add_task_attachment(&pool, &dir, task_id, "photo.png", "image/png", &payload)
            .await
            .unwrap();

        let out_dir = tempfile::TempDir::new().unwrap();
        let target = out_dir.path().join("preview.png");
        let written = export_task_attachment(&pool, &dir, &view.hash, &target)
            .await
            .unwrap();
        assert_eq!(written, payload.len() as i64);
        assert_eq!(std::fs::read(&target).unwrap(), payload);

        // 覆盖导出（同内容重导出）不得留下临时/半截文件
        export_task_attachment(&pool, &dir, &view.hash, &target)
            .await
            .unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), payload);
        let leftovers: Vec<_> = std::fs::read_dir(out_dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "导出目录不得残留临时文件");
    }

    #[tokio::test]
    async fn export_rejects_uncached_and_malformed_hash() {
        let pool = setup_db().await;
        let dir = tmp_dir("export-invalid");
        let out = tempfile::TempDir::new().unwrap();
        let target = out.path().join("x.bin");

        let err = export_task_attachment(&pool, &dir, "not-a-hash", &target)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("hash 格式非法"), "实际: {err}");

        let real = crate::crypto::sha256::sha256_hex(b"never-added");
        let err = export_task_attachment(&pool, &dir, &real, &target)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("不存在"), "实际: {err}");
    }
}
