//! search_pinyin — 拼音/首字母派生索引（F5，docs/13 §五 F5，docs/07 #101）
//!
//! 「gzs → 工作总结」级别的中文检索：为 todo_tasks.title / todo_projects.title /
//! todo_comments.content 维护 `search_pinyin` 派生表（全拼 + 首字母，无声调
//! 小写；非汉字原样保留可直命中）。表**不进同步白名单/备份清单**——可随时
//! 整表重建的索引，不是业务数据。
//!
//! ## 写入双通道（正确性设计）
//! 1. **实时维护**：generic_repo 的三表 create/update/软删、trash restore，
//!    以及绕过 generic_repo 的裸 INSERT（子任务转出 / 重复任务下次实例 /
//!    复制任务）在写库成功后调 [sync_row] / [remove_row]（单行重建微秒级）；
//! 2. **置脏 + 按需对账**：同步合并、全量备份恢复、批量导入、冲突副本恢复等
//!    **直写路径**在提交后调 [mark_dirty]；查询入口 [ensure_fresh] 先读哨兵行
//!    （O(1)），仅在脏时跑 [reconcile]（补缺失 / 清幽灵 / 按 title 不一致重建）。
//!
//! ## 为什么不「每查必对账」（2026-10-25，docs/07 #104）
//! 50k 行实测：对账 6 次全表扫描 ≈316ms，把纯字母查询 p95 拖到 374ms（P1 验收
//! 线 150ms）；而检索本身只要 11ms。故对账降级为**事件驱动**，代价是新增直写
//! 路径必须显式置脏——判据：**凡直接写 todo_tasks/todo_projects/todo_comments
//! 的 title/content 且不经 generic_repo 钩子，提交后一律 [mark_dirty]（或直接
//! [sync_row] 精确补行）**。[ensure_fresh] 的脏判定见 `search_pinyin_state`。
//!
//! ## 多音字口径
//! 取 pinyin crate 的首选音（如「银行」只收 yin）。行文本变更时整行重建；
//! heteronym 多音展开留待真实检索缺口出现再评估（spike 与本实现同口径）。

use pinyin::ToPinyin;
use sqlx::SqlitePool;

use crate::db::clock;
use crate::error::CoreResult;

/// 索引来源种类（与源表一一对应）
pub const KIND_TASK: &str = "task";
pub const KIND_PROJECT: &str = "project";
pub const KIND_COMMENT: &str = "comment";

/// 进拼音索引面的源表名（直写路径置脏判定用）
pub const INDEXED_TABLES: [&str; 3] = ["todo_tasks", "todo_projects", "todo_comments"];

/// 源表是否进拼音索引面
pub fn is_indexed_table(table: &str) -> bool {
    INDEXED_TABLES.contains(&table)
}

/// 拼音索引纯函数：文本 → (全拼串, 首字母串)。
///
/// 汉字转无声调小写拼音，非汉字原样保留（ASCII/数字可直命中）；全拼与
/// 首字母逐字符对应（等长字符序）。多音字取首选音。
pub fn pinyin_index_text(text: &str) -> (String, String) {
    let mut full = String::with_capacity(text.len() * 6);
    let mut initials = String::with_capacity(text.len());
    for (orig, p) in text.chars().zip(text.to_pinyin()) {
        match p {
            Some(p) => {
                full.push_str(p.plain());
                initials.push(p.plain().chars().next().unwrap_or(' '));
            }
            None => {
                full.push(orig);
                initials.push(orig);
            }
        }
    }
    (full.to_lowercase(), initials.to_lowercase())
}

/// 查询词是否可走拼音通道：全 ASCII 字母（含大小写；数字/中文交由原通道）
pub fn is_pinyin_query(kw: &str) -> bool {
    !kw.is_empty() && kw.chars().all(|c| c.is_ascii_alphabetic())
}

/// UPSERT 单行索引（源表写路径实时维护入口）。
///
/// `text` 为被索引文本（task/project 的 title、comment 的 content）；
/// 文本为空白时等价于移除（空串索引无检索意义）。
pub async fn sync_row(pool: &SqlitePool, kind: &str, uuid: &str, text: &str) -> CoreResult<()> {
    if text.trim().is_empty() {
        return remove_row(pool, uuid).await;
    }
    let (full, initials) = pinyin_index_text(text);
    sqlx::query(
        "INSERT INTO search_pinyin (uuid, kind, title, pinyin_full, initials, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?) \
         ON CONFLICT(uuid) DO UPDATE SET kind = excluded.kind, title = excluded.title, \
           pinyin_full = excluded.pinyin_full, initials = excluded.initials, \
           updated_at = excluded.updated_at",
    )
    .bind(uuid)
    .bind(kind)
    .bind(text)
    .bind(&full)
    .bind(&initials)
    .bind(clock::next_ms())
    .execute(pool)
    .await?;
    Ok(())
}

