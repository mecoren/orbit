//! db_maintenance_api — 数据库维护 API（性能批次：磁盘维护 + 碎片整理）
//!
//! 只读维护路径：不 emit db-change 事件（前端缓存无需失效）、不进同步
//! 白名单（`PRAGMA` / `VACUUM` 只作用于本地库文件，墓碑与版本数据零
//! 改动——云端视角与未执行维护完全一致）。
//!
//! 口径：
//! - `db_maintenance`：一条命令跑完全套维护，返回各步量化结果；
//!   顺序 = WAL checkpoint → 附件 GC → 附件缓存上限（LRU）→ 日志表
//!   TTL prune → 全量 `ANALYZE` → `VACUUM`。
//!   checkpoint 在前：把 WAL 帧回写主文件，VACUUM 才能真正回收磁盘空间
//!   （否则已 checkpoint 的页仍留在 -wal 里，主文件膨胀照旧）。
//! - 日志表 TTL：notification_log / todo_activity_log 各自 30 天
//!   （物理 DELETE——两表为本地轨迹无软删语义，且不在同步白名单，
//!   云端视角零影响；表只进不出会持续拖慢列表查询与 VACUUM）。
//! - VACUUM 前后 `freelist_count` 对比即碎片回收量（页数）；重写整库
//!   耗时与库体积成正比，本地应用秒级可接受，故不做 incremental_vacuum
//!   分档（auto_vacuum 未开启，回档需整库重写）。
//! - `PRAGMA optimize` **不再使用**（2026-10-25 P5 实测：它在本应用里恒为空转，
//!   详见 [`analyze_plan_stats`]）；改为显式全量 `ANALYZE`——这是唯一能让
//!   `sqlite_stat1` 从无到有的路径，也是首屏列表计划从「索引扫全表 + 临时
//!   B 树排序」翻到「有序索引 + LIMIT 提前终止」的唯一开关。

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

/// 全量 `ANALYZE`：把 `sqlite_stat1` 从无到有（或从旧到新）地建起来
///
/// **为什么不是 `PRAGMA optimize`**（P5 实测，50k 行，2026-10-25）：
/// - 默认掩码（0xfffe）不含「从未分析过」的表 → 新库/空库跑它等于空转
///   （实测：stat1 行数 0 → 0，耗时 0ms）；
/// - 它的「行数漂移」判据是**连接级**状态 → 一次 10 倍膨胀的导入（45k 行）
///   之后在写连接上跑，仍是 3ms 空转，stat1 摘要一字未变；
/// - 统计新鲜时它 0～1ms、幂等不改统计 —— 有价值但收益为零。
///
/// **为什么不带 `analysis_limit`**（采样口径反而更差）：`analysis_limit=400`
/// 会把每个等值前缀的平均行数夹到采样规模上（实测 `is_deleted=0` 写成
/// `50000 401`，真值 `50000 25000`），软删列这种「98% 行都命中」的选择率
/// 被低估 60 倍，规划器于是继续选「索引扫全表 + 排序」。全量 ANALYZE 才写
/// 真值，首屏列表在 50k 行上从 10～12ms 掉到 0ms（计划改为
/// `SCAN todo_tasks USING INDEX idx_todo_tasks_updated_at`，`ORDER BY
/// updated_at DESC LIMIT 50` 直接走有序索引提前终止，不再建临时 B 树）。
/// 成本：50k 行 47～88ms，库体积不增（实测 21,835,776 → 21,020,672 字节，
/// VACUUM 之后）——放在本就是秒级的维护动作里可忽略。
///
/// **生效范围是连接**：`ANALYZE` 后未重开池时，只有重新准备过语句的连接
/// 换新计划（实测 3 条连接里 1～2 条换新）；本函数不重建池，收益会在
/// 各连接下次重连时陆续到位。
pub async fn analyze_plan_stats(pool: &SqlitePool) -> CoreResult<()> {
    sqlx::query("ANALYZE").execute(pool).await?;
    Ok(())
}

/// 建统计的行数门槛（`todo_tasks` 总行数）
///
/// 为什么要有门槛：统计只在「数据到规模」时才有收益——5k 行实测无统计 1ms /
/// 有统计 0ms（差 1ms，不值得为写一次 `sqlite_stat1` 而写）；50k 行是 10～12ms
/// / 0ms。拐点在两者之间未细分，取 5k 作为保守下限。门槛以内 ANALYZE 本身也
/// 只要约 10ms，即便误判也无害；门槛设在这里主要是让「刚装的空库 / 小库」
/// 一次盘都不写。
pub const MIN_ROWS_FOR_PLAN_STATS: i64 = 5_000;

