//! pragma_eval — P5「启动/关闭 `PRAGMA optimize`、导入后 `ANALYZE`」收益评估
//! （docs/13 §七 P5）
//!
//! **不是产品代码**：本地手动跑的评估探针（与 `pinyin_spike` / `operation_probe`
//! 同惯例，不进生产二进制）。P5 的原始问法是「评估收益」，但收益问题里藏着三个
//! 必须分开量的因素，混在一起会得出反向结论（首版探针就踩了：`ANALYZE` 全量扫
//! 一遍 21MB 库恰好把 OS 页缓存灌满，随后所有查询都「变快」，看着像统计的功劳）：
//!
//! 1. **统计 vs 缓存**：计划选择变没变？变了才是统计的功劳，没变而查询变快，
//!    那是 `ANALYZE` 顺带做了全库预热的功劳（预热是副作用，不是收益）。
//!    → 场景 A 在同一个库、同一个池上依次量「无统计冷」「无统计热」「全量统计」
//!    「采样统计」，并逐态抓真实 SQL 的 `EXPLAIN QUERY PLAN`。
//! 2. **陈旧统计的代价**：真实用户库的统计是「上次维护时的行数」，导入 10 倍
//!    数据后统计还停在旧行数——这时候计划会不会塌？塌了才需要「导入后 ANALYZE」。
//!    → 场景 B：5k 行建统计 → 一次性导入 45k 行（10 倍膨胀）→ 量陈旧统计下的
//!    七条热读路径，再刷新统计量一次，看是否回到正常水位。
//! 3. **该挂哪儿、挂得住吗**：`PRAGMA optimize` 的默认掩码（0xfffe）**不覆盖
//!    「从未分析过」的表**，所以新库首装它什么也不做；而它的「行数漂移」判据是
//!    **连接级**状态——写发生在连接 A、optimize 跑在连接 B 时，B 看不见 A 的写。
//!    连接池下这条最要命，故单独量「同连接」与「异连接」两种 optimize。
//!    → 场景 C。
//!
//! 口径要点：
//! - **同一引擎、同一连接池参数**（`init_pool_unencrypted`：WAL + cache_size 8MB），
//!   不用 Python 复刻——P5 判的是「本仓这套查询在本仓这套引擎上的计划选择」；
//! - 热路径走**真实 API**（`list_todo_tasks` / `business_count` / `stats::aggregate`
//!   / `search_all`）；日历范围查询无独立 API，手写等价 SQL；
//! - 查询计划用**与 `generic_repo::list` 逐字一致**的 SQL 复现（列裁剪、归档项目
//!   排除子句、`ORDER BY updated_at DESC`），否则量的不是同一条语句；
//! - `PRAGMA analysis_limit` 是**连接级**状态，故 ANALYZE / optimize 都钉在同一条
//!   连接上执行，否则池里换连接会让限制悄悄失效；
//! - 每口径 `--samples` 次采样报 p50/p95 毫秒；测量前 `wal_checkpoint(TRUNCATE)`；
//! - 统计有没有真的重写，靠 `sqlite_stat1` 内容摘要（FNV-1a）+ 行数判断，
//!   不看 `PRAGMA optimize` 的返回值（它不返回任何信息）。
//!
//! 用法：
//! ```text
//! cargo run --release -p orbit-core --example pragma_eval -- \
//!   --workdir <dir> --rows 50000 --out <result.json>
//! ```

use std::path::PathBuf;
use std::time::Instant;

use orbit_core::api::{asset_api, business_api, stats_api};
use orbit_core::db::pool::init_pool_unencrypted;
use orbit_core::models::business::ListFilter;
use serde_json::{Map, Value, json};
use sqlx::{Connection, SqliteConnection, SqlitePool};

// ============================================================================
// 参数
// ============================================================================

struct Args {
    workdir: PathBuf,
    out: PathBuf,
    rows: usize,
    samples: usize,
}

fn parse_args() -> Result<Args, String> {
    let mut map = std::collections::HashMap::new();
    let mut iter = std::env::args().skip(1);
    while let Some(key) = iter.next() {
        if !key.starts_with("--") {
            return Err(format!("无法识别的参数：{key}"));
        }
        let value = iter.next().ok_or_else(|| format!("{key} 缺少取值"))?;
        map.insert(key.trim_start_matches("--").to_string(), value);
    }
    let get = |k: &str, default: &str| map.get(k).cloned().unwrap_or_else(|| default.into());
    Ok(Args {
        workdir: PathBuf::from(get("workdir", ".")),
        out: PathBuf::from(get("out", "pragma-eval-result.json")),
        rows: get("rows", "50000")
            .parse()
            .map_err(|e| format!("rows: {e}"))?,
        samples: get("samples", "30")
            .parse()
            .map_err(|e| format!("samples: {e}"))?,
    })
}

// ============================================================================
// 主流程
// ============================================================================

#[tokio::main]
async fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("参数错误：{e}");
            std::process::exit(2);
        }
    };
    match run(&args).await {
        Ok(v) => {
            let text = serde_json::to_string_pretty(&v).expect("序列化结果");
            if let Some(dir) = args.out.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            std::fs::write(&args.out, &text).expect("写入结果文件");
            println!("{text}");
        }
        Err(e) => {
            let v = json!({ "ok": false, "error": e });
            println!("{v}");
            std::process::exit(1);
        }
    }
}

