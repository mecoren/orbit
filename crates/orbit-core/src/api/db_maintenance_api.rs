//! db_maintenance_api — 数据库维护 API（性能批次：磁盘维护 + 碎片整理）
//!
//! 只读维护路径：不 emit db-change 事件（前端缓存无需失效）、不进同步
//! 白名单（`PRAGMA` / `VACUUM` 只作用于本地库文件，墓碑与版本数据零
//! 改动——云端视角与未执行维护完全一致）。
//!
//! 口径：
//! - `db_maintenance`：一条命令跑完全套维护，返回各步量化结果；
//!   顺序 = WAL checkpoint → 附件 GC → 附件缓存上限（LRU）→ 日志表
//!   TTL prune → `PRAGMA optimize` → `VACUUM`。
//!   checkpoint 在前：把 WAL 帧回写主文件，VACUUM 才能真正回收磁盘空间
//!   （否则已 checkpoint 的页仍留在 -wal 里，主文件膨胀照旧）。
//! - 日志表 TTL：notification_log / todo_activity_log 各自 30 天
//!   （物理 DELETE——两表为本地轨迹无软删语义，且不在同步白名单，
//!   云端视角零影响；表只进不出会持续拖慢列表查询与 VACUUM）。
//! - VACUUM 前后 `freelist_count` 对比即碎片回收量（页数）；重写整库
//!   耗时与库体积成正比，本地应用秒级可接受，故不做 incremental_vacuum
//!   分档（auto_vacuum 未开启，回档需整库重写）。
//! - `PRAGMA optimize` 按 sqlite 官方建议跑 ANALYZE 子集（analysis_limit
//!   400 行采样），更新查询计划统计——排序/筛选类查询扫全表时可观提速。

use sqlx::SqlitePool;

use crate::api::asset_api;
use crate::error::CoreResult;

/// 日志表 TTL 保留天数（30 天，与 notification_log 模块头口径一致）
pub const LOG_TTL_DAYS: i64 = 30;

/// 维护结果视图（双端设置页展示用）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DbMaintenanceResult {
    /// WAL checkpoint 后 -wal 文件剩余大小（字节；TRUNCATE 尽力归零，
    /// 并发读持旧快照时可能残留，下次维护再收）
    pub wal_bytes_after_checkpoint: i64,
    /// 附件 GC 清理的孤立文件数
    pub attachments_cleaned: usize,
    /// 日志 TTL 清理的行数（notification_log + todo_activity_log）
    pub log_rows_pruned: u64,
    /// VACUUM 前空闲页数（碎片页）
    pub freelist_before: i64,
    /// VACUUM 后空闲页数（应为 0）
    pub freelist_after: i64,
    /// VACUUM 实际回收的页数
    pub pages_reclaimed: i64,
}

/// 读取单值 PRAGMA（i64 档位）
async fn pragma_i64(pool: &SqlitePool, name: &str) -> CoreResult<i64> {
    // name 全部为本文件内常量字面量，无注入面
    let row: (i64,) = sqlx::query_as(&format!("PRAGMA {}", name))
        .fetch_one(pool)
        .await?;
    Ok(row.0)
}

/// WAL checkpoint：把 -wal 日志帧回写主库文件并截断
///
/// `wal_checkpoint(TRUNCATE)` 尽力把 -wal 文件截断到 0 字节；有并发读
/// 持有旧快照时可能部分回写（返回 busy），不视为错误——下次维护再收。
/// wal_bytes 返回 checkpoint 后 -wal 文件实际大小（磁盘档案口径）。
async fn checkpoint_wal(pool: &SqlitePool) -> CoreResult<i64> {
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(pool)
        .await?;
    // 内存库无独立 -wal 文件，本口径仅对磁盘库有实义（0 = 无 wal 残留）
    Ok(0)
}

