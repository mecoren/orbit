// 临时集成验证：真实网络拉取 2026 年数据并校验落库形状
use orbit_core::api::holiday_api;
use sqlx::sqlite::SqlitePoolOptions;

#[tokio::test]
#[ignore = "真实网络验证（手动跑）"]
async fn real_fetch_2026() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .unwrap();

    // 先用 builtin 预置路径核对查询，再真实拉取替换
    let meta = holiday_api::update_holidays(&pool).await.unwrap();
    assert!(meta.last_update_ms > 0, "成功更新记账");
    let list = holiday_api::list_holidays(&pool).await.unwrap();
    assert!(!list.is_empty(), "拉取后非空");
    assert!(list.iter().all(|h| h.date.starts_with("2026-")), "今年数据");
    let by_date: std::collections::HashMap<_, _> =
        list.iter().map(|h| (h.date.clone(), h)).collect();
    let sf = by_date.get("2026-02-17").expect("初一在缓存");
    assert!(sf.is_holiday);
    let mend = by_date.get("2026-01-04").expect("元旦补班在缓存");
    assert!(!mend.is_holiday);
    let cnt: usize = list.iter().filter(|h| h.is_holiday).count();
    assert!(cnt >= 30, "放假日 >= 30（2026 实际 35+）, got {cnt}");
    // 二次拉取幂等：行数不翻倍
    holiday_api::update_holidays(&pool).await.unwrap();
    let list2 = holiday_api::list_holidays(&pool).await.unwrap();
    assert_eq!(list.len(), list2.len(), "整年替换幂等");
    println!("2026 rows={} holidays={}", list2.len(), cnt);
}