/// 移除单行索引（软删/清空文本；uuid 不存在时静默幂等）
pub async fn remove_row(pool: &SqlitePool, uuid: &str) -> CoreResult<()> {
    sqlx::query("DELETE FROM search_pinyin WHERE uuid = ?")
        .bind(uuid)
        .execute(pool)
        .await?;
    Ok(())
}

/// 拼音通道命中：按 kind 返回命中的源行 uuid 列表（上限 limit）。
///
/// 匹配语义（与 spike 同口径）：首字母前缀命中（gzs → 工作总结）或全拼子串
/// 命中（gongzuo → 工作…）。线性 LIKE 扫描 10k 行 < 1ms，无需倒排。
pub async fn search_hits(
    pool: &SqlitePool,
    kind: &str,
    query: &str,
    limit: i32,
) -> CoreResult<Vec<String>> {
    let initials_prefix = format!("{}%", query);
    let full_infix = format!("%{}%", query);
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT uuid FROM search_pinyin \
         WHERE kind = ? AND (initials LIKE ? OR pinyin_full LIKE ?) LIMIT ?",
    )
    .bind(kind)
    .bind(&initials_prefix)
    .bind(&full_infix)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(u,)| u).collect())
}

/// 置脏：直写路径提交后调用，下次拼音查询入口做一次全量对账。
///
/// 适用：云同步合并、全量备份恢复、批量导入、冲突副本恢复等**绕过
/// generic_repo 钩子**的写路径。成本为单行 UPSERT（µs 级），把对账的
/// 全表扫描从「每次查询」挪到「每次直写之后的一次查询」。
pub async fn mark_dirty(pool: &SqlitePool) -> CoreResult<()> {
    sqlx::query(
        "INSERT INTO search_pinyin_state (id, dirty, gen, reconciled_at) VALUES (1, 1, 1, 0) \
         ON CONFLICT(id) DO UPDATE SET dirty = 1, gen = search_pinyin_state.gen + 1",
    )
    .execute(pool)
    .await?;
    Ok(())
}

/// 查询入口保鲜：索引新鲜时零成本返回，脏时对账一次并清零。
///
/// 清零带 `gen` 乐观锁——对账期间若有新的直写置脏（gen 已推进），本次不清零，
/// 下一查再对账一遍。语义上「宁多对账一次，不少对账」。
pub async fn ensure_fresh(pool: &SqlitePool) -> CoreResult<()> {
    let state: Option<(i64, i64)> =
        sqlx::query_as("SELECT dirty, gen FROM search_pinyin_state WHERE id = 1")
            .fetch_optional(pool)
            .await?;

    let Some((dirty, generation)) = state else {
        // 哨兵行缺失（迁移前老库被外部工具改写等）：补对账 + 补行，避免永久失鲜
        reconcile(pool).await?;
        sqlx::query(
            "INSERT INTO search_pinyin_state (id, dirty, gen, reconciled_at) VALUES (1, 0, 1, ?) \
             ON CONFLICT(id) DO UPDATE SET dirty = 0, reconciled_at = excluded.reconciled_at",
        )
        .bind(clock::next_ms())
        .execute(pool)
        .await?;
        return Ok(());
    };

    if dirty == 0 {
        return Ok(());
    }
    reconcile(pool).await?;
    sqlx::query(
        "UPDATE search_pinyin_state SET dirty = 0, reconciled_at = ? WHERE id = 1 AND gen = ?",
    )
    .bind(clock::next_ms())
    .bind(generation)
    .execute(pool)
    .await?;
    Ok(())
}

