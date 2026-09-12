//! FTS5 运行时能力探针（批 7 前置验证）
//!
//! sqlx 0.8 bundled sqlite 默认编译 FTS5；本探针在内存库建虚表验证
//! 能力可用（含中文 unicode61 分词），FTS 改造据此推进。若此处失败，
//! 说明目标平台 sqlite 未编 FTS5，搜索升级方案需换 external content 表
//! 或 LIKE 路线（探针即守卫）。

#[tokio::test]
async fn fts5_runtime_probe() {
    let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
    let r = sqlx::query("CREATE VIRTUAL TABLE IF NOT EXISTS fts_probe USING fts5(content)")
        .execute(&pool)
        .await;
    assert!(r.is_ok(), "FTS5 未编译进 bundled sqlite：{:?}", r.err());
    sqlx::query("INSERT INTO fts_probe(content) VALUES ('你好世界 hello world')")
        .execute(&pool)
        .await
        .unwrap();
    let hit: (i64,) = sqlx::query_as("SELECT count(*) FROM fts_probe WHERE fts_probe MATCH 'hello'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(hit.0, 1);
    // 关键事实（2026-09-13 python sqlite 3.49 对照诊断）：
    // unicode61 分词器对 CJK 直接丢弃 token——单字「世」也不命中！
    // 中文产品搜索必须走 trigram 分词器（3-gram：≥3 字短语精确命中，
    // <3 字走 LIKE 兜底）。下方 trigram 段即正式能力守卫。
    let zh: (i64,) = sqlx::query_as("SELECT count(*) FROM fts_probe WHERE fts_probe MATCH '世'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(zh.0, 0, "unicode61 竟命中了 CJK——分词器行为与本批认知不符，重审方案");
    // trigram 分词器能力探针（SQLite 3.34+；未编入则此查询报错）
    let tri = sqlx::query(
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tri USING fts5(content, tokenize='trigram')",
    )
    .execute(&pool)
    .await;
    if tri.is_ok() {
        sqlx::query("INSERT INTO fts_tri(content) VALUES ('完成移动端重构方案评审')")
            .execute(&pool)
            .await
            .unwrap();
        let zh2: (i64,) = sqlx::query_as("SELECT count(*) FROM fts_tri WHERE fts_tri MATCH '移动端'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(zh2.0, 1, "trigram 已编入但中文短语未命中");
    }
    // trigram 不可用时探针不算失败（英文 LIKE/FTS 仍可用；中文走 LIKE 路线）
}
