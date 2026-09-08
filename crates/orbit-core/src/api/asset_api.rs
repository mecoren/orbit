//! asset_api — 任务附件业务 API（07 排查报告后续批次：附件功能）
//!
//! 附件以 sha256 内容寻址：文件字节写 `{attachments_dir}/{hash}`，元数据入
//! `sys_attachments`（hash 主键，本地账本不进同步白名单），任务关联入
//! `todo_task_attachments`（随 todos 模块同步——同步的是"哪个任务挂了哪个
//! hash"的引用关系，二进制走 cloud_sync/attachments 的 assets/ 通道）。
//!
//! 流程：
//! - `add_task_attachment`：算 hash → 原子落盘 → upsert sys_attachments →
//!   建任务关联（已挂载同 hash 则幂等返回）→ emit 事件（触发 on-change push）
//! - `get_task_attachments`：关联 join 元数据（原始文件名/mime/大小）
//! - `read_task_attachment`：读本地文件字节（详情页预览/另存用）
//! - `remove_task_attachment`：软删关联；无任何任务引用的 hash 触发本地 GC
//!   （删文件 + 删账本行；云端对象留给下次同步的 push 侧自然对账，不做
//!   云端删除——多设备引用计数不可靠，宁可多留不误删）

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

/// 上传并挂载附件到任务
///
/// 幂等：同任务重复挂同 hash 直接返回已有关联（不重复计费上限）。
/// 文件写入用 fs_util::write_atomic（tmp+rename，防半截文件被内容寻址"背书"）。
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
        return Err(CoreError::Other(format!(
            "附件超过单文件上限 {}MB",
            MAX_ATTACHMENT_BYTES / 1024 / 1024
        )));
    }

    // 0. 任务存在性校验（外键只防孤儿，报错信息要可读）
    let task_exists: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE id = ? AND is_deleted = 0")
            .bind(task_id)
            .fetch_one(pool)
            .await?;
    if task_exists.0 == 0 {
        return Err(CoreError::NotFound(format!("任务 {} 不存在", task_id)));
    }

    let hash = crate::crypto::sha256::sha256_hex(data);
    let now = chrono::Utc::now().timestamp_millis();

    // 1. 原子落盘（已存在同 hash 内容寻址文件则跳过——幂等）
    std::fs::create_dir_all(attachments_dir)
        .map_err(|e| CoreError::Other(format!("创建附件目录失败: {}", e)))?;
    let file_path = std::path::Path::new(attachments_dir).join(&hash);
    if !file_path.exists() {
        crate::fs_util::write_atomic(&file_path, data)
            .map_err(|e| CoreError::Other(format!("附件落盘失败: {}", e)))?;
    }

    // 2. upsert 附件元数据（本地账本；is_uploaded=0 等同步 push 上传）
    attachment_repo::upsert(
        pool,
        &Attachment {
            hash: hash.clone(),
            original_name: file_name.to_string(),
            mime_type: mime_type.to_string(),
            size_bytes: data.len() as i64,
            local_path: Some(file_path.to_string_lossy().to_string()),
            is_uploaded: 0,
            is_local_cached: 1,
            created_at: now,
        },
    )
    .await?;

    // 3. 建任务关联（幂等：同任务已有同 hash 直接返回）
    let existing: Option<(i64, String)> =
        sqlx::query_as("SELECT id, uuid FROM todo_task_attachments WHERE task_id = ? AND hash = ? AND is_deleted = 0")
            .bind(task_id)
            .bind(&hash)
            .fetch_optional(pool)
            .await?;
    let link = match existing {
        Some((id, uuid)) => (id, uuid),
        None => {
            // 上限校验（仅新挂载时）
            let count: (i64,) = sqlx::query_as(
                "SELECT COUNT(*) FROM todo_task_attachments WHERE task_id = ? AND is_deleted = 0",
            )
            .bind(task_id)
            .fetch_one(pool)
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
            .bind(&hash)
            .bind(now)
            .bind(now)
            .fetch_one(pool)
            .await?;
            emit_attachment_event(
                "todo_task_attachments",
                link_id.0,
                &link_uuid,
                DbOp::Insert,
                now,
            );
            (link_id.0, link_uuid)
        }
    };

    Ok(TaskAttachmentView {
        link_id: link.0,
        link_uuid: link.1,
        hash,
        original_name: file_name.to_string(),
        mime_type: mime_type.to_string(),
        size_bytes: data.len() as i64,
        is_local_cached: 1,
    })
}

/// 列出任务的全部附件（含本地缓存状态）
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
pub async fn read_task_attachment(
    pool: &SqlitePool,
    attachments_dir: &str,
    hash: &str,
) -> CoreResult<Vec<u8>> {
    let meta = attachment_repo::get_by_hash(pool, hash)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("附件 {} 不存在", hash)))?;
    if meta.is_local_cached == 0 {
        return Err(CoreError::NotFound(
            "附件尚未从云端同步到本机，请稍后重试".to_string(),
        ));
    }
    let path = std::path::Path::new(attachments_dir).join(hash);
    std::fs::read(&path).map_err(|e| CoreError::Other(format!("读取附件失败: {}", e)))
}

/// 卸下任务附件（软删关联行）
///
/// 不直接删二进制与账本：其他任务可能引用同 hash，且本机删除与云端对账
/// 交给 push/pull 的自然 diff。本地 GC（无引用的 hash 清文件+账本）由
/// `gc_local_attachments` 在合适的时机（如同步完成后/启动时）调用。
pub async fn remove_task_attachment(pool: &SqlitePool, link_id: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let link: Option<(i64, String)> = sqlx::query_as(
        "SELECT id, uuid FROM todo_task_attachments WHERE id = ? AND is_deleted = 0",
    )
    .bind(link_id)
    .fetch_optional(pool)
    .await?;
    let Some((id, link_uuid)) = link else {
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
    Ok(())
}

/// 本地附件 GC：清理无任何任务引用的附件文件与账本行
///
/// 返回清理数量。多设备安全：本机判定"无引用"只代表本机视角，
/// 云端 assets/ 对象不删（其他设备可能仍挂载着该 hash），由同步的
/// push/pull diff 自然对账——宁可多留一个孤儿对象，不做误删。
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
                is_uploaded, is_local_cached, created_at
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
}
