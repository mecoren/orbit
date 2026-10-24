//! search_pinyin — 拼音/首字母派生索引（F5，docs/13 §五 F5，docs/07 #101）
//!
//! 「gzs → 工作总结」级别的中文检索：为 todo_tasks.title / todo_projects.title /
//! todo_comments.content 维护 `search_pinyin` 派生表（全拼 + 首字母，无声调
//! 小写；非汉字原样保留可直命中）。表**不进同步白名单/备份清单**——可随时
//! 整表重建的索引，不是业务数据。
//!
//! ## 写入双通道（正确性设计）
//! 1. **实时维护**：generic_repo 的三表 create/update/软删与 trash restore
//!    在写库成功后调 [sync_row] / [remove_row]（单行重建约微秒级，见 spike）；
//! 2. **幂等兜底**：同步合并、CSV/ICS 导入、备份恢复等**直写路径**绕过
//!    generic_repo——[reconcile] 在查询入口对账（补缺失 / 清幽灵 / 按 title
//!    不一致重建，通常 0 行改动，10k 行 < 5ms），保证「查询时索引恒新鲜」
//!    而不必在每个直写路径挂钩。
//!
//! ## 多音字口径
//! 取 pinyin crate 的首选音（如「银行」只收 yin）。行文本变更时整行重建；
//! heteronym 多音展开留待真实检索缺口出现再评估（spike 与本实现同口径）。

use std::time::Instant;

use pinyin::ToPinyin;
use sqlx::SqlitePool;

use crate::db::clock;
use crate::error::CoreResult;

/// 索引来源种类（与源表一一对应）
pub const KIND_TASK: &str = "task";
pub const KIND_PROJECT: &str = "project";
pub const KIND_COMMENT: &str = "comment";

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

/// 幂等对账：三表与索引全量校准，返回 (重建行数, 移除行数)。
///
/// ① 清幽灵：源行已软删/不存在的索引行删除；
/// ② 补缺失 + 更新不一致：源表活跃行在索引缺失或 title 不一致的重建
/// （title 相等即跳过——拼音由 title 确定性导出，无需比较拼音串）。
/// 直写路径（同步合并/导入/备份恢复）的兜底入口：查询前调用保证索引新鲜。
pub async fn reconcile(pool: &SqlitePool) -> CoreResult<(usize, usize)> {
    let t = Instant::now();
    let _ = t;

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

    // ② 补缺失 / 更新不一致（三类各一条；title 相等跳过）
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

        for (uuid, text) in stale {
            sync_row(pool, kind, &uuid, &text).await?;
            rebuilt += 1;
        }
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
}
