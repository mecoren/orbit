//! attachment_repo — 附件元数据仓储
//!
//! 管理 sys_attachments 表的 CRUD 操作。
//! 附件以 hash 为主键，记录上传/缓存状态，供 AssetSyncService 使用。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::models::business::Attachment;

/// 根据 hash 查询单个附件
pub async fn get_by_hash(pool: &SqlitePool, hash: &str) -> CoreResult<Option<Attachment>> {
    let item = sqlx::query_as::<_, Attachment>(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments WHERE hash = ?",
    )
    .bind(hash)
    .fetch_optional(pool)
    .await?;
    Ok(item)
}

/// 插入或更新附件（以 hash 为冲突键）
///
/// 冲突路径的 last_accessed_at 取新旧较大值——重挂载同 hash 不把既有
/// 附件的 LRU 新鲜度倒退回 created_at。
pub async fn upsert(pool: &SqlitePool, a: &Attachment) -> CoreResult<()> {
    sqlx::query(
        "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                  is_uploaded, is_local_cached, created_at, last_accessed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(hash) DO UPDATE SET
            original_name = excluded.original_name,
            mime_type = excluded.mime_type,
            size_bytes = excluded.size_bytes,
            local_path = excluded.local_path,
            is_uploaded = excluded.is_uploaded,
            is_local_cached = excluded.is_local_cached,
            created_at = excluded.created_at,
            last_accessed_at = MAX(sys_attachments.last_accessed_at, excluded.last_accessed_at)",
    )
    .bind(&a.hash)
    .bind(&a.original_name)
    .bind(&a.mime_type)
    .bind(a.size_bytes)
    .bind(&a.local_path)
    .bind(a.is_uploaded)
    .bind(a.is_local_cached)
    .bind(a.created_at)
    .bind(a.last_accessed_at)
    .execute(pool)
    .await?;
    Ok(())
}

/// 标记附件已上传云端
pub async fn mark_uploaded(pool: &SqlitePool, hash: &str) -> CoreResult<()> {
    sqlx::query("UPDATE sys_attachments SET is_uploaded = 1 WHERE hash = ?")
        .bind(hash)
        .execute(pool)
        .await?;
    Ok(())
}

/// 全部附件重置为未上传（rekey 全量重传场景）
///
/// Data Key 更换（v2 改密 / v1→v2 迁移 / 以本机为准恢复）后，云端旧密文
/// 附件已不可用，必须用新 Key 重加密重传。将 is_uploaded 全部清零后，
/// `sync_attachments_push` 的 get_unuploaded 会重取全部本地缓存附件重传。
pub async fn mark_all_unuploaded(pool: &SqlitePool) -> CoreResult<u64> {
    let result = sqlx::query("UPDATE sys_attachments SET is_uploaded = 0")
        .execute(pool)
        .await?;
    Ok(result.rows_affected())
}

/// 标记附件已本地缓存
pub async fn mark_local_cached(pool: &SqlitePool, hash: &str, local_path: &str) -> CoreResult<()> {
    sqlx::query("UPDATE sys_attachments SET is_local_cached = 1, local_path = ? WHERE hash = ?")
        .bind(local_path)
        .bind(hash)
        .execute(pool)
        .await?;
    Ok(())
}