async fn run(args: &Args) -> Result<Value, String> {
    std::fs::create_dir_all(&args.workdir).map_err(|e| e.to_string())?;
    let mut out = Map::new();
    out.insert("ok".into(), json!(true));
    out.insert("rows".into(), json!(args.rows));
    out.insert("samplesPerQuery".into(), json!(args.samples));

    // ========================================================================
    // 场景 A：统计 vs 缓存 vs 连接（六态对照）
    //
    // 这里必须把「统计生效」和「连接重开」分开量：实测发现 sqlx 的连接级语句
    // 缓存会让 ANALYZE 后的新统计只对「重新准备过语句」的连接生效——同一时刻
    // 池里三条连接可能跑两套计划（见 plansPerConn / 原始样本的周期 3 双峰）。
    // 所以每一种统计口径各量两次：不重开池（真实运行态）与重开池（理论收益）。
    // ========================================================================
    let db_a = args.workdir.join("a-stats-vs-cache.db");
    fresh_db_files(&db_a);
    let mut pool_a = init_pool_unencrypted(&db_a)
        .await
        .map_err(|e| e.to_string())?;
    let ver: (String,) = sqlx::query_as("SELECT sqlite_version()")
        .fetch_one(&pool_a)
        .await
        .map_err(|e| e.to_string())?;
    out.insert("sqliteVersion".into(), json!(ver.0));

    let seed_ms = seed_projects_and_tasks(&pool_a, 0, args.rows).await?;
    checkpoint(&pool_a).await?;
    let db_bytes = file_len(&db_a);
    let busiest = busiest_project(&pool_a).await?;
    let mut probe = ProbeSet::new(pool_a.clone(), busiest, args.samples);

    let plans_none = probe.plans().await?;
    let plans_conn_none = probe.plans_per_conn().await?;
    let t_none = probe.measure().await?;
    let raw_none = probe.raw();
    let price_none = probe.price_forced(args.samples).await?;
    let (n_none, digest_none) = stat1_digest(&pool_a).await?;

    // 纯全库扫描（表 + 两个候选索引）——只灌页缓存，不改统计
    let warm_ms = warm_scan(&pool_a).await?;
    let t_none_warm = probe.measure().await?;
    let raw_none_warm = probe.raw();

    // ---- 全量 ANALYZE：先不重开池（真实运行态），再重开（理论收益）----
    let analyze_full_ms = analyze_pinned(&pool_a, 0).await?;
    let plans_conn_full = probe.plans_per_conn().await?;
    // 维护路径的真实顺序是 ANALYZE → VACUUM：看 VACUUM 会不会替所有连接刷新计划
    let vacuum_after_analyze_ms = vacuum_pinned(&pool_a).await?;
    let plans_conn_after_vacuum = probe.plans_per_conn().await?;
    let t_full_noreopen = probe.measure().await?;
    let raw_full_noreopen = probe.raw();
    let (n_full, digest_full) = stat1_digest(&pool_a).await?;
    pool_a.close().await;
    pool_a = init_pool_unencrypted(&db_a)
        .await
        .map_err(|e| e.to_string())?;
    let mut probe = ProbeSet::new(pool_a.clone(), busiest, args.samples);
    let plans_full = probe.plans().await?;
    let plans_conn_full_reopened = probe.plans_per_conn().await?;
    let t_full = probe.measure().await?;
    let raw_full = probe.raw();
    let price_full = probe.price_forced(args.samples).await?;

    // ---- 采样口径覆盖全量统计（analysis_limit=400：SQLite 官方建议值）----
    let analyze_sampled_ms = analyze_pinned(&pool_a, 400).await?;
    let plans_conn_sampled = probe.plans_per_conn().await?;
    let t_sampled_noreopen = probe.measure().await?;
    let raw_sampled_noreopen = probe.raw();
    let (n_sampled, digest_sampled) = stat1_digest(&pool_a).await?;
    pool_a.close().await;
    pool_a = init_pool_unencrypted(&db_a)
        .await
        .map_err(|e| e.to_string())?;
    let mut probe = ProbeSet::new(pool_a.clone(), busiest, args.samples);
    let plans_sampled = probe.plans().await?;
    let t_sampled = probe.measure().await?;
    let raw_sampled = probe.raw();
    let price_sampled = probe.price_forced(args.samples).await?;

    out.insert(
        "scenarioA_statsVsCache".into(),
        json!({
            "seedMs": seed_ms,
            "dbBytes": db_bytes,
            "warmScanMs": warm_ms,
            "install": {
                "analyzeFullMs": analyze_full_ms,
                "analyzeSampledMs": analyze_sampled_ms,
                "vacuumAfterAnalyzeMs": vacuum_after_analyze_ms,
                "stat1RowsNone": n_none,
                "stat1RowsFull": n_full,
                "stat1RowsSampled": n_sampled,
                "stat1DigestNone": format!("{digest_none:016x}"),
                "stat1DigestFull": format!("{digest_full:016x}"),
                "stat1DigestSampled": format!("{digest_sampled:016x}"),
                "dbBytesAfterFullAnalyze": file_len(&db_a),
            },
            "timings": {
                "noStatsCold": t_none,
                "noStatsWarm": t_none_warm,
                "fullAnalyzeNoReopen": t_full_noreopen,
                "fullAnalyzeReopened": t_full,
                "sampledAnalyzeNoReopen": t_sampled_noreopen,
                "sampledAnalyzeReopened": t_sampled,
            },
            "plans": {
                "noStats": plans_none,
                "fullAnalyzeReopened": plans_full,
                "sampledAnalyzeReopened": plans_sampled,
            },
            "plansPerConn": {
                "noStats": plans_conn_none,
                "fullAnalyzeNoReopen": plans_conn_full,
                "fullAnalyzeThenVacuum": plans_conn_after_vacuum,
                "fullAnalyzeReopened": plans_conn_full_reopened,
                "sampledAnalyzeNoReopen": plans_conn_sampled,
            },
            "priceForced": {
                "noStats": price_none,
                "fullAnalyzeReopened": price_full,
                "sampledAnalyzeReopened": price_sampled,
            },
            "rawSamples": {
                "noStatsCold": raw_none,
                "noStatsWarm": raw_none_warm,
                "fullAnalyzeNoReopen": raw_full_noreopen,
                "fullAnalyzeReopened": raw_full,
                "sampledAnalyzeNoReopen": raw_sampled_noreopen,
                "sampledAnalyzeReopened": raw_sampled,
            },
        }),
    );
    pool_a.close().await;

    // ========================================================================
    // 场景 B：陈旧统计（10 倍膨胀导入）与「导入后 ANALYZE」
    // ========================================================================
    let db_b = args.workdir.join("b-stale-after-import.db");
    fresh_db_files(&db_b);
    let pool_b = init_pool_unencrypted(&db_b)
        .await
        .map_err(|e| e.to_string())?;
    let small = (args.rows / 10).max(1000);
    let mut conn_b = pool_b.acquire().await.map_err(|e| e.to_string())?;

    // 5k 行、从未分析过 → 先看 optimize 会不会自己补统计（默认掩码不含 0x1）
    seed_projects_and_tasks(&pool_b, 0, small).await?;
    checkpoint(&pool_b).await?;
    let (n_b0, digest_b0) = stat1_digest(&pool_b).await?;
    let optimize_never_analyzed_ms = optimize_on(&mut conn_b, 400).await?;
    let (n_b1, digest_b1) = stat1_digest(&pool_b).await?;

    let busiest_b = busiest_project(&pool_b).await?;
    let mut probe_b = ProbeSet::new(pool_b.clone(), busiest_b, args.samples);
    let plans_small_nostats = probe_b.plans().await?;
    let t_small_nostats = probe_b.measure().await?;

    // 建一次统计（5k 规模），此后就是「用户上次维护时的口径」
    let analyze_small_ms = analyze_pinned(&pool_b, 0).await?;
    let t_small_stats = probe_b.measure().await?;
    let (n_small, digest_small) = stat1_digest(&pool_b).await?;

    // 一次导入把行数打到 10 倍（同一连接：后续 optimize 才算「同连接」）
    let import_ms = import_more_tasks(&mut conn_b, small, args.rows).await?;
    checkpoint(&pool_b).await?;
    let plans_stale = probe_b.plans().await?;
    let price_stale = probe_b.price_forced(args.samples).await?;
    // 量两轮：「导入后首次查询」与「稳态」必须分开（首查有段合并/预读的额外成本）
    let t_stale = probe_b.measure().await?;
    let t_stale2 = probe_b.measure().await?;
    let (n_stale_before, digest_stale_before) = stat1_digest(&pool_b).await?;

    // 导入后立刻 optimize（同一条写过数据的连接）——它认不认这 10 倍漂移？
    let optimize_after_import_ms = optimize_on(&mut conn_b, 400).await?;
    let (n_stale_after, digest_stale_after) = stat1_digest(&pool_b).await?;
    let t_stale_after_optimize = probe_b.measure().await?;
    let plans_stale_after_optimize = probe_b.plans().await?;

    // 显式全量 ANALYZE 刷新统计（采样口径见场景 A：它买不到正确计划）
    let analyze_after_import_ms = analyze_pinned(&pool_b, 0).await?;
    let t_refreshed_raw = probe_b.measure().await?;
    // 统计变了之后老连接仍可能跑旧计划（场景 A 的 plansPerConn），重开一次再看
    drop(conn_b);
    pool_b.close().await;
    let pool_b = init_pool_unencrypted(&db_b)
        .await
        .map_err(|e| e.to_string())?;
    let mut probe_b = ProbeSet::new(pool_b.clone(), busiest_b, args.samples);
    let t_refreshed = probe_b.measure().await?;
    let plans_refreshed = probe_b.plans().await?;
    let price_refreshed = probe_b.price_forced(args.samples).await?;
    let (n_refreshed, digest_refreshed) = stat1_digest(&pool_b).await?;

    out.insert(
        "scenarioB_staleAfterImport".into(),
        json!({
            "smallRows": small,
            "bigRows": args.rows,
            "importMs": import_ms,
            "install": {
                "optimizeNeverAnalyzedMs": optimize_never_analyzed_ms,
                "stat1RowsNeverAnalyzedBefore": n_b0,
                "stat1RowsNeverAnalyzedAfter": n_b1,
                "stat1DigestNeverAnalyzedBefore": format!("{digest_b0:016x}"),
                "stat1DigestNeverAnalyzedAfter": format!("{digest_b1:016x}"),
                "analyzeSmallMs": analyze_small_ms,
                "stat1RowsSmall": n_small,
                "stat1DigestSmall": format!("{digest_small:016x}"),
                "optimizeAfterImportMs": optimize_after_import_ms,
                "stat1RowsStaleBefore": n_stale_before,
                "stat1RowsStaleAfter": n_stale_after,
                "stat1DigestStaleBefore": format!("{digest_stale_before:016x}"),
                "stat1DigestStaleAfter": format!("{digest_stale_after:016x}"),
                "analyzeAfterImportMs": analyze_after_import_ms,
                "stat1RowsRefreshed": n_refreshed,
                "stat1DigestRefreshed": format!("{digest_refreshed:016x}"),
            },
            "timings": {
                "smallNoStats": t_small_nostats,
                "smallFullStats": t_small_stats,
                "bigStaleStatsFirstQuery": t_stale,
                "bigStaleStatsSteady": t_stale2,
                "bigAfterOptimize": t_stale_after_optimize,
                "bigFullStatsNoReopen": t_refreshed_raw,
                "bigFullStatsReopened": t_refreshed,
            },
            "plans": {
                "smallNoStats": plans_small_nostats,
                "bigStaleStats": plans_stale,
                "bigAfterOptimize": plans_stale_after_optimize,
                "bigRefreshedStats": plans_refreshed,
            },
            "priceForced": {
                "bigStaleStats": price_stale,
                "bigRefreshedStats": price_refreshed,
            },
        }),
    );
    pool_b.close().await;

    // ========================================================================
    // 场景 C：`PRAGMA optimize` 在「统计新鲜」态的成本与连接作用域
    //
    // 写后是否重算统计不在这里测——场景 B 的 10 倍导入已经给出答案
    // （同连接、45k 行新增、optimize 2ms、stat1 摘要一字未变）。
    // 这里只确认两件事：新鲜态它是不是零成本；换连接跑会不会有区别。
    // ========================================================================
    let db_c = args.workdir.join("c-optimize-scope.db");
    fresh_db_files(&db_c);
    let pool_c = init_pool_unencrypted(&db_c)
        .await
        .map_err(|e| e.to_string())?;
    seed_projects_and_tasks(&pool_c, 0, args.rows).await?;
    checkpoint(&pool_c).await?;
    analyze_pinned(&pool_c, 400).await?;

    // 同时占住两条连接 → 保证 c1/c2 不是同一条
    let mut c1 = pool_c.acquire().await.map_err(|e| e.to_string())?;
    let mut c2 = pool_c.acquire().await.map_err(|e| e.to_string())?;

    let (n_c0, digest_c0) = stat1_digest(&pool_c).await?;
    let optimize_fresh_ms = optimize_on(&mut c1, 400).await?;
    let (n_c1, digest_c1) = stat1_digest(&pool_c).await?;
    let optimize_other_conn_ms = optimize_on(&mut c2, 400).await?;
    let (n_c2, digest_c2) = stat1_digest(&pool_c).await?;
    drop(c1);
    drop(c2);

    // 第三次（幂等性）：换一条干净的连接再跑
    let mut c3 = pool_c.acquire().await.map_err(|e| e.to_string())?;
    let optimize_third_ms = optimize_on(&mut c3, 400).await?;
    drop(c3);
    let (n_c3, digest_c3) = stat1_digest(&pool_c).await?;

    out.insert(
        "scenarioC_optimizeScope".into(),
        json!({
            "install": {
                "optimizeFreshSameConnMs": optimize_fresh_ms,
                "optimizeFreshOtherConnMs": optimize_other_conn_ms,
                "optimizeThirdRoundMs": optimize_third_ms,
                "stat1RowsBefore": n_c0,
                "stat1RowsAfterSameConn": n_c1,
                "stat1RowsAfterOtherConn": n_c2,
                "stat1RowsAfterThird": n_c3,
                "stat1DigestBefore": format!("{digest_c0:016x}"),
                "stat1DigestAfterSameConn": format!("{digest_c1:016x}"),
                "stat1DigestAfterOtherConn": format!("{digest_c2:016x}"),
                "stat1DigestAfterThird": format!("{digest_c3:016x}"),
            },
        }),
    );
    pool_c.close().await;

    // ========================================================================
    // 场景 D：维护成本拆解 —— 哪几步该在「启动」做
    //
    // 起因：移动端 boot_gate 每次冷启动都 `unawaited` 跑完整 db_maintenance
    // （WAL checkpoint → 附件 GC → 缓存 LRU → 日志 TTL → 全量 ANALYZE →
    // VACUUM），而桌面只在设置页手动做。VACUUM 的成本与**库体积**成正比、
    // 收益只与**空闲页**成正比，两者不是一回事。
    //
    // 量三件事：
    //   ① 脏库上真函数跑一次 = 第一次启动的真实成本（含 TTL 清掉的页）；
    //   ② 紧接着跑第二次 = 之后每次启动的稳态成本；
    //   ③ 在稳态库上把六步拆开计时 = 每一步各自多少钱，以及 TTL prune 到底
    //      释放了几个页（决定「按判据 VACUUM」能不能省掉整库重写）。
    // ========================================================================
    let db_d = args.workdir.join("d-maintenance-cost.db");
    fresh_db_files(&db_d);
    let pool_d = init_pool_unencrypted(&db_d)
        .await
        .map_err(|e| e.to_string())?;
    seed_projects_and_tasks(&pool_d, 0, args.rows).await?;
    checkpoint(&pool_d).await?;

    let att_dir = args.workdir.join("d-attachments");
    std::fs::create_dir_all(&att_dir).map_err(|e| e.to_string())?;
    let att_dir_str = att_dir.to_string_lossy().to_string();

    let page_size = pragma_of(&pool_d, "page_size").await?;
    let clean_bytes = file_len(&db_d);
    let clean_free = pragma_of(&pool_d, "freelist_count").await?;

    // 造「用了一段时间」的库：编辑/软删（不释放页）+ 清空回收站/TTL 过期日志（释放页）
    let churn = churn_usage(&pool_d).await?;
    checkpoint(&pool_d).await?;
    let dirty_bytes = file_len(&db_d);
    let dirty_free = pragma_of(&pool_d, "freelist_count").await?;

    // ---- ① 第一次启动：真函数在脏库上跑一次 ----
    let t = Instant::now();
    let first = orbit_core::api::db_maintenance_api::db_maintenance(&pool_d, &att_dir_str)
        .await
        .map_err(|e| e.to_string())?;
    let first_boot_ms = t.elapsed().as_millis();
    let bytes_after_first = file_len(&db_d);

    // ---- ② 第二次启动：刚跑完的库再跑一次（稳态）----
    let t = Instant::now();
    let second = orbit_core::api::db_maintenance_api::db_maintenance(&pool_d, &att_dir_str)
        .await
        .map_err(|e| e.to_string())?;
    let second_boot_ms = t.elapsed().as_millis();
    let bytes_after_second = file_len(&db_d);

    // ---- ③ 稳态库上分步计时 ----
    // 顺序与 db_maintenance 内部一致；每步后记 freelist，看谁在释放页、谁在回收页
    let mut steps = Map::new();
    let free_at = |n: i64| json!(n);

    let free_before_steps = pragma_of(&pool_d, "freelist_count").await?;
    steps.insert("freelistAtStepsStart".into(), free_at(free_before_steps));

    let t = Instant::now();
    checkpoint(&pool_d).await?;
    let checkpoint_ms = t.elapsed().as_millis();
    steps.insert("walCheckpointMs".into(), json!(checkpoint_ms));

    let t = Instant::now();
    let cleaned = asset_api::gc_local_attachments(&pool_d, &att_dir_str)
        .await
        .map_err(|e| e.to_string())?;
    let gc_ms = t.elapsed().as_millis();
    steps.insert("attachmentGcMs".into(), json!(gc_ms));
    steps.insert("attachmentGcFiles".into(), json!(cleaned));

    let t = Instant::now();
    asset_api::enforce_attachment_cache_limit(&pool_d, &att_dir_str)
        .await
        .map_err(|e| e.to_string())?;
    let cache_ms = t.elapsed().as_millis();
    steps.insert("attachmentCacheLimitMs".into(), json!(cache_ms));

    let free_before_prune = pragma_of(&pool_d, "freelist_count").await?;
    let t = Instant::now();
    let n_notif = orbit_core::api::notification_log_api::prune_old(&pool_d, 30)
        .await
        .map_err(|e| e.to_string())?;
    let n_act = orbit_core::api::activity_log_api::prune_old(&pool_d, 30)
        .await
        .map_err(|e| e.to_string())?;
    let prune_ms = t.elapsed().as_millis();
    let free_after_prune = pragma_of(&pool_d, "freelist_count").await?;
    steps.insert("logTtlPruneMs".into(), json!(prune_ms));
    steps.insert("logRowsPruned".into(), json!(n_notif + n_act));
    steps.insert("freelistBeforePrune".into(), free_at(free_before_prune));
    steps.insert("freelistAfterPrune".into(), free_at(free_after_prune));

    let t = Instant::now();
    orbit_core::api::db_maintenance_api::analyze_plan_stats(&pool_d)
        .await
        .map_err(|e| e.to_string())?;
    let analyze_ms = t.elapsed().as_millis();
    steps.insert("analyzeMs".into(), json!(analyze_ms));

    let free_before_vacuum = pragma_of(&pool_d, "freelist_count").await?;
    let t = Instant::now();
    sqlx::query("VACUUM")
        .execute(&pool_d)
        .await
        .map_err(|e| e.to_string())?;
    let vacuum_ms = t.elapsed().as_millis();
    let free_after_vacuum = pragma_of(&pool_d, "freelist_count").await?;
    steps.insert("vacuumMs".into(), json!(vacuum_ms));
    steps.insert("freelistBeforeVacuum".into(), free_at(free_before_vacuum));
    steps.insert("freelistAfterVacuum".into(), free_at(free_after_vacuum));

    // 「轻维护」= 除 VACUUM 之外的五步（候选的启动路径）
    let routine_ms = checkpoint_ms + gc_ms + cache_ms + prune_ms + analyze_ms;
    steps.insert("routineTotalMs".into(), json!(routine_ms));
    steps.insert(
        "routineWithoutAnalyzeMs".into(),
        json!(routine_ms - analyze_ms),
    );
    steps.insert(
        // VACUUM 相对「其余五步合计」的倍数（不是占比：占比 = r/(r+1)）
        "vacuumOverRoutineRatio".into(),
        json!(if routine_ms == 0 {
            0.0
        } else {
            vacuum_ms as f64 / routine_ms as f64
        }),
    );

    out.insert(
        "scenarioD_maintenanceCost".into(),
        json!({
            "reclaimableBytesGate": {
                // 判据候选：空闲页 × 页大小 就是「VACUUM 至多能还回多少」
                "pageSize": page_size,
                "cleanFreelistPages": clean_free,
                "dirtyFreelistPages": dirty_free,
                "dirtyReclaimableBytes": dirty_free * page_size,
                "steadyStateFreelistPages": free_before_vacuum,
                "steadyStateReclaimableBytes": free_before_vacuum * page_size,
            },
            "size": {
                "afterSeedBytes": clean_bytes,
                "afterChurnBytes": dirty_bytes,
                "afterFirstMaintenanceBytes": bytes_after_first,
                "afterSecondMaintenanceBytes": bytes_after_second,
            },
            "churn": churn,
            "firstBoot": {
                "totalMs": first_boot_ms,
                "logRowsPruned": first.log_rows_pruned,
                "freelistBefore": first.freelist_before,
                "pagesReclaimed": first.pages_reclaimed,
                "bytesReclaimed": first.pages_reclaimed * page_size,
            },
            "secondBoot": {
                "totalMs": second_boot_ms,
                "logRowsPruned": second.log_rows_pruned,
                "freelistBefore": second.freelist_before,
                "pagesReclaimed": second.pages_reclaimed,
            },
            "steadyStateSteps": steps,
        }),
    );
    // ========================================================================
    // 场景 E：启动争用 —— 维护与首屏列表抢同一套连接/锁
    //
    // 壳层两条路径都是 `unawaited`（不 await），看起来「不挡启动」；但
    // `wal_checkpoint(TRUNCATE)` 要等所有读者放手、`VACUUM` 要独占写锁，
    // 所以真实影响只能靠并发测量，不能靠「异步所以不影响」推断。
    // ========================================================================
    let first_page_sql = format!(
        "SELECT {} FROM todo_tasks WHERE is_deleted = 0{} ORDER BY updated_at DESC LIMIT 50 OFFSET 0",
        LIST_COLS, ARCHIVED_EXCLUDE
    );

    // 基线：维护不参与时的首屏列表（此时统计已建好，应为 0ms 档）
    let mut base = Vec::new();
    for _ in 0..args.samples {
        let t = Instant::now();
        let _ = sqlx::query_as::<_, (i64,)>(&first_page_sql)
            .fetch_all(&pool_d)
            .await
            .map_err(|e| e.to_string())?;
        base.push(t.elapsed().as_millis());
    }

    // 争用：维护在后台跑的同时打同一批查询
    let maint_pool = pool_d.clone();
    let maint_dir = att_dir_str.clone();
    let maint = tokio::spawn(async move {
        let t = Instant::now();
        let r = orbit_core::api::db_maintenance_api::db_maintenance(&maint_pool, &maint_dir).await;
        (t.elapsed().as_millis(), r.is_ok())
    });

    let mut contended = Vec::new();
    for _ in 0..args.samples {
        let t = Instant::now();
        let _ = sqlx::query_as::<_, (i64,)>(&first_page_sql)
            .fetch_all(&pool_d)
            .await
            .map_err(|e| e.to_string())?;
        contended.push(t.elapsed().as_millis());
    }
    let (contended_total_ms, contested_ok) = maint.await.map_err(|e| e.to_string())?;

    out.insert(
        "scenarioE_bootContention".into(),
        json!({
            "samplesPerSide": args.samples,
            "baselineListMs": percentile_pair(&base),
            "contendedListMs": percentile_pair(&contended),
            "baselineMaxMs": base.iter().copied().max().unwrap_or(0),
            "contendedMaxMs": contended.iter().copied().max().unwrap_or(0),
            "maintenanceTotalMs": contended_total_ms,
            "maintenanceSucceeded": contested_ok,
        }),
    );

    pool_d.close().await;

    Ok(Value::Object(out))
}