/// 幂等对账：三表与索引全量校准，返回 (重建行数, 移除行数)。
///
/// ① 清幽灵：源行已软删/不存在的索引行删除；
/// ② 补缺失 + 更新不一致：源表活跃行在索引缺失或 title 不一致的重建
/// （title 相等即跳过——拼音由 title 确定性导出，无需比较拼音串）。
/// 直写路径的兜底：只在 [ensure_fresh] 认定脏（或哨兵行缺失）时调用——
/// 50k 行下 6 次全表扫描 ≈316ms，不能挂在每次查询上（docs/07 #104）。
///
/// 重建走**单事务批量**：存量库首次对账可达万行级，逐行自动事务的 per-row
/// fsync 会把首次拼音查询拖到秒级（探针 global-search 实测 7.8s）；WAL 下
/// 单事务一次提交，万行 < 500ms。
pub async fn reconcile(pool: &SqlitePool) -> CoreResult<(usize, usize)> {
    // ① 清幽灵（三类各一条；NOT IN 子查询走各表 uuid 索引）
    let mut removed = 0usize;
    for (kind, table) in [
        (KIND_TASK, "todo_tasks"),
        (KIND_PROJECT, "todo_projects"),
        (KIND_COMMENT, "todo_comments"),
    ] {
        let sql = format!(
            "DELETE FROM search_pinyin WHERE kind = '{kind}' AND uuid NOT IN \
             (SELECT uuid FROM {table} WHERE is_deleted = 0)"
        );
        let r = sqlx::query(&sql).execute(pool).await?;
        removed += r.rows_affected() as usize;
    }

    // ② 补缺失 / 更新不一致（三类各一条；title 相等跳过）。
    // 重建走**单事务批量**：存量库首次对账可达万行级，逐行自动事务的 per-row
    // fsync 会把首次拼音查询拖到秒级（探针 global-search 实测 7.8s）；WAL 下
    // 单事务一次提交，万行 < 500ms。
    let mut rebuilt = 0usize;
    for (kind, table, column) in [
        (KIND_TASK, "todo_tasks", "title"),
        (KIND_PROJECT, "todo_projects", "title"),
        (KIND_COMMENT, "todo_comments", "content"),
    ] {
        let sql = format!(
            "SELECT t.uuid, t.{column} FROM {table} t \
             LEFT JOIN search_pinyin s ON s.kind = '{kind}' AND s.uuid = t.uuid \
             WHERE t.is_deleted = 0 AND (s.uuid IS NULL OR s.title != t.{column})"
        );
        let stale: Vec<(String, String)> = sqlx::query_as(&sql).fetch_all(pool).await?;
        if stale.is_empty() {
            continue;
        }
        let mut tx = pool.begin().await?;
        for (uuid, text) in &stale {
            if text.trim().is_empty() {
                continue;
            }
            let (full, initials) = pinyin_index_text(text);
            sqlx::query(
                "INSERT INTO search_pinyin (uuid, kind, title, pinyin_full, initials, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(uuid) DO UPDATE SET kind = excluded.kind, title = excluded.title, \
                   pinyin_full = excluded.pinyin_full, initials = excluded.initials, \
                   updated_at = excluded.updated_at",
            )
            .bind(uuid)
            .bind(kind)
            .bind(text)
            .bind(&full)
            .bind(&initials)
            .bind(clock::next_ms())
            .execute(&mut *tx)
            .await?;
            rebuilt += 1;
        }
        tx.commit().await?;
    }
    Ok((rebuilt, removed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chinese_to_full_and_initials() {
        let (full, initials) = pinyin_index_text("工作总结");
        assert_eq!(full, "gongzuozongjie");
        assert_eq!(initials, "gzzj");
    }

    #[test]
    fn mixed_text_keeps_non_han_verbatim() {
        // 非汉字原样保留（ASCII 直命中），汉字转拼音
        let (full, initials) = pinyin_index_text("V2 发布会");
        assert_eq!(full, "v2 fabuhui");
        assert_eq!(initials, "v2 fbh");
    }

    #[test]
    fn uppercase_and_spaces_lowercased() {
        let (full, _) = pinyin_index_text("OKR 复盘");
        assert_eq!(full, "okr fupan");
    }

    #[test]
    fn pinyin_query_gate() {
        assert!(is_pinyin_query("gzs"));
        assert!(is_pinyin_query("GZ"));
        assert!(!is_pinyin_query("工作"));
        assert!(!is_pinyin_query("gz2"));
        assert!(!is_pinyin_query(""));
    }

    #[test]
    fn polyphonic_takes_first_reading() {
        // 多音字取首选音（「银行」→ yin；hang 属 heteronym 扩展范围）
        let (full, _) = pinyin_index_text("银行");
        assert!(full.starts_with("yin"));
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use crate::api::business_api::{
        create_todo_comment, create_todo_project, create_todo_task, delete_todo_comment,
        delete_todo_project, delete_todo_task, get_todo_task_by_uuid, search_all,
    };
    use crate::db::repository::generic_repo::soft_delete_by_id;
    use crate::models::business::{
        TodoCommentCreateInput, TodoProjectCreateInput, TodoTaskCreateInput,
    };

    async fn setup_db() -> SqlitePool {
        // max_connections(1)：:memory: 每连接独立库，reconcile 的多语句对账
        // 必须落在同一连接（既有测试先写后读单连接复用侥幸成立，本模块的
        // 跨语句对账必须显式钉死）
        let opts = sqlx::sqlite::SqliteConnectOptions::new()
            .in_memory(true)
            .foreign_keys(true);
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 空 patch（全部缺键 = 不改）：UpdateInput 无 Default derive，
    /// 经 serde 反序列化空对象最短（三态字段全部落「不改」）
    fn empty_task_update() -> crate::models::business::TodoTaskUpdateInput {
        serde_json::from_str("{}").unwrap()
    }

    #[tokio::test]
    async fn create_and_update_maintain_index_via_generic_repo_hooks() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "工作总结".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        // 创建即入索引（写路径钩子）
        let hits = search_hits(&pool, KIND_TASK, "gzzj", 20).await.unwrap();
        assert_eq!(hits, vec![t.uuid.clone()], "首字母 gzzj 命中新建行");

        // 标题变更 → 索引随行重建
        crate::api::business_api::update_todo_task(
            &pool,
            t.id,
            &crate::models::business::TodoTaskUpdateInput {
                title: Some("周会复盘".into()),
                ..empty_task_update()
            },
        )
        .await
        .unwrap();
        assert!(
            search_hits(&pool, KIND_TASK, "gzzj", 20)
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            search_hits(&pool, KIND_TASK, "zhfp", 20).await.unwrap(),
            vec![t.uuid]
        );
    }

    #[tokio::test]
    async fn soft_delete_removes_index_and_reconcile_covers_direct_writes() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "工作项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap();
        assert_eq!(
            search_hits(&pool, KIND_PROJECT, "gzxm", 20)
                .await
                .unwrap()
                .len(),
            1
        );

        // 软删 → 索引即时移除（无幽灵命中）
        delete_todo_project(&pool, p.id).await.unwrap();
        assert!(
            search_hits(&pool, KIND_PROJECT, "gzxm", 20)
                .await
                .unwrap()
                .is_empty()
        );

        // 直写路径（模拟同步合并：绕过 api 层直接 INSERT）→ 查询入口 reconcile 兜底
        sqlx::query("INSERT INTO todo_tasks (uuid, title, is_deleted, done, created_at, updated_at, version) VALUES ('sync-row-1', '简历优化', 0, 0, 1, 1, 1)")
            .execute(&pool)
            .await
            .unwrap();
        assert!(
            search_hits(&pool, KIND_TASK, "jlyh", 20)
                .await
                .unwrap()
                .is_empty()
        );
        let (rebuilt, _) = reconcile(&pool).await.unwrap();
        assert!(rebuilt >= 1, "直写行 + 种子行（首次对账）: {rebuilt}");
        assert_eq!(
            search_hits(&pool, KIND_TASK, "jlyh", 20)
                .await
                .unwrap()
                .len(),
            1
        );

        // 幂等：再次对账零改动
        let (rebuilt, removed) = reconcile(&pool).await.unwrap();
        assert_eq!((rebuilt, removed), (0, 0));
    }

    #[tokio::test]
    async fn title_mismatch_is_rebuilt_by_reconcile() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "旧标题".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        // 模拟索引与源行不一致（外部改写 search_pinyin.title）
        sqlx::query("UPDATE search_pinyin SET title = '漂移的标题' WHERE uuid = ?")
            .bind(&t.uuid)
            .execute(&pool)
            .await
            .unwrap();
        let all: Vec<(String, String, String)> =
            sqlx::query_as("SELECT kind, uuid, title FROM search_pinyin")
                .fetch_all(&pool)
                .await
                .unwrap();
        let (rebuilt, _) = reconcile(&pool).await.unwrap();
        // migrate! 种了「收件箱」默认项目（首次对账一并补索引）+ 本用例漂移行
        assert!(
            rebuilt >= 2,
            "title 不一致按源表重建（含种子行）: {rebuilt}"
        );
        let row: (String,) = sqlx::query_as("SELECT title FROM search_pinyin WHERE uuid = ?")
            .bind(&t.uuid)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(row.0, "旧标题");
    }

    #[tokio::test]
    async fn search_all_merges_pinyin_hits_after_primary() {
        let pool = setup_db().await;
        // 中文精确命中走主路径；拼音命中经合并通道进入结果
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "工作总结".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "周会复盘".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "工作项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap();

        // 全拼 gongzuo 子串命中「工作总结/工作项目」；主路径中文通道零命中
        let r = search_all(&pool, "gongzuo", 20).await.unwrap();
        assert!(r.tasks.iter().any(|t| t.title == "工作总结"));
        assert!(r.projects.iter().any(|p| p.title == "工作项目"));

        // 首字母 gzzj 命中工作总结；zhhfp 命中周会复盘（2 字母 gz 也在列）
        let r = search_all(&pool, "gzzj", 20).await.unwrap();
        assert_eq!(r.tasks.len(), 1);
        assert_eq!(r.tasks[0].title, "工作总结");
        let r = search_all(&pool, "zhfp", 20).await.unwrap();
        assert!(r.tasks.iter().any(|t| t.title == "周会复盘"));

        // 中文查询不触发拼音通道（行为不变）
        let r = search_all(&pool, "工作", 20).await.unwrap();
        assert!(r.projects.iter().any(|p| p.title == "工作项目"));
    }

    #[tokio::test]
    async fn comment_index_lifecycle() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "宿主任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let c = create_todo_comment(
            &pool,
            &TodoCommentCreateInput {
                task_id: t.id,
                content: "评审意见".into(),
            },
        )
        .await
        .unwrap();
        assert_eq!(
            search_hits(&pool, KIND_COMMENT, "psyj", 20)
                .await
                .unwrap()
                .len(),
            1
        );
        delete_todo_comment(&pool, c.id).await.unwrap();
        assert!(
            search_hits(&pool, KIND_COMMENT, "psyj", 20)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn empty_title_text_removes_index_row() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "待清空".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        sync_row(&pool, KIND_TASK, &t.uuid, "  ").await.unwrap();
        let n: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM search_pinyin WHERE uuid = ?")
            .bind(&t.uuid)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(n.0, 0, "空白文本 = 移除索引");
    }

    /// 软删行恢复（回收站 restore）后索引重建——幽灵与漏命中都不出现
    #[tokio::test]
    async fn restore_reindexes_via_reconcile_and_direct_hook() {
        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "会恢复的任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        delete_todo_task(&pool, t.id).await.unwrap();
        assert!(
            search_hits(&pool, KIND_TASK, "hhfdrw", 20)
                .await
                .unwrap()
                .is_empty()
        );

        // 恢复：直改 is_deleted（trash restore 的等价路径）+ reconcile 兜底
        sqlx::query("UPDATE todo_tasks SET is_deleted = 0 WHERE id = ?")
            .bind(t.id)
            .execute(&pool)
            .await
            .unwrap();
        assert!(
            search_hits(&pool, KIND_TASK, "hhfdrw", 20)
                .await
                .unwrap()
                .is_empty(),
            "恢复后若未挂钩，reconcile 前无命中"
        );
        reconcile(&pool).await.unwrap();
        assert_eq!(
            search_hits(&pool, KIND_TASK, "hhfdrw", 20)
                .await
                .unwrap()
                .len(),
            1
        );
        let _ = get_todo_task_by_uuid(&pool, &t.uuid)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn soft_delete_by_id_generic_hook_covers_all_three_kinds() {
        let pool = setup_db().await;
        let p = create_todo_project(
            &pool,
            &TodoProjectCreateInput {
                title: "泛型软删项目".into(),
                description: None,
                hex_color: None,
                sort_order: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap();
        soft_delete_by_id(&pool, "todo_projects", p.id, &p.uuid)
            .await
            .unwrap();
        assert!(
            search_hits(&pool, KIND_PROJECT, "hxrsxm", 20)
                .await
                .unwrap()
                .is_empty(),
            "泛型 soft_delete_by_id 路径也必须移除索引"
        );
    }

    /// 哨兵行读值（(dirty, gen)）
    async fn state_row(pool: &SqlitePool) -> (i64, i64) {
        sqlx::query_as("SELECT dirty, gen FROM search_pinyin_state WHERE id = 1")
            .fetch_one(pool)
            .await
            .unwrap()
    }

    /// 查询入口的对账是**事件驱动**的（docs/07 #104）：
    /// 索引干净时走 O(1) 快路径，直写行必须显式置脏才会被下一次查询收进来。
    #[tokio::test]
    async fn direct_write_needs_mark_dirty_then_next_query_covers_it() {
        let pool = setup_db().await;

        // 迁移种子 dirty = 1 → 首次拼音查询对账一次后清零
        assert!(
            search_all(&pool, "gzzj", 20)
                .await
                .unwrap()
                .tasks
                .is_empty()
        );
        assert_eq!(state_row(&pool).await.0, 0, "对账完成后哨兵行清零");

        // 直写（模拟同步合并/导入）但不置脏：查询只读哨兵行，索引保持不新鲜
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, is_deleted, done, created_at, updated_at, version) \
             VALUES ('direct-1', '工作总结', 0, 0, 1, 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        assert!(
            search_all(&pool, "gzzj", 20)
                .await
                .unwrap()
                .tasks
                .is_empty(),
            "未置脏 → 不跑对账（这是 50k 搜索达标的代价，直写路径必须自行置脏）"
        );

        // 置脏 → 下一次查询对账补齐，且对账后哨兵行再次清零
        mark_dirty(&pool).await.unwrap();
        assert_eq!(state_row(&pool).await.0, 1);
        let r = search_all(&pool, "gzzj", 20).await.unwrap();
        assert!(r.tasks.iter().any(|t| t.uuid == "direct-1"));
        assert_eq!(state_row(&pool).await.0, 0);
    }

    /// 置脏代数单调递增；对账清零只在「代数未被推进」时生效（乐观锁）
    #[tokio::test]
    async fn mark_dirty_bumps_gen_and_clear_is_optimistic() {
        let pool = setup_db().await;
        let (_, gen0) = state_row(&pool).await;

        mark_dirty(&pool).await.unwrap();
        mark_dirty(&pool).await.unwrap();
        let (dirty, gen1) = state_row(&pool).await;
        assert_eq!(dirty, 1);
        assert_eq!(gen1, gen0 + 2, "每次置脏推进一代");

        ensure_fresh(&pool).await.unwrap();
        let (dirty, gen2) = state_row(&pool).await;
        assert_eq!((dirty, gen2), (0, gen1), "对账完成只清 dirty，不动代数");

        // 幂等：干净状态下重复调用零改动
        ensure_fresh(&pool).await.unwrap();
        ensure_fresh(&pool).await.unwrap();
        assert_eq!(state_row(&pool).await, (0, gen1));
    }

    /// 三条绕过 generic_repo 的裸 INSERT 路径：提交后立即补索引（无需等对账）
    #[tokio::test]
    async fn raw_insert_paths_index_task_immediately() {
        use crate::api::business_api::create_todo_subtask;
        use crate::api::todo_api::{duplicate_todo_task, promote_todo_subtask};
        use crate::models::business::TodoSubtaskCreateInput;

        let pool = setup_db().await;
        let t = create_todo_task(
            &pool,
            &TodoTaskCreateInput {
                title: "宿主任务".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        // ① 子任务转出为独立任务（promote_todo_subtask 内裸 INSERT）
        let sub = create_todo_subtask(
            &pool,
            &TodoSubtaskCreateInput {
                task_id: t.id,
                title: "会议纪要".into(),
                position: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap();
        let promoted = promote_todo_subtask(&pool, sub.id).await.unwrap();
        assert_eq!(
            search_hits(&pool, KIND_TASK, "hyjy", 20).await.unwrap(),
            vec![promoted.uuid.clone()],
            "转出任务提交后即入索引"
        );

        // ② 复制任务（duplicate_todo_task 内裸 INSERT）
        let dup = duplicate_todo_task(&pool, t.id).await.unwrap();
        let hits = search_hits(&pool, KIND_TASK, "szrw", 20).await.unwrap();
        assert!(hits.contains(&dup.uuid), "复制体提交后即入索引: {hits:?}");
    }
}