/// 标记附件已本地缓存，记录不存在时插入占位行（P0-8）
///
/// 附件 pull 从云端 hash 列表差集下载，但 `sys_attachments` 表不在同步白名单
/// （03 文档 §六），新设备/删库后本地无记录——旧的 `mark_local_cached` 仅
/// UPDATE，affected rows = 0，记录永远缺失，导致每轮同步差集永不为空、
/// 全部附件反复重下。此方法在 UPDATE 未命中时插入占位行（原始文件名/mime
/// 未知，用 hash 占位；is_uploaded=1 因云端已存在该对象）。
///
/// `size_bytes` 为下载解密后的实际字节数（2026-09-14 修正：此前占位行恒
/// 写 0，UI 展示与上限校验失真）。冲突路径（本地行已存在）不回写 size，
/// 保留本地已有的真实元数据（original_name/mime_type 仅存于本地账本）。
pub async fn ensure_local_cached(
    pool: &SqlitePool,
    hash: &str,
    local_path: &str,
    size_bytes: i64,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                  is_uploaded, is_local_cached, created_at, last_accessed_at)
         VALUES (?, ?, 'application/octet-stream', ?, ?, 1, 1, ?, ?)
         ON CONFLICT(hash) DO UPDATE SET
            is_local_cached = 1,
            local_path = excluded.local_path,
            last_accessed_at = ?",
    )
    .bind(hash)
    .bind(hash)
    .bind(size_bytes)
    .bind(local_path)
    .bind(now)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

/// 检查附件是否已本地缓存
pub async fn is_local_cached(pool: &SqlitePool, hash: &str) -> CoreResult<bool> {
    let row: (i32,) = sqlx::query_as("SELECT is_local_cached FROM sys_attachments WHERE hash = ?")
        .bind(hash)
        .fetch_optional(pool)
        .await?
        .unwrap_or((0,));
    Ok(row.0 == 1)
}

/// 获取所有本地已缓存的附件
pub async fn get_all_local_cached(pool: &SqlitePool) -> CoreResult<Vec<Attachment>> {
    let items = sqlx::query_as::<_, Attachment>(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments WHERE is_local_cached = 1",
    )
    .fetch_all(pool)
    .await?;
    Ok(items)
}

/// 获取所有未上传的附件
pub async fn get_unuploaded(pool: &SqlitePool) -> CoreResult<Vec<Attachment>> {
    let items = sqlx::query_as::<_, Attachment>(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments WHERE is_uploaded = 0",
    )
    .fetch_all(pool)
    .await?;
    Ok(items)
}

/// 查询仍被存活任务引用的附件 hash 集合（S31：pull 差集的活跃引用过滤）
///
/// 云端孤儿附件（本端 GC 已删、但其他设备视角仍挂载的对象）在本端无任何
/// 任务引用——拉回它们只会重插占位行、耗磁盘与流量，且下一轮 GC 又删、
/// 再下一轮 pull 又拉回，形成「GC ↔ pull」对打架循环。pull 差集只保留
/// 本端有活跃引用的 hash，无引用的云端对象留在云端等真正需要时再拉。
pub async fn get_active_referenced_hashes(pool: &SqlitePool) -> CoreResult<Vec<String>> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT hash FROM todo_task_attachments WHERE is_deleted = 0")
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|(h,)| h).collect())
}

/// 按 hash 删除单个附件记录
pub async fn delete_by_hash(pool: &SqlitePool, hash: &str) -> CoreResult<()> {
    sqlx::query("DELETE FROM sys_attachments WHERE hash = ?")
        .bind(hash)
        .execute(pool)
        .await?;
    Ok(())
}

/// 统计附件总数
pub async fn count(pool: &SqlitePool) -> CoreResult<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM sys_attachments")
        .fetch_one(pool)
        .await?;
    Ok(count)
}

/// 按 hash 列表批量查询附件（用于详情页附件区域，避免 N 次查询）
pub async fn get_by_hashes(pool: &SqlitePool, hashes: &[String]) -> CoreResult<Vec<Attachment>> {
    if hashes.is_empty() {
        return Ok(Vec::new());
    }
    // SQLite 不支持绑定 Vec<String>，用 IN (?, ?, ...) 动态拼接
    let placeholders: Vec<&str> = hashes.iter().map(|_| "?").collect();
    let sql = format!(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments WHERE hash IN ({})",
        placeholders.join(", ")
    );
    let mut q = sqlx::query_as::<_, Attachment>(&sql);
    for hash in hashes {
        q = q.bind(hash);
    }
    let items = q.fetch_all(pool).await?;
    Ok(items)
}