// ============================================================================
// 采样集：七条热读路径
// ============================================================================

const LABELS: [&str; 7] = [
    "list-first-page",
    "list-by-project",
    "list-undone",
    "count-all",
    "stats-aggregate",
    "search-broad",
    "calendar-range",
];

/// 与 `generic_repo::LIST_COLUMNS_TASKS` 逐字一致（列表主通道：`NULL AS description`）
const LIST_COLS: &str = "id, title, NULL AS description, project_id, priority, status, done, \
    done_at, due_date, start_date, repeat_mode, percent_done, position, is_favorite, \
    my_day_date, duration_minutes, is_deleted, created_at, updated_at";

/// 归档项目排除子句（`generic_repo::list` 在 project_id 为空时追加）
const ARCHIVED_EXCLUDE: &str = " AND (project_id IS NULL OR project_id NOT IN \
     (SELECT id FROM todo_projects WHERE is_deleted = 0 AND is_archived = 1))";

struct ProbeSet {
    pool: SqlitePool,
    samples: usize,
    latencies: Vec<Vec<u128>>,
    last_raw: Vec<Vec<u128>>,
    filter_first: ListFilter,
    filter_project: ListFilter,
    filter_undone: ListFilter,
    calendar_sql: String,
}

impl ProbeSet {
    fn new(pool: SqlitePool, project_id: i64, samples: usize) -> Self {
        let now = chrono::Utc::now().timestamp_millis();
        let day = 86_400_000i64;
        let calendar_sql = format!(
            "SELECT id FROM todo_tasks WHERE is_deleted = 0 AND done = 0 \
             AND due_date >= {} AND due_date < {} ORDER BY due_date ASC LIMIT 200",
            now - 15 * day,
            now + 15 * day
        );
        Self {
            samples,
            latencies: (0..LABELS.len()).map(|_| Vec::new()).collect(),
            last_raw: (0..LABELS.len()).map(|_| Vec::new()).collect(),
            filter_first: ListFilter {
                page: 1,
                page_size: 50,
                ..Default::default()
            },
            filter_project: ListFilter {
                page: 1,
                page_size: 50,
                project_id: Some(project_id),
                ..Default::default()
            },
            filter_undone: ListFilter {
                page: 1,
                page_size: 50,
                done: Some(false),
                ..Default::default()
            },
            calendar_sql,
            pool,
        }
    }

