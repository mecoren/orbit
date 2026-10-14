//! diagnostics — 应用内诊断读数（只读聚合）
//!
//! ## 为什么要有这个 API
//!
//! 内存/性能门禁（`perf-metrics/`）只在仓库侧可用：用户报障时我们没法让他装
//! 工具链。本模块把**应用内可见**的那部分读数收成一次调用：库体积、各表行数、
//! 墓碑行数、附件本地缓存体积。前端「设置 → 诊断」分区渲染它。
//!
//! ## 口径
//!
//! - **只读聚合**：不 emit db-change、不进同步白名单（AGENTS「只读聚合不进同步
//!   白名单」），也不写任何状态。
//! - 行数一律按 `is_deleted = 0`（活行）；墓碑行数单列，便于判断「回收站里的
//!   东西还没同步出去」这类问题。
//! - 库体积取 SQLite 自身口径（`page_count × page_size`），不含 WAL 与附件目录。
//! - 附件缓存体积是**磁盘**占用，与内存中的字节缓存（F4/A9）无关。
//! - 表清单固定取自 [`SYNCABLE_TABLES`]：行数是逐表 COUNT，属有界固定次数的查询。

use std::path::Path;

use serde::Serialize;
use sqlx::SqlitePool;

use crate::db::sync_registry::SYNCABLE_TABLES;
use crate::error::CoreResult;

/// 单表活行数
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TableRowCount {
    /// 表名（与 `sync_registry` 白名单同名）
    pub table: String,
    /// `is_deleted = 0` 的行数
    pub rows: i64,
}

/// 应用内诊断快照（只读）
#[derive(Debug, Clone, Serialize, Default, PartialEq, Eq)]
pub struct DiagnosticsSnapshot {
    /// 本地库体积（字节，SQLite `page_count × page_size`）
    pub db_size_bytes: i64,
    /// 各表活行数（固定顺序 = 同步白名单顺序）
    pub table_rows: Vec<TableRowCount>,
    /// 全部可同步表的墓碑行数合计（`is_deleted = 1`）
    pub tombstone_rows: i64,
    /// 附件本地缓存体积（字节；`attachments_dir` 为空时恒 0）
    pub attachment_cache_bytes: i64,
    /// 附件本地缓存文件数
    pub attachment_cache_files: i64,
}

/// 采集诊断快照
///
/// `attachments_dir` 为空串表示不统计附件缓存（取不到应用数据目录时的降级）；
/// 路径不存在同样按 0 处理（首次运行尚未产生附件）。
pub async fn diagnostics_snapshot(
    pool: &SqlitePool,
    attachments_dir: &str,
) -> CoreResult<DiagnosticsSnapshot> {
    let mut snapshot = DiagnosticsSnapshot {
        db_size_bytes: db_size_bytes(pool).await?,
        ..Default::default()
    };

    for table in SYNCABLE_TABLES {
        let live: (i64,) = sqlx::query_as(&format!(
            "SELECT COUNT(*) FROM {table} WHERE is_deleted = 0"
        ))
        .fetch_one(pool)
        .await?;
        snapshot.table_rows.push(TableRowCount {
            table: (*table).to_string(),
            rows: live.0,
        });
        let tomb: (i64,) = sqlx::query_as(&format!(
            "SELECT COUNT(*) FROM {table} WHERE is_deleted = 1"
        ))
        .fetch_one(pool)
        .await?;
        snapshot.tombstone_rows += tomb.0;
    }

    if !attachments_dir.is_empty() {
        let (bytes, files) = dir_usage(Path::new(attachments_dir)).await;
        snapshot.attachment_cache_bytes = bytes;
        snapshot.attachment_cache_files = files;
    }

    Ok(snapshot)
}

/// SQLite 库体积：`page_count × page_size`（WAL/SHM 不计入）
async fn db_size_bytes(pool: &SqlitePool) -> CoreResult<i64> {
    let page_count: (i64,) = sqlx::query_as("PRAGMA page_count").fetch_one(pool).await?;
    let page_size: (i64,) = sqlx::query_as("PRAGMA page_size").fetch_one(pool).await?;
    Ok(page_count.0.saturating_mul(page_size.0))
}