/// 删除不在活跃哈希列表中的附件（垃圾回收）
pub async fn delete_orphans(pool: &SqlitePool, active_hashes: &[String]) -> CoreResult<()> {
    if active_hashes.is_empty() {
        // 无活跃附件时清空全部
        sqlx::query("DELETE FROM sys_attachments")
            .execute(pool)
            .await?;
        return Ok(());
    }
    // SQLite 不支持绑定 Vec<String>，逐条删除（附件数量通常不大）
    let active_set: std::collections::HashSet<&str> =
        active_hashes.iter().map(|s| s.as_str()).collect();
    let all: Vec<(String,)> = sqlx::query_as("SELECT hash FROM sys_attachments")
        .fetch_all(pool)
        .await?;
    for (hash,) in &all {
        if !active_set.contains(hash.as_str()) {
            sqlx::query("DELETE FROM sys_attachments WHERE hash = ?")
                .bind(hash)
                .execute(pool)
                .await?;
        }
    }
    Ok(())
}

// ---------- 磁盘缓存上限 + LRU 逐出（多设备安全口径）----------

/// 刷新附件最近访问时间（读取/挂载时调用；LRU 排序键）
pub async fn touch_last_accessed(pool: &SqlitePool, hash: &str) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query("UPDATE sys_attachments SET last_accessed_at = ? WHERE hash = ?")
        .bind(now)
        .bind(hash)
        .execute(pool)
        .await?;
    Ok(())
}

/// 本地已缓存附件的总占用（字节；is_local_cached=1 的 size_bytes 求和）
pub async fn cached_total_bytes(pool: &SqlitePool) -> CoreResult<i64> {
    let (total,): (i64,) = sqlx::query_as(
        "SELECT COALESCE(SUM(size_bytes), 0) FROM sys_attachments WHERE is_local_cached = 1",
    )
    .fetch_one(pool)
    .await?;
    Ok(total)
}

/// LRU 逐出候选：按最久未访问优先，返回本地已缓存且**已上传云端**的附件
///
/// 只逐出 `is_uploaded = 1` 的行——文件删了下一轮 push 不受影响（get_unuploaded
/// 按 is_uploaded 取集合，不读已删文件）；且保留账本行本身，pull 差集按
/// 「本地无缓存（is_local_cached=0）」判定会自然重拉有活跃引用的附件。
/// 未上传的（is_uploaded=0）绝不逐出：文件是云端唯一副本的 pending 源，
/// 删了会让每轮 push 读不到文件持续报错。
pub async fn get_lru_evictable(pool: &SqlitePool, limit_bytes: i64) -> CoreResult<Vec<Attachment>> {
    let items = sqlx::query_as::<_, Attachment>(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at, last_accessed_at
         FROM sys_attachments
         WHERE is_local_cached = 1 AND is_uploaded = 1
         ORDER BY last_accessed_at ASC",
    )
    .fetch_all(pool)
    .await?;
    // 只取到能凑出 limit_bytes 的最久未访问前缀（调用方按序逐出）
    let mut out = Vec::new();
    let mut acc = 0i64;
    for item in items {
        if acc >= limit_bytes {
            break;
        }
        acc += item.size_bytes;
        out.push(item);
    }
    Ok(out)
}

/// 逐出本地缓存：清 is_local_cached 标志 + 删本地文件（账本行保留）
///
/// 返回是否成功删掉本地文件（文件已缺失不视为错误）。
pub async fn evict_local_cache(
    pool: &SqlitePool,
    attachments_dir: &str,
    hash: &str,
) -> CoreResult<bool> {
    sqlx::query("UPDATE sys_attachments SET is_local_cached = 0 WHERE hash = ?")
        .bind(hash)
        .execute(pool)
        .await?;
    let path = std::path::Path::new(attachments_dir).join(hash);
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(CoreError::Other(format!("删除附件缓存文件失败: {}", e))),
    }
}