    /// 采样一轮并汇总 p50/p95（先跑一次预热，不计入样本）
    async fn measure(&mut self) -> Result<Value, String> {
        self.once().await?;
        for v in &mut self.latencies {
            v.clear();
        }
        for _ in 0..self.samples {
            self.once().await?;
        }
        self.last_raw = self.latencies.clone();
        let mut out = Map::new();
        let mut all = Vec::new();
        for (i, label) in LABELS.iter().enumerate() {
            let mut v = std::mem::take(&mut self.latencies[i]);
            v.sort_unstable();
            let p50 = v[v.len() / 2];
            let p95 = v[(v.len() as f64 * 0.95) as usize % v.len()];
            all.extend(v);
            out.insert(label.to_string(), json!({ "p50Ms": p50, "p95Ms": p95 }));
        }
        all.sort_unstable();
        out.insert(
            "overall".into(),
            json!({
                "p50Ms": all[all.len() / 2],
                "p95Ms": all[(all.len() as f64 * 0.95) as usize % all.len()],
            }),
        );
        Ok(Value::Object(out))
    }

    /// 七个口径各跑一次并按固定顺序落样本
    async fn once(&mut self) -> Result<(), String> {
        let t = Instant::now();
        business_api::list_todo_tasks(&self.pool, &self.filter_first)
            .await
            .map_err(|e| e.to_string())?;
        self.push(0, t);

        let t = Instant::now();
        business_api::list_todo_tasks(&self.pool, &self.filter_project)
            .await
            .map_err(|e| e.to_string())?;
        self.push(1, t);

        let t = Instant::now();
        business_api::list_todo_tasks(&self.pool, &self.filter_undone)
            .await
            .map_err(|e| e.to_string())?;
        self.push(2, t);

        let t = Instant::now();
        business_api::business_count(&self.pool, "todo_tasks")
            .await
            .map_err(|e| e.to_string())?;
        self.push(3, t);

        let t = Instant::now();
        stats_api::aggregate(&self.pool, None)
            .await
            .map_err(|e| e.to_string())?;
        self.push(4, t);

        let t = Instant::now();
        business_api::search_all(&self.pool, "操作探针", 20)
            .await
            .map_err(|e| e.to_string())?;
        self.push(5, t);

        let t = Instant::now();
        sqlx::query(&self.calendar_sql)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        self.push(6, t);
        Ok(())
    }

