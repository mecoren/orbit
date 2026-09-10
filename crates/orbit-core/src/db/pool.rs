//! pool — 数据库连接池初始化
//!
//! SQLCipher 加密通过 PRAGMA key 启用（详见 design.md 第四节 4.2）。
//! 迁移由 sqlx::migrate! 宏在连接池建立后自动应用。

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions};
use std::path::Path;
use std::str::FromStr;
use std::time::Duration;

use crate::error::CoreResult;

/// SQLite page cache 每连接上限（-2000 = 兆字节口径，2MB）
///
/// 默认（-2000 即 2MB）下大查询会逐连接膨胀到几十 MB 不归还；收紧到
/// 8MB 上限档覆盖本应用查询工作集（列表分页/统计聚合），超限页让出，
/// 多连接场景显式封顶可预期（6 连接 × ≤8MB）。
const PAGE_CACHE_MB: i64 = 8;

/// 初始化加密数据库连接池
///
/// # 参数
/// - `db_path`：数据库文件路径
/// - `db_key`：主密码派生的数据库密钥（明文 passphrase 或 PRAGMA key 表达式）。
///   None 则不加密（明文数据库）。
///
/// # 流程
/// 1. 构建 SQLite 连接选项（WAL 模式 + 外键约束 + 忙等待 + 每连接 PRAGMA）
/// 2. 建立连接池（max_connections=6）
/// 3. 若提供密钥，经 options.pragma 注入 PRAGMA key（sqlx 保证每条
///    连接建立时都执行、且 key 最先于其它 PRAGMA——池是惰性建连接的，
///    直接对池执行只会命中第一条连接，加密库后续连接将因未解密读出密文）
/// 4. 运行迁移脚本（migrations/ 目录）
pub async fn init_pool(db_path: &Path, db_key: Option<&str>) -> CoreResult<SqlitePool> {
    let url = format!("sqlite://{}?mode=rwc", db_path.display());
    let mut opts = SqliteConnectOptions::from_str(&url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(5))
        // page cache 每连接封顶（性能批次内存优化口径，见 PAGE_CACHE_MB）
        .pragma("cache_size", format!("-{}", PAGE_CACHE_MB * 1024));

    // SQLCipher 加密（主密码开启时）：经 options 注入保证逐连接生效。
    // 值含引号/反斜杠时按 SQL 字符串字面量转义（PRAGMA key = '...' 形式）
    if let Some(key) = db_key {
        let escaped = key.replace('\'', "''");
        opts = opts.pragma("key", format!("'{escaped}'"));
    }

    // 连接池 6：同步 push/pull 已串行化（WebDAV 并发 MKCOL 503 与
    // ProgressSender Send 约束两轮踩坑后收敛），单同步流最多占 1 连接；
    // UI 命令 + 备份/提醒/节假日调度器并发余量 5 足够。SQLite WAL 下
    // 多连接可并发读、串行写（busy_timeout=5s 等待）
    let pool = SqlitePoolOptions::new()
        .max_connections(6)
        .connect_with(opts)
        .await?;

    // 运行迁移（嵌入 src/db/migrations/ 目录的 .sql 文件）
    sqlx::migrate!("./src/db/migrations").run(&pool).await?;

    Ok(pool)
}

/// 初始化明文（无加密）数据库连接池
pub async fn init_pool_unencrypted(db_path: &Path) -> CoreResult<SqlitePool> {
    init_pool(db_path, None).await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每连接 PRAGMA 生效口径：并发取满池连接，逐条校验
    /// foreign_keys 与 cache_size（曾因 PRAGMA 只跑第一条连接潜伏未解密 bug）
    #[tokio::test]
    async fn pragmas_apply_to_every_pooled_connection() {
        let tmp = tempfile::tempdir().unwrap();
        let pool = init_pool_unencrypted(&tmp.path().join("t.db"))
            .await
            .unwrap();

        // 并发取 6 条连接（全部即时建立后各自持有）
        let conns: Vec<_> =
            futures::future::join_all(std::iter::repeat_with(|| pool.acquire()).take(6))
                .await
                .into_iter()
                .map(|c| c.unwrap())
                .collect();

        for (i, mut conn) in conns.into_iter().enumerate() {
            let (fk,): (i64,) = sqlx::query_as("PRAGMA foreign_keys")
                .fetch_one(&mut *conn)
                .await
                .unwrap();
            assert_eq!(fk, 1, "连接 {i} foreign_keys 未生效");
            let (cache,): (i64,) = sqlx::query_as("PRAGMA cache_size")
                .fetch_one(&mut *conn)
                .await
                .unwrap();
            assert_eq!(cache, -PAGE_CACHE_MB * 1024, "连接 {i} cache_size 未生效");
        }
    }
}