/// 目录占用（字节、文件数）；路径不存在或不可读按 (0, 0) 处理
///
/// 只统计常规文件（跳过目录/符号链接），`read_dir` 失败不报错——诊断分区不该
/// 因为一个权限问题整页失败。
async fn dir_usage(dir: &Path) -> (i64, i64) {
    let Ok(mut entries) = tokio::fs::read_dir(dir).await else {
        return (0, 0);
    };
    let mut bytes = 0i64;
    let mut files = 0i64;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if let Ok(meta) = entry.metadata().await
            && meta.is_file()
        {
            bytes = bytes.saturating_add(meta.len() as i64);
            files += 1;
        }
    }
    (bytes, files)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup() -> SqlitePool {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[tokio::test]
    async fn snapshot_reports_db_size_and_all_tables() {
        let pool = setup().await;
        let snap = diagnostics_snapshot(&pool, "").await.unwrap();
        assert!(snap.db_size_bytes > 0, "库体积必须为正");
        assert_eq!(
            snap.table_rows.len(),
            SYNCABLE_TABLES.len(),
            "每张可同步表都要出一行读数"
        );
        assert_eq!(
            snap.table_rows
                .iter()
                .map(|r| r.table.as_str())
                .collect::<Vec<_>>(),
            SYNCABLE_TABLES.to_vec(),
            "顺序与白名单一致（前端按固定顺序展示）"
        );
        assert_eq!(snap.attachment_cache_bytes, 0, "未传目录时不统计附件");
        assert_eq!(snap.attachment_cache_files, 0);
    }

    #[tokio::test]
    async fn live_and_tombstone_rows_are_split() {
        let pool = setup().await;
        // 迁移会带种子行（如默认项目），故按增量断言
        let before = diagnostics_snapshot(&pool, "").await.unwrap();
        let before_live = rows_of(&before, "todo_projects");
        let before_tomb = before.tombstone_rows;

        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
             VALUES ('d1','活',1,1), ('d2','墓碑',1,1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("UPDATE todo_projects SET is_deleted = 1, deleted_at = 5 WHERE uuid = 'd2'")
            .execute(&pool)
            .await
            .unwrap();

        let after = diagnostics_snapshot(&pool, "").await.unwrap();
        assert_eq!(
            rows_of(&after, "todo_projects"),
            before_live + 1,
            "活行只数 is_deleted = 0"
        );
        assert_eq!(after.tombstone_rows, before_tomb + 1, "墓碑行单列统计");
    }

    fn rows_of(snap: &DiagnosticsSnapshot, table: &str) -> i64 {
        snap.table_rows
            .iter()
            .find(|r| r.table == table)
            .expect("表必须在读数里")
            .rows
    }

    #[tokio::test]
    async fn attachment_cache_usage_sums_regular_files_only() {
        let pool = setup().await;
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path();
        tokio::fs::create_dir(dir.join("sub")).await.unwrap();
        tokio::fs::write(dir.join("a.bin"), vec![7u8; 1024])
            .await
            .unwrap();
        tokio::fs::write(dir.join("b.bin"), vec![7u8; 256])
            .await
            .unwrap();

        let snap = diagnostics_snapshot(&pool, dir.to_str().unwrap())
            .await
            .unwrap();
        assert_eq!(snap.attachment_cache_bytes, 1280);
        assert_eq!(snap.attachment_cache_files, 2, "子目录不计入文件数");
    }

    #[tokio::test]
    async fn missing_attachment_dir_is_zero_not_error() {
        let pool = setup().await;
        let snap = diagnostics_snapshot(&pool, "definitely/not/here")
            .await
            .unwrap();
        assert_eq!(snap.attachment_cache_bytes, 0);
        assert_eq!(snap.attachment_cache_files, 0);
    }
}