    fn push(&mut self, idx: usize, started: Instant) {
        if self.latencies[idx].len() < self.samples {
            self.latencies[idx].push(started.elapsed().as_millis());
        }
    }

    /// 上一次 `measure()` 的原始样本（毫秒，未排序）——诊断「p50 是双峰还是单峰」
    fn raw(&self) -> Value {
        let mut out = Map::new();
        for (i, label) in LABELS.iter().enumerate() {
            out.insert(label.to_string(), json!(self.last_raw[i]));
        }
        Value::Object(out)
    }

    /// 待取计划的 SQL 清单（与 `generic_repo::list` 逐字一致 + 统计/日历）
    fn plan_sqls(&self) -> Vec<(&'static str, String)> {
        let some_project = self.filter_project.project_id.unwrap_or(1);
        // 注意：字符串里不用 `\` 续行——它会把下一行的缩进连同分隔空格一起吃掉
        vec![
            (
                "list-first-page",
                format!(
                    "EXPLAIN QUERY PLAN SELECT {} FROM todo_tasks WHERE is_deleted = 0{} \
                     ORDER BY updated_at DESC LIMIT 50 OFFSET 0",
                    LIST_COLS, ARCHIVED_EXCLUDE
                ),
            ),
            (
                "list-undone",
                format!(
                    "EXPLAIN QUERY PLAN SELECT {} FROM todo_tasks WHERE is_deleted = 0 AND done = 0{} \
                     ORDER BY updated_at DESC LIMIT 50 OFFSET 0",
                    LIST_COLS, ARCHIVED_EXCLUDE
                ),
            ),
            (
                "list-by-project",
                format!(
                    "EXPLAIN QUERY PLAN SELECT {} FROM todo_tasks WHERE is_deleted = 0 AND project_id = {} \
                     ORDER BY updated_at DESC LIMIT 50 OFFSET 0",
                    LIST_COLS, some_project
                ),
            ),
            (
                "count-all",
                "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0"
                    .to_string(),
            ),
            (
                "calendar-range",
                format!("EXPLAIN QUERY PLAN {}", self.calendar_sql),
            ),
        ]
    }

