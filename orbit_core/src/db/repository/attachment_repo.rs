//! attachment_repo — 附件元数据仓储
//!
//! 管理 sys_attachments 表的 CRUD 操作。
//! 附件以 hash 为主键，记录上传/缓存状态，供 AssetSyncService 使用。

use sqlx::SqlitePool;

use crate::error::CoreResult;
use crate::models::business::Attachment;

/// 根据 hash 查询单个附件
pub async fn get_by_hash(pool: &SqlitePool, hash: &str) -> CoreResult<Option<Attachment>> {
    let item = sqlx::query_as::<_, Attachment>(
        "SELECT hash, original_name, mime_type, size_bytes, local_path,
                is_uploaded, is_local_cached, created_at
         FROM sys_attachments WHERE hash = ?",
    )
    .bind(hash)
    .fetch_optional(pool)
    .await?;
    Ok(item)
}

/// 插入或更新附件（以 hash 为冲突键）
pub async fn upsert(pool: &SqlitePool, a: &Attachment) -> CoreResult<()> {
    sqlx::query(
        "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path,
                                  is_uploaded, is_local_cached, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(hash) DO UPDATE SET
            original_name = excluded.original_name,
            mime_type = excluded.mime_type,
            size_bytes = excluded.size_bytes,
            local_path = excluded.local_path,
            is_uploaded = excluded.is_uploaded,
            is_local_cached = excluded.is_local_cached,
            created_at = excluded.created_at",
    )
    .bind(&a.hash)
    .bind(&a.original_name)
    .bind(&a.mime_type)
    .bind(a.size_bytes)
    .bind(&a.local_path)
    .bind(a.is_uploaded)
    .bind(a.is_local_cached)
    .bind(&a.created_at)
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

/// 标记附件已本地缓存
pub async fn mark_local_cached(pool: &SqlitePool, hash: &str, local_path: &str) -> CoreResult<()> {
    sqlx::query("UPDATE sys_attachments SET is_local_cached = 1, local_path = ? WHERE hash = ?")
        .bind(local_path)
        .bind(hash)
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
                is_uploaded, is_local_cached, created_at
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
                is_uploaded, is_local_cached, created_at
         FROM sys_attachments WHERE is_uploaded = 0",
    )
    .fetch_all(pool)
    .await?;
    Ok(items)
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
                is_uploaded, is_local_cached, created_at
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
        sqlx::query("DELETE FROM sys_attachments").execute(pool).await?;
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
