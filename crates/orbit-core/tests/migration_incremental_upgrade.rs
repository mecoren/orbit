//! 增量迁移守护：冻结基线 + 追加 NNNN 口径不伤老用户。
//!
//! 约定见 03 文档 §二：0001 永不改，新增结构走 NNNN_xxx.sql（加列带 DEFAULT）。
//! 本文件用“模拟 0002”验证该口径：老行先写 → ALTER 加列 → 老行保留 + 默认值回填。

use sqlx::SqlitePool;

/// 新鲜库只跑基线，schema 版本为 1（新增文件才递增，不凭空 bump）
#[tokio::test]
async fn fresh_db_runs_baseline_only() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    let (v,): (Option<i64>,) =
        sqlx::query_as("SELECT MAX(version) FROM _sqlx_migrations WHERE success = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(v.unwrap_or(0), 1, "当前仅基线 0001，版本应为 1");
}

/// 模拟老用户升级：0001 数据 → 增量加列 → 数据保留 + 默认值生效
#[tokio::test]
async fn incremental_add_column_preserves_rows() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    // 老版本行（无新列时写入）
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at)
         VALUES ('u-old', '老任务', 'pending', 0, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();

    // 模拟未来 0002：加列必须带 DEFAULT，老行自动回填且不丢
    sqlx::query("ALTER TABLE todo_tasks ADD COLUMN due_memo TEXT NOT NULL DEFAULT ''")
        .execute(&pool)
        .await
        .unwrap();

    let (title, memo): (String, String) =
        sqlx::query_as("SELECT title, due_memo FROM todo_tasks WHERE uuid='u-old'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(title, "老任务");
    assert_eq!(memo, "", "老行新列应回填 DEFAULT");

    // 新行可写新列，SELECT * 不坏
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at, due_memo)
         VALUES ('u-new', '新任务', 'pending', 0, 1, 1, 'hi')",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_tasks")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(n, 2);
}
