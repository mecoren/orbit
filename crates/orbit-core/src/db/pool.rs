//! pool — 数据库连接池初始化
//!
//! SQLCipher 加密通过 PRAGMA key 启用（详见 design.md 第四节 4.2）。
//! 迁移由 sqlx::migrate! 宏在连接池建立后自动应用。

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions};
use std::path::Path;
use std::str::FromStr;
use std::time::Duration;

use crate::error::CoreResult;

/// 初始化加密数据库连接池
///
/// # 参数
/// - `db_path`：数据库文件路径
/// - `db_key`：主密码派生的数据库密钥（明文 passphrase 或 PRAGMA key 表达式）。
///   None 则不加密（明文数据库）。
///
/// # 流程
/// 1. 构建 SQLite 连接选项（WAL 模式 + 外键约束 + 忙等待）
/// 2. 建立连接池（max_connections=5）
/// 3. 若提供密钥，执行 PRAGMA key 启用 SQLCipher
/// 4. 启用外键约束
/// 5. 运行迁移脚本（migrations/ 目录）
pub async fn init_pool(db_path: &Path, db_key: Option<&str>) -> CoreResult<SqlitePool> {
    let url = format!("sqlite://{}?mode=rwc", db_path.display());
    let opts = SqliteConnectOptions::from_str(&url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(5));

    // 连接池大小 10：支持同步模块级并行（8 并发）+ UI/后台读写余量
    // SQLite WAL 模式下多连接可并发读、串行写（busy_timeout=5s 等待）
    let pool = SqlitePoolOptions::new()
        .max_connections(10)
        .connect_with(opts)
        .await?;

    // 启用 SQLCipher 加密（主密码开启时）
    if let Some(key) = db_key {
        // 转义单引号： passphrase 中的 ' 替换为 ''
        let escaped = key.replace('\'', "''");
        sqlx::query(&format!("PRAGMA key = '{}'", escaped))
            .execute(&pool)
            .await?;
    }

    // 强制外键约束
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&pool)
        .await?;

    // 运行迁移（嵌入 src/db/migrations/ 目录的 .sql 文件）
    sqlx::migrate!("./src/db/migrations").run(&pool).await?;

    Ok(pool)
}

/// 初始化明文（无加密）数据库连接池
pub async fn init_pool_unencrypted(db_path: &Path) -> CoreResult<SqlitePool> {
    init_pool(db_path, None).await
}
