//! 基线（0001_init.sql，已冻结）schema 回归：end_date 列不存在、
//! my_day_date/holiday 表存在、任务行含 start/due 正常读写。

use sqlx::SqlitePool;

/// 基线迁移后：end_date 列不存在，任务行含 start/due 正常读写
#[tokio::test]
async fn end_date_column_removed_and_rows_survive() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    let (has_end,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM pragma_table_info('todo_tasks') WHERE name='end_date'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(has_end, 0, "end_date 列应不存在（随单文件迁移口径删除）");

    // 0002/0003 并入断言：my_day_date 列 + 节假日缓存两表在单文件 schema 中
    let (has_my_day,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM pragma_table_info('todo_tasks') WHERE name='my_day_date'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(has_my_day, 1, "my_day_date 列应在 0001 表体中");
    let (holiday_tables,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('cfg_holidays','cfg_kv')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(holiday_tables, 2, "cfg_holidays/cfg_kv 两表应在 0001 中");

    // 读写冒烟：新 schema 下插入任务行并读回截止/开始日期
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at, due_date, start_date)
         VALUES ('u1', 't', 'pending', 0, 1, 1, 1000, 2000)",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (due, start): (Option<i64>, Option<i64>) =
        sqlx::query_as("SELECT due_date, start_date FROM todo_tasks WHERE uuid='u1'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(due, Some(1000));
    assert_eq!(start, Some(2000));
}