    /// 真实 SQL 的查询计划（逐条 `EXPLAIN QUERY PLAN`）
    async fn plans(&self) -> Result<Value, String> {
        let mut out = Map::new();
        for (label, sql) in self.plan_sqls() {
            let rows: Vec<(i64, i64, i64, String)> = sqlx::query_as(&sql)
                .fetch_all(&self.pool)
                .await
                .map_err(|e| e.to_string())?;
            let lines: Vec<String> = rows.into_iter().map(|(_, _, _, d)| d).collect();
            out.insert(label.to_string(), json!(lines));
        }
        Ok(Value::Object(out))
    }

    /// 三条连接各取一遍计划——确认「池里不同连接看到的计划是否一致」
    /// （若不一致，说明统计/语句缓存的作用域是连接，而不是库）
    async fn plans_per_conn(&self) -> Result<Value, String> {
        let mut conns = Vec::new();
        for _ in 0..3 {
            conns.push(self.pool.acquire().await.map_err(|e| e.to_string())?);
        }
        let sqls = self.plan_sqls();
        let mut out = Map::new();
        for (i, conn) in conns.iter_mut().enumerate() {
            let mut m = Map::new();
            for (label, sql) in &sqls {
                let rows: Vec<(i64, i64, i64, String)> = sqlx::query_as(sql.as_str())
                    .fetch_all(&mut **conn)
                    .await
                    .map_err(|e| e.to_string())?;
                let first = rows
                    .into_iter()
                    .map(|(_, _, _, d)| d)
                    .next()
                    .unwrap_or_default();
                m.insert(label.to_string(), json!(first));
            }
            out.insert(format!("conn{i}"), Value::Object(m));
        }
        Ok(Value::Object(out))
    }

