//! 增量迁移守护：冻结基线 + 追加 NNNN 口径不伤老用户。
//!
//! 约定见 03 文档 §二：0001 永不改，新增结构走 NNNN_xxx.sql（加列带 DEFAULT）。
//! 本文件用“模拟 0002”验证该口径：老行先写 → ALTER 加列 → 老行保留 + 默认值回填。

use sqlx::SqlitePool;

/// 新鲜库跑全链：schema 版本 == 迁移目录里的最大编号文件
/// （断言由目录推导，新增 NNNN_xxx.sql 时无需手改本测试——只增文件不改断言）
#[tokio::test]
async fn fresh_db_runs_all_migrations() {
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

    let mut files: Vec<i64> = std::fs::read_dir("./src/db/migrations")
        .unwrap()
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            let stem = name.strip_suffix(".sql")?.to_string();
            stem.split('_').next()?.parse::<i64>().ok()
        })
        .collect();
    files.sort_unstable();
    let expected = *files.last().expect("迁移目录不应为空");
    assert_eq!(
        v.unwrap_or(0),
        expected,
        "schema 版本应等于最大编号迁移文件（0001 基线 + 后续增量）"
    );
    assert!(
        files.len() >= 2,
        "0002_reminder_constant.sql 起增量文件应独立成文件（并回 0001 会让存量库 VersionMismatch）"
    );
}

/// 0002 增量落地：todo_reminders.is_constant 带 DEFAULT，老行回填 0（一次性）
#[tokio::test]
async fn reminder_constant_column_backfills_zero() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at)
         VALUES ('u-t1', '吃药', 'pending', 0, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();
    // 不写 is_constant 的老写法（增量前口径）：靠 DEFAULT 落地
    sqlx::query(
        "INSERT INTO todo_reminders (uuid, task_id, remind_at, created_at, updated_at)
         VALUES ('u-r1', 1, 1000, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();

    let (constant,): (i64,) =
        sqlx::query_as("SELECT is_constant FROM todo_reminders WHERE uuid='u-r1'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(constant, 0, "存量提醒行应回填 0（一次性），语义零变化");
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
