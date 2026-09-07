//! 0004_remove_end_date 迁移回归：end_date 列已删、任务行读写正常。

use sqlx::SqlitePool;

/// 全量迁移（0001→0004）后：end_date 列不存在，任务行含 start/due 正常读写
#[tokio::test]
async fn end_date_column_removed_and_rows_survive() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations").run(&pool).await.unwrap();

    let (has_end,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM pragma_table_info('todo_tasks') WHERE name='end_date'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(has_end, 0, "end_date 列应已被 0004 迁移删除");

    // 读写冒烟：新 schema 下插入任务行并读回截止/开始日期
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at, due_date, start_date)
         VALUES ('u1', 't', 'pending', 0, 1, 1, 1000, 2000)",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (due, start): (Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT due_date, start_date FROM todo_tasks WHERE uuid='u1'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(due, Some(1000));
    assert_eq!(start, Some(2000));
}