    /// 给「首屏列表」这条 SQL 的价格表：自动计划 vs 三种强制计划 vs 去掉归档子句。
    /// 用来判断「p50 差 10ms」到底是计划选择还是子查询开销，而不是猜。
    async fn price_forced(&self, samples: usize) -> Result<Value, String> {
        let mut conn = self.pool.acquire().await.map_err(|e| e.to_string())?;
        let sel = format!(
            "SELECT {} FROM todo_tasks {{hint}} WHERE is_deleted = 0{{tail}} \
             ORDER BY updated_at DESC LIMIT 50",
            LIST_COLS
        );
        let variants: [(&str, String); 6] = [
            (
                "auto",
                sel.replace("{hint}", "")
                    .replace("{tail}", ARCHIVED_EXCLUDE),
            ),
            (
                "forced-updated_at",
                sel.replace("{hint}", "INDEXED BY idx_todo_tasks_updated_at")
                    .replace("{tail}", ARCHIVED_EXCLUDE),
            ),
            (
                "forced-trash",
                sel.replace("{hint}", "INDEXED BY idx_todo_tasks_trash")
                    .replace("{tail}", ARCHIVED_EXCLUDE),
            ),
            (
                "forced-is_deleted",
                sel.replace("{hint}", "INDEXED BY idx_todo_tasks_is_deleted")
                    .replace("{tail}", ARCHIVED_EXCLUDE),
            ),
            (
                "auto-no-subquery",
                sel.replace("{hint}", "").replace("{tail}", ""),
            ),
            (
                "forced-trash-no-subquery",
                sel.replace("{hint}", "INDEXED BY idx_todo_tasks_trash")
                    .replace("{tail}", ""),
            ),
        ];
        let mut out = Map::new();
        for (label, sql) in variants {
            // 预热一次（失败也继续，价格表里记录错误而不是整轮失败）
            if let Err(e) = sqlx::query(&sql).fetch_all(&mut *conn).await {
                out.insert(label.to_string(), json!({ "error": e.to_string() }));
                continue;
            }
            let mut v = Vec::new();
            for _ in 0..samples {
                let t = Instant::now();
                sqlx::query(&sql)
                    .fetch_all(&mut *conn)
                    .await
                    .map_err(|e| e.to_string())?;
                v.push(t.elapsed().as_millis());
            }
            v.sort_unstable();
            out.insert(
                label.to_string(),
                json!({
                    "p50Ms": v[v.len() / 2],
                    "p95Ms": v[(v.len() as f64 * 0.95) as usize % v.len()],
                    "minMs": v[0],
                    "maxMs": v[v.len() - 1],
                }),
            );
        }
        Ok(Value::Object(out))
    }
}

// ============================================================================
// 种子与辅助
// ============================================================================

/// 30 个项目（只建一次）+ [from, to) 区间的任务与评论
async fn seed_projects_and_tasks(
    pool: &SqlitePool,
    from: usize,
    to: usize,
) -> Result<u128, String> {
    let t = Instant::now();
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;
    let mut tx = conn.begin().await.map_err(|e| e.to_string())?;
    insert_projects(&mut tx, pool).await?;
    insert_task_range(&mut tx, from, to).await?;
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(t.elapsed().as_millis())
}

/// 「导入涨到 10 倍」：同一连接上再插 [from, to) 区间
async fn import_more_tasks(
    conn: &mut SqliteConnection,
    from: usize,
    to: usize,
) -> Result<u128, String> {
    let t = Instant::now();
    let mut tx = conn.begin().await.map_err(|e| e.to_string())?;
    insert_task_range(&mut tx, from, to).await?;
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(t.elapsed().as_millis())
}

