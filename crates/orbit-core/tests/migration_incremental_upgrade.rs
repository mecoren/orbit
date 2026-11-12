//! 迁移守护：基线 schema 回归 + 增量口径（追加 NNNN 不伤老用户）。
//!
//! 约定见 03 文档 §二：0001 冻结，新增结构走 NNNN_xxx.sql（加列带 DEFAULT）。
//! 2026-10-27 起 0002-0012、2026-11-12 起 0002_task_start_sort_index 均已
//! 全量并回 0001（均为未随任何 release 发布的增量），故现行基线本身就是完整
//! schema；本文件逐列/逐索引回归这些结构，并用「模拟未来增量」用例守住
//! ALTER 加列不丢老行 / 默认值回填的口径。

use orbit_core::crypto::sha256_hex;
use sqlx::SqlitePool;

/// 0001 基线冻结护栏：首发前一次性定型
///
/// 「未发布的多文件可并回 0001」只在零存量用户窗口成立；发布后任何一次改写
/// （哪怕只改注释）都会让老库 `_sqlx_migrations` 的 version 1 校验和对不上，
/// 启动即 VersionMismatch（现由 `init_pool` 给出备份/恢复指引）。本用例把基线
/// 字节的 SHA-256 锁成常量：动基线必须显式改这里，让 review 看得见；新增结构
/// 一律追加 NNNN_xxx.sql。更新常量的唯一合法时机是首发前的基线定型，之后永不改。
/// 2026-11-12 更新即属该窗口：未随任何 release 发布的 0002_task_start_sort_index
/// 并回基线（单文件基线重新定型），常量随之重算。
///
/// **常量按 LF 字节定型**：Windows 开发机 `core.autocrlf=true` 会让 `include_str!`
/// 读到 CRLF 版本（同为 0001 内容，只差 868 个行尾），若直接对读到字节哈希，本地绿、
/// Linux CI 必红（2026-11-12 CI 即此形态）。故比较前先归一 `\r\n` → `\n`，两端同一值。
#[test]
fn baseline_migration_checksum_is_frozen() {
    const FROZEN_SHA256: &str =
        "0b548297308b1727329f20077667d3764bb44e81f3caa5230401d8694c6c1e0c";
    let sql = include_str!("../src/db/migrations/0001_init.sql");
    let normalized = sql.replace("\r\n", "\n");
    assert_eq!(
        sha256_hex(normalized.as_bytes()),
        FROZEN_SHA256,
        "0001_init.sql 是冻结基线：结构变更请追加 NNNN_xxx.sql，不要改本文件"
    );
}

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

    // 迁移目录里每个文件都应被记录且成功（单文件基线时即为 1 条）
    let (applied,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM _sqlx_migrations WHERE success = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        applied as usize,
        files.len(),
        "迁移目录每个文件都应有成功的 _sqlx_migrations 记录"
    );
}

/// 基线 schema：todo_reminders.is_constant 带 DEFAULT，未写该列的行回填 0（一次性）
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

/// 基线 schema：todo_projects.parent_uuid 带 DEFAULT NULL，未写该列的项目行回落顶层
/// （父引用用同步主键 uuid 而非 parent_id：自引用外键会破坏云同步「父行先落库」定序）
#[tokio::test]
async fn project_parent_uuid_backfills_null() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    // 不写 parent_uuid 的老写法（增量前口径）：靠 DEFAULT 落地
    sqlx::query(
        "INSERT INTO todo_projects (uuid, title, sort_order, created_at, updated_at)
         VALUES ('u-p1', '老清单', 0, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();

    let (parent,): (Option<String>,) =
        sqlx::query_as("SELECT parent_uuid FROM todo_projects WHERE uuid='u-p1'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(
        parent.is_none(),
        "存量清单行应回填 NULL（顶层），层级语义零变化"
    );

    // 新行可写父引用（自引用同表列），顶层行与子行共存不互相约束
    sqlx::query(
        "INSERT INTO todo_projects (uuid, title, sort_order, created_at, updated_at, parent_uuid)
         VALUES ('u-p2', '子清单', 1, 1, 1, 'u-p1')",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (child_parent,): (Option<String>,) =
        sqlx::query_as("SELECT parent_uuid FROM todo_projects WHERE uuid='u-p2'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(child_parent.as_deref(), Some("u-p1"));
}

/// 基线 schema：todo_subtasks.parent_uuid 带 DEFAULT NULL，未写该列的子任务行回落顶层
/// （父引用用同步主键 uuid 而非 parent_id：自引用外键会破坏云同步「父行先落库」定序）
#[tokio::test]
async fn subtask_parent_uuid_backfills_null() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    // 老版本行（无 parent_uuid 时写入）：靠 DEFAULT 落地
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at)
         VALUES ('u-t1', '任务', 'pending', 0, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO todo_subtasks (uuid, task_id, title, created_at, updated_at)
         VALUES ('u-s1', 1, '老顶层子任务', 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();

    let (parent,): (Option<String>,) =
        sqlx::query_as("SELECT parent_uuid FROM todo_subtasks WHERE uuid='u-s1'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(
        parent.is_none(),
        "存量子任务行应回填 NULL（顶层），层级语义零变化"
    );

    // 新行可写父引用（同任务内嵌套），顶层行与子行共存不互相约束
    sqlx::query(
        "INSERT INTO todo_subtasks (uuid, task_id, title, parent_uuid, created_at, updated_at)
         VALUES ('u-s2', 1, '嵌套子任务', 'u-s1', 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (child_parent,): (Option<String>,) =
        sqlx::query_as("SELECT parent_uuid FROM todo_subtasks WHERE uuid='u-s2'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(child_parent.as_deref(), Some("u-s1"));
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

/// 基线 schema：todo_tasks.duration_minutes 带 DEFAULT NULL，未写该列的任务行未设置时长
/// （可空而非 NOT NULL DEFAULT 0：同步 merge 对老设备载荷缺失字段绑 NULL，NULL=未设置
/// 与「清空时长」语义一致）
#[tokio::test]
async fn task_duration_minutes_backfills_null() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    // 不写 duration_minutes 的老写法（增量前口径）：靠 DEFAULT 落地
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at)
         VALUES ('u-d1', '老任务', 'pending', 0, 1, 1)",
    )
    .execute(&pool)
    .await
    .unwrap();

    let (duration,): (Option<i64>,) =
        sqlx::query_as("SELECT duration_minutes FROM todo_tasks WHERE uuid='u-d1'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(
        duration.is_none(),
        "存量任务行应回填 NULL（未设置），语义零变化"
    );

    // 新行可写时长，与未设置行共存
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, position, created_at, updated_at, duration_minutes)
         VALUES ('u-d2', '新任务', 'pending', 1, 1, 1, 90)",
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

/// 基线 schema：开始时间档键集分页索引已并入 0001（原未发布 0002 增量）
#[tokio::test]
async fn task_start_keyset_index_in_baseline() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    let (count,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_todo_tasks_keyset_start'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1, "开始时间档键集分页索引应在 0001 基线内建好");
}