/// 执行全套数据库维护（设置页「立即维护」入口）
///
/// 各步独立容错：附件 GC 失败（如目录不可达）不影响其余步骤，
/// 失败步骤以 map_err 透传首个错误——调用方 toast 展示即可。
pub async fn db_maintenance(
    pool: &SqlitePool,
    attachments_dir: &str,
) -> CoreResult<DbMaintenanceResult> {
    // 1. WAL checkpoint：回收 -wal 磁盘占用，也让后续 VACUUM 能整库重写
    let wal_bytes_after_checkpoint = checkpoint_wal(pool).await?;

    // 2. 附件 GC：清理无任何任务引用的孤儿文件（上次 GC 错过/同步残留）
    let attachments_cleaned = asset_api::gc_local_attachments(pool, attachments_dir).await?;

    // 2.5 附件磁盘缓存上限：超 2GB 时 LRU 逐出已上传附件（只删本地文件，
    // 账本保留可重拉；多设备安全口径见 asset_api 模块文档）
    asset_api::enforce_attachment_cache_limit(pool, attachments_dir).await?;

    // 2.6 日志表 TTL：30 天前的通知/活动日志物理删除（两表本地轨迹不进
    // 同步白名单；表只进不出会持续涨表拖慢查询与 VACUUM）
    let notification_pruned =
        crate::api::notification_log_api::prune_old(pool, LOG_TTL_DAYS).await?;
    let activity_pruned = crate::api::activity_log_api::prune_old(pool, LOG_TTL_DAYS).await?;
    let log_rows_pruned = notification_pruned + activity_pruned;

    // 3. 更新查询计划统计（ANALYZE 采样）——排序/筛选查询提速
    sqlx::query("PRAGMA optimize").execute(pool).await?;

    // 4. VACUUM：整库重写，回收软删/编辑留下的碎片页
    let freelist_before = pragma_i64(pool, "freelist_count").await?;
    sqlx::query("VACUUM").execute(pool).await?;
    let freelist_after = pragma_i64(pool, "freelist_count").await?;

    Ok(DbMaintenanceResult {
        wal_bytes_after_checkpoint,
        attachments_cleaned,
        log_rows_pruned,
        freelist_before,
        freelist_after,
        pages_reclaimed: (freelist_before - freelist_after).max(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 内存库 + 全量迁移（附件 GC 依赖 sys_attachments/todo_task_attachments 真实表）
    async fn setup_db() -> SqlitePool {
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 维护全流程跑通（WAL/优化/VACUUM 各步不报错），
    /// 空闲页口径 VACUUM 后应为 0，数据不丢
    #[tokio::test]
    async fn maintenance_reclaims_freelist_and_reports() {
        let pool = setup_db().await;

        // 制造碎片：建表插行再 DROP，产生空闲页
        sqlx::query("CREATE TABLE junk (id INTEGER PRIMARY KEY);")
            .execute(&pool)
            .await
            .unwrap();
        for i in 0..200 {
            sqlx::query("INSERT INTO junk (id) VALUES (?)")
                .bind(i)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("DROP TABLE junk").execute(&pool).await.unwrap();

        // 存量数据锚点：插入一个项目并回读
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, created_at, updated_at) \
                     VALUES ('p1', '锚点项目', 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let tmp = tempfile::tempdir().unwrap();
        let r = db_maintenance(&pool, tmp.path().to_str().unwrap())
            .await
            .unwrap();
        assert_eq!(r.freelist_after, 0, "VACUUM 后空闲页应归零");
        assert_eq!(r.pages_reclaimed, r.freelist_before);
        // 附件 GC 在空账本上清 0
        assert_eq!(r.attachments_cleaned, 0);
        // 数据经维护不丢（按 uuid 定位锚点行——迁移自带默认「收件箱」项目）
        let (title,): (String,) =
            sqlx::query_as("SELECT title FROM todo_projects WHERE uuid = 'p1'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(title, "锚点项目");
    }

    /// 日志表 TTL 接线：30 天前的通知/活动日志在维护中物理删除，30 天内保留
    #[tokio::test]
    async fn maintenance_prunes_stale_log_rows() {
        let pool = setup_db().await;
        let old_ms = chrono::Utc::now().timestamp_millis() - (LOG_TTL_DAYS + 1) * 86_400_000;
        let now_ms = chrono::Utc::now().timestamp_millis();

        // 过期 + 新鲜各一条（两表同口径；直接手插控制 created_at）
        sqlx::query(
            "INSERT INTO notification_log (kind, task_id, task_title, reminder_id, payload, created_at)
             VALUES ('reminder_due', 1, '旧通知', 1, '{}', ?)",
        )
        .bind(old_ms)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO notification_log (kind, task_id, task_title, reminder_id, payload, created_at)
             VALUES ('reminder_due', 1, '新通知', 1, '{}', ?)",
        )
        .bind(now_ms)
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO todo_activity_log (task_id, task_title, action, detail, created_at)
             VALUES (1, '旧活动', 'create', '{}', ?)",
        )
        .bind(old_ms)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO todo_activity_log (task_id, task_title, action, detail, created_at)
             VALUES (1, '新活动', 'update', '{}', ?)",
        )
        .bind(now_ms)
        .execute(&pool)
        .await
        .unwrap();

        let tmp = tempfile::tempdir().unwrap();
        let r = db_maintenance(&pool, tmp.path().to_str().unwrap())
            .await
            .unwrap();
        assert_eq!(r.log_rows_pruned, 2, "过期通知+过期活动各一行");

        let (n_old,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM notification_log WHERE task_title = '旧通知'")
                .fetch_one(&pool)
                .await
                .unwrap();
        let (n_new,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM notification_log WHERE task_title = '新通知'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((n_old, n_new), (0, 1), "过期通知删、新鲜通知留");

        let (a_old,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_activity_log WHERE action = 'create'")
                .fetch_one(&pool)
                .await
                .unwrap();
        let (a_new,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_activity_log WHERE action = 'update'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((a_old, a_new), (0, 1), "过期活动删、新鲜活动留");
    }
}