async fn insert_projects(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    pool: &SqlitePool,
) -> Result<(), String> {
    let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_projects")
        .fetch_one(pool)
        .await
        .map_err(|e| e.to_string())?;
    if n > 0 {
        return Ok(());
    }
    let now = chrono::Utc::now().timestamp_millis();
    for i in 0..30 {
        sqlx::query(
            "INSERT INTO todo_projects \
               (uuid, title, hex_color, sort_order, is_deleted, created_at, updated_at, version) \
             VALUES (?, ?, '#3B82F6', ?, 0, ?, ?, 1)",
        )
        .bind(format!("pragma-proj-{i:04}"))
        .bind(format!("探针项目 {i:02}"))
        .bind(i as f64)
        .bind(now)
        .bind(now)
        .execute(&mut **tx)
        .await
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// 任务 + 每 10 条 1 条评论；分布口径：30% 已完成 / 20% 无截止 / 2% 软删 / 10% 未分组
async fn insert_task_range(
    tx: &mut SqliteConnection,
    from: usize,
    to: usize,
) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp_millis();
    let day = 86_400_000i64;
    // 项目 id 一次取回（避免每行一条子查询：导入耗时要量的不是这个）
    let project_ids: Vec<i64> = sqlx::query_as("SELECT id FROM todo_projects ORDER BY id")
        .fetch_all(&mut *tx)
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(id,): (i64,)| id)
        .collect();
    if project_ids.is_empty() {
        return Err("todo_projects 为空".into());
    }

    for i in from..to {
        let project_id: Option<i64> = if i % 10 == 0 {
            None
        } else {
            let slot = ((i % 7) * (i % 7)) % project_ids.len();
            Some(project_ids[slot])
        };
        let done = if i % 10 < 3 { 1 } else { 0 };
        let due = if i % 5 == 0 {
            None
        } else {
            Some(now + ((i as i64 % 730) - 365) * day)
        };
        sqlx::query(
            "INSERT INTO todo_tasks \
               (uuid, title, description, project_id, priority, status, done, done_at, due_date, \
                position, is_deleted, created_at, updated_at, version) \
             VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)",
        )
        .bind(format!("pragma-task-{i:08}"))
        .bind(format!("操作探针任务 {i:06}"))
        .bind(project_id)
        .bind((i % 6) as i64)
        .bind(if done == 1 { "done" } else { "pending" })
        .bind(done)
        .bind(if done == 1 { Some(now) } else { None })
        .bind(due)
        .bind(i as f64)
        .bind(if i % 50 == 0 { 1 } else { 0 })
        .bind(now - i as i64)
        .bind(now - i as i64)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;

        if i % 10 == 0 {
            sqlx::query(
                "INSERT INTO todo_comments \
                   (uuid, task_id, content, is_deleted, created_at, updated_at, version) \
                 VALUES (?, last_insert_rowid(), ?, 0, ?, ?, 1)",
            )
            .bind(format!("pragma-cmt-{i:08}"))
            .bind(format!("评论样本 {i}: 让评论检索与统计有真实行数"))
            .bind(now)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// ANALYZE（钉在单条连接上：analysis_limit 是连接级状态）
async fn analyze_pinned(pool: &SqlitePool, analysis_limit: i64) -> Result<u128, String> {
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;
    let t = Instant::now();
    sqlx::query(&format!("PRAGMA analysis_limit={analysis_limit}"))
        .execute(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query("ANALYZE")
        .execute(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;
    Ok(t.elapsed().as_millis())
}

/// `VACUUM`（整库重写；维护路径紧跟 ANALYZE 之后）
async fn vacuum_pinned(pool: &SqlitePool) -> Result<u128, String> {
    let t = Instant::now();
    sqlx::query("VACUUM")
        .execute(pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(t.elapsed().as_millis())
}

/// `PRAGMA optimize`（钉在指定连接上，便于对照「同连接 / 异连接」）
async fn optimize_on(conn: &mut SqliteConnection, analysis_limit: i64) -> Result<u128, String> {
    let t = Instant::now();
    sqlx::query(&format!("PRAGMA analysis_limit={analysis_limit}"))
        .execute(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query("PRAGMA optimize")
        .execute(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;
    Ok(t.elapsed().as_millis())
}

/// 只灌页缓存：表全扫 + 两个候选索引各扫一遍（不改统计、不改计划）
async fn warm_scan(pool: &SqlitePool) -> Result<u128, String> {
    let t = Instant::now();
    for sql in [
        "SELECT SUM(LENGTH(title)) FROM todo_tasks",
        "SELECT COUNT(*) FROM todo_tasks INDEXED BY idx_todo_tasks_updated_at WHERE is_deleted = 0",
        "SELECT COUNT(*) FROM todo_tasks INDEXED BY idx_todo_tasks_position WHERE is_deleted = 0",
    ] {
        sqlx::query(sql)
            .execute(pool)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(t.elapsed().as_millis())
}

/// 最忙的项目 id（`list-by-project` 要量的不是空项目）
async fn busiest_project(pool: &SqlitePool) -> Result<i64, String> {
    let row: (i64,) = sqlx::query_as(
        "SELECT project_id FROM todo_tasks WHERE is_deleted = 0 AND project_id IS NOT NULL \
         GROUP BY project_id ORDER BY COUNT(*) DESC LIMIT 1",
    )
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;
    Ok(row.0)
}

/// `sqlite_stat1` 的（行数, 内容摘要）——摘要用来判断「统计到底有没有被重写」
async fn stat1_digest(pool: &SqlitePool) -> Result<(i64, u64), String> {
    let exists: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sqlite_stat1'",
    )
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;
    if exists.0 == 0 {
        return Ok((0, 0));
    }
    let rows: Vec<(String, String, String)> =
        sqlx::query_as("SELECT tbl, COALESCE(idx, ''), stat FROM sqlite_stat1 ORDER BY tbl, idx")
            .fetch_all(pool)
            .await
            .map_err(|e| e.to_string())?;
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for (tbl, idx, stat) in &rows {
        for part in [tbl.as_str(), idx.as_str(), stat.as_str()] {
            for b in part.as_bytes() {
                h ^= *b as u64;
                h = h.wrapping_mul(0x100_0000_01b3);
            }
        }
    }
    Ok((rows.len() as i64, h))
}

async fn checkpoint(pool: &SqlitePool) -> Result<(), String> {
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// 读单值 PRAGMA（`freelist_count` / `page_size` 这类单列整数口径）
async fn pragma_of(pool: &SqlitePool, name: &str) -> Result<i64, String> {
    // name 全部为本文件内字面量，无注入面
    let row: (i64,) = sqlx::query_as(&format!("PRAGMA {name}"))
        .fetch_one(pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(row.0)
}

/// p50 / p95（最近秩，与 `ProbeSet::measure` 同口径）
fn percentile_pair(samples: &[u128]) -> Value {
    if samples.is_empty() {
        return json!({ "p50Ms": 0, "p95Ms": 0 });
    }
    let mut v = samples.to_vec();
    v.sort_unstable();
    json!({
        "p50Ms": v[v.len() / 2],
        "p95Ms": v[(v.len() as f64 * 0.95) as usize % v.len()],
    })
}

/// 造「用了一段时间」的库，四类变化各管一件事：
/// - 编辑 / 软删：**不**释放页（只改行内容，页仍是满的）；
/// - 清空回收站：真删任务行 → 释放整页（这是唯一由用户操作产生的真实碎片）；
/// - 过期日志：20k 行 > 30 天 → 只有 TTL prune 才会删，用来量「TTL 释放多少页」。
async fn churn_usage(pool: &SqlitePool) -> Result<Value, String> {
    let now = chrono::Utc::now().timestamp_millis();

    let edited = sqlx::query(
        "UPDATE todo_tasks SET title = title || ' ✓', updated_at = ? WHERE id % 20 = 0",
    )
    .bind(now)
    .execute(pool)
    .await
    .map_err(|e| e.to_string())?
    .rows_affected();

    let soft_deleted =
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1, updated_at = ? WHERE id % 20 = 1")
            .bind(now)
            .execute(pool)
            .await
            .map_err(|e| e.to_string())?
            .rows_affected();

    // 「清空回收站」：物理删 4% 的任务，再删掉失主张的评论
    let purged = sqlx::query("DELETE FROM todo_tasks WHERE id % 25 = 1")
        .execute(pool)
        .await
        .map_err(|e| e.to_string())?
        .rows_affected();
    let purged_comments =
        sqlx::query("DELETE FROM todo_comments WHERE task_id NOT IN (SELECT id FROM todo_tasks)")
            .execute(pool)
            .await
            .map_err(|e| e.to_string())?
            .rows_affected();

    // 过期日志 20k 行（31 天前）+ 新鲜日志 2k 行（本次启动新产生的）
    sqlx::query(
        "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
         INSERT INTO notification_log (kind, task_title, payload, created_at)
         SELECT 'reminder_due', '历史通知 ' || n, '{}', ? - ? * 86400000 - n * 60000 FROM seq",
    )
    .bind(now)
    .bind(31)
    .execute(pool)
    .await
    .map_err(|e| e.to_string())?;

    sqlx::query(
        "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000)
         INSERT INTO notification_log (kind, task_title, payload, created_at)
         SELECT 'reminder_due', '新通知 ' || n, '{}', ? - n * 60000 FROM seq",
    )
    .bind(now)
    .execute(pool)
    .await
    .map_err(|e| e.to_string())?;

    Ok(json!({
        "editedTasks": edited,
        "softDeletedTasks": soft_deleted,
        "purgedTasks": purged,
        "purgedComments": purged_comments,
        "expiredLogRows": 20_000,
        "freshLogRows": 2_000,
    }))
}

fn fresh_db_files(path: &std::path::Path) {
    for suffix in ["", "-wal", "-shm"] {
        let p = PathBuf::from(format!("{}{suffix}", path.display()));
        let _ = std::fs::remove_file(p);
    }
}

fn file_len(path: &std::path::Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}