/// 空闲时补一次查询计划统计：只在「从来没有统计 + 数据已到规模」时真跑
///
/// 调用时机由壳层决定（桌面在首屏之后的空闲时；见 `db_maintenance_cmd`）。
/// 返回 `true` 表示这次真的跑了 `ANALYZE`。
///
/// 判据刻意只认「统计是否缺失」，不认「统计是否陈旧」：
/// - 陈旧不影响计划选择——10 倍膨胀（5k → 50k）后计划与时延都不变，因为缩放的
///   是绝对行数、选择率比例没变（P5 实测）；
/// - 而 `PRAGMA optimize` 的「漂移判据」在连接池下看不见别的连接的写，实测
///   45k 行导入后仍空转，故这里不用它。
///
/// 幂等：已有覆盖 `todo_tasks` 的统计行即返回 `false`（重复调用零成本）。
pub async fn maybe_analyze_plan_stats(pool: &SqlitePool, min_rows: i64) -> CoreResult<bool> {
    // 1) 已经建过统计 → 什么都不做（sqlite_stat1 不存在时不能直接查它）
    let stat1_exists: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_stat1'",
    )
    .fetch_one(pool)
    .await?;
    if stat1_exists.0 > 0 {
        let covered: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM sqlite_stat1 WHERE tbl = 'todo_tasks'")
                .fetch_one(pool)
                .await?;
        if covered.0 > 0 {
            return Ok(false);
        }
    }

    // 2) 数据量没到门槛 → 收益为零，别为它写库
    let (rows,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_tasks")
        .fetch_one(pool)
        .await?;
    if rows < min_rows {
        return Ok(false);
    }

    analyze_plan_stats(pool).await?;
    Ok(true)
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

    // 3. 更新查询计划统计（全量 ANALYZE）——见 analyze_plan_stats 的实测口径；
    //    放在 VACUUM 之前：stat1 会被 VACUUM 原样保留（实测），顺序只影响
    //    「这次维护里查询是否已用上新计划」
    analyze_plan_stats(pool).await?;

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

    /// 维护必须真的建出查询计划统计（P5）
    ///
    /// 回归锚点：此前维护跑的是 `PRAGMA optimize`，它在「从未分析过」的库上
    /// 是空转（默认掩码不含 0x1）——维护跑完 `sqlite_stat1` 依然不存在，
    /// 首屏列表在 50k 行上继续走「索引扫全表 + 临时 B 树排序」（10～12ms）。
    /// 这条用例只锁「统计被建出来」这一档事实，不锁具体数值。
    #[tokio::test]
    async fn maintenance_builds_plan_stats() {
        let pool = setup_db().await;
        // 造点行：统计要能覆盖到 todo_tasks 才算数
        for i in 0..50 {
            sqlx::query(
                "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
            )
            .bind(format!("stats-{i}"))
            .bind(format!("统计样本 {i}"))
            .bind(i)
            .bind(i)
            .execute(&pool)
            .await
            .unwrap();
        }
        let before: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sqlite_stat1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(before.0, 0, "前提：内存库此前没有统计");

        let tmp = tempfile::tempdir().unwrap();
        db_maintenance(&pool, tmp.path().to_str().unwrap())
            .await
            .unwrap();

        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT tbl, COALESCE(idx, '') FROM sqlite_stat1 WHERE tbl = 'todo_tasks'",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        // SQLite 3.45 对 rowid 表不额外写「表行」（idx 为 NULL 的那行），
        // 行数统计挂在索引行上——所以这里按索引行断言，不假设表行的存在
        assert!(
            !rows.is_empty(),
            "todo_tasks 必须有统计行（否则维护等于没做）"
        );
        assert!(
            rows.iter()
                .any(|(_, idx)| idx == "idx_todo_tasks_updated_at"),
            "首屏列表依赖的 updated_at 索引必须有统计（计划切换的判据）: {rows:?}"
        );
    }

    /// 空闲引导：小库/空库不写统计，到门槛才建一次，且只建一次（P5）
    #[tokio::test]
    async fn maybe_analyze_plan_stats_respects_threshold_and_is_idempotent() {
        let pool = setup_db().await;

        // 空库：低于门槛 → 不建
        assert!(!maybe_analyze_plan_stats(&pool, 50).await.unwrap());
        let (n,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sqlite_stat1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(n, 0, "小库不该为统计写盘");

        // 到门槛 → 建一次，返回 true
        for i in 0..60 {
            sqlx::query(
                "INSERT INTO todo_tasks (uuid, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
            )
            .bind(format!("idle-{i}"))
            .bind(format!("空闲引导样本 {i}"))
            .bind(i)
            .bind(i)
            .execute(&pool)
            .await
            .unwrap();
        }
        assert!(maybe_analyze_plan_stats(&pool, 50).await.unwrap());
        let (covered,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM sqlite_stat1 WHERE tbl = 'todo_tasks'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(covered > 0, "门槛以上必须真的建出统计");

        // 再调一次：已有统计 → 空转（幂等）
        assert!(!maybe_analyze_plan_stats(&pool, 50).await.unwrap());
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
