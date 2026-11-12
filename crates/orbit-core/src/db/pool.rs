//! pool — 数据库连接池初始化
//!
//! SQLCipher 加密通过 PRAGMA key 启用（详见 design.md 第四节 4.2）。
//! 迁移由 sqlx::migrate! 宏在连接池建立后自动应用。

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions};
use std::path::Path;
use std::str::FromStr;
use std::time::Duration;

use crate::error::{CoreError, CoreResult};

/// SQLite page cache 每连接上限（-2000 = 兆字节口径，2MB）
///
/// 默认（-2000 即 2MB）下大查询会逐连接膨胀到几十 MB 不归还；收紧到
/// 8MB 上限档覆盖本应用查询工作集（列表分页/统计聚合），超限页让出，
/// 多连接场景显式封顶可预期（6 连接 × ≤8MB）。
const PAGE_CACHE_MB: i64 = 8;

/// 连接池上限（内存治理 A8：6 → 3）
///
/// 口径：同步 push/pull 已串行化（WebDAV 并发 MKCOL 503 与 ProgressSender Send
/// 约束两轮踩坑后收敛），单同步流最多占 1 连接；UI 命令 + 备份 / 提醒 / 节假日 /
/// 回收站调度器并发余量 2 足够（各调度器互不同拍，且都短事务）。SQLite WAL 下
/// 多连接可并发读、串行写（busy_timeout=5s 等待），池越大只是多份 page cache
/// 驻留——池上限即是内存下界，故取满足并发需求的最小值。
const MAX_CONNECTIONS: u32 = 3;

/// 初始化加密数据库连接池
///
/// # 参数
/// - `db_path`：数据库文件路径
/// - `db_key`：主密码派生的数据库密钥（明文 passphrase 或 PRAGMA key 表达式）。
///   None 则不加密（明文数据库）。
///
/// # 流程
/// 1. 构建 SQLite 连接选项（WAL 模式 + 外键约束 + 忙等待 + 每连接 PRAGMA）
/// 2. 建立连接池（`MAX_CONNECTIONS`，见常量口径）
/// 3. 若提供密钥，经 options.pragma 注入 PRAGMA key（sqlx 保证每条
///    连接建立时都执行、且 key 最先于其它 PRAGMA——池是惰性建连接的，
///    直接对池执行只会命中第一条连接，加密库后续连接将因未解密读出密文）
/// 4. 运行迁移脚本（migrations/ 目录）
pub async fn init_pool(db_path: &Path, db_key: Option<&str>) -> CoreResult<SqlitePool> {
    // 先清掉上次迁移崩溃遗留的明文/半成品临时库，再打开数据库（见 migrate.rs）。
    // 放在最前面：加密库存在时旁边多一份整库明文副本，等于加密形同虚设。
    crate::db::migrate::cleanup_orphan_migration_tmp(db_path)?;

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

    // 连接池上限：口径见 MAX_CONNECTIONS 注释（性能批次 A8：6 → 3）
    let pool = SqlitePoolOptions::new()
        .max_connections(MAX_CONNECTIONS)
        .connect_with(opts)
        .await?;

    // 运行迁移（嵌入 src/db/migrations/ 目录的 .sql 文件）
    if let Err(e) = sqlx::migrate!("./src/db/migrations").run(&pool).await {
        // 0001 是冻结基线：被并回改写后，老库 _sqlx_migrations 的 version 1
        // 校验和对不上。裸 VersionMismatch 只说「已应用但被修改」，用户按字面
        // 理解会直接删库——必须给出备份与恢复路径。0001 头注中「init_pool
        // 无兜底」的旧描述以本分支为准，基线文件本身保持冻结不动。
        if let sqlx::migrate::MigrateError::VersionMismatch(_) = &e {
            pool.close().await;
            return Err(CoreError::Other(format!(
                "数据库迁移基线校验和不匹配：{e}。请先备份当前数据库文件（含 -wal/-shm），\
                 再通过云同步或全量备份恢复；切勿直接删除数据库。\
                 若确属未发布版本的一次性基线重建，须明确接受存量库重装。"
            )));
        }
        return Err(e.into());
    }

    // 恢复逻辑时钟（慢表重启后不得让时间戳回落到墙上时钟，见 db/clock.rs）
    crate::db::clock::load(&pool).await?;

    Ok(pool)
}

/// 初始化明文（无加密）数据库连接池
pub async fn init_pool_unencrypted(db_path: &Path) -> CoreResult<SqlitePool> {
    init_pool(db_path, None).await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 迁移崩溃遗留的临时库必须在下次启动被清扫
    ///
    /// `migrate_to_plaintext` 成功导出后、finalize rename 前若进程崩溃，
    /// `*.db.plain_tmp` 就是一份**整库明文副本**，会一直躺在加密库旁边。
    #[tokio::test]
    async fn orphan_migration_tmp_files_are_cleaned_on_startup() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("orbit.db");
        let plain_tmp = tmp.path().join("orbit.db.plain_tmp");
        let enc_tmp = tmp.path().join("orbit.db.enc_tmp");
        std::fs::write(&plain_tmp, b"PLAINTEXT-LEAK").unwrap();
        std::fs::write(&enc_tmp, b"half-written").unwrap();

        let pool = init_pool_unencrypted(&db).await.unwrap();
        pool.close().await;

        assert!(!plain_tmp.exists(), "明文临时库残留等于加密库旁躺着明文");
        assert!(!enc_tmp.exists(), "半成品加密临时库必须一并清除");
        assert!(db.exists(), "正常库文件不得被误删");
    }

    /// 每连接 PRAGMA 生效口径：并发取满池连接，逐条校验
    /// foreign_keys 与 cache_size（曾因 PRAGMA 只跑第一条连接潜伏未解密 bug）
    #[tokio::test]
    async fn pragmas_apply_to_every_pooled_connection() {
        let tmp = tempfile::tempdir().unwrap();
        let pool = init_pool_unencrypted(&tmp.path().join("t.db"))
            .await
            .unwrap();

        // 并发取满整池连接（全部即时建立后各自持有）——池上限随 A8 收紧，
        // 此处按常量取数，避免写死数字与上限漂移
        let conns: Vec<_> = futures::future::join_all(
            std::iter::repeat_with(|| pool.acquire()).take(MAX_CONNECTIONS as usize),
        )
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

    /// 基线被并回改写后，老库 `_sqlx_migrations` 的 version 1 校验和对不上。
    /// `init_pool` 不能只抛一句 VersionMismatch：用户必须先备份、再走恢复路径，
    /// 否则第一反应就是删库，数据直接没了。
    #[tokio::test]
    async fn version_mismatch_error_explains_backup_and_recovery() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("orbit.db");
        let pool = init_pool_unencrypted(&db).await.unwrap();
        sqlx::query(
            "UPDATE _sqlx_migrations SET checksum = X'00000000000000000000000000000000' WHERE version = 1",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool.close().await;

        let err = match init_pool_unencrypted(&db).await {
            Ok(p) => {
                p.close().await;
                panic!("校验和不匹配必须报错，不能让旧库带着错基线启动");
            }
            Err(e) => e.to_string(),
        };
        assert!(err.contains("备份"), "应提示先备份当前库: {err}");
        assert!(
            err.contains("云同步") && err.contains("恢复"),
            "应提示云同步 / 全量备份恢复路径: {err}"
        );
    }
}
