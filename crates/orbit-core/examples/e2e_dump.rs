//! 端到端测试取证助手：对**指定 orbit.db** 调用生产 API 落盘
//! `plaintext_export_json` 的 `table_counts`（true/false 双口径）与
//! `stats_aggregate(year)`，供 `verify_consistency.py` 比对真机/桌面壳的库。
//!
//! 用法：
//! ```bash
//! cargo run --release -p orbit-core --example e2e_dump -- \
//!   --db target/sync-e2e/run4/m1.db --tag phase4 --out-dir target/sync-e2e/run4 --name m1
//! ```
//!
//! 只读：不迁移、不写入业务表。

use std::path::PathBuf;

use orbit_core::api::{plaintext_export_api, stats_api};
use orbit_core::db::pool::init_pool_unencrypted;

const YEARS: [i64; 4] = [1999, 2005, 2018, 2026];

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let mut db: Option<PathBuf> = None;
    let mut out_dir: Option<PathBuf> = None;
    let mut tag = String::from("phase4");
    let mut name = String::from("node");
    while let Some(k) = args.next() {
        match k.as_str() {
            "--db" => db = args.next().map(PathBuf::from),
            "--out-dir" => out_dir = args.next().map(PathBuf::from),
            "--tag" => tag = args.next().expect("--tag 值"),
            "--name" => name = args.next().expect("--name 值"),
            other => panic!("未知参数 {other}"),
        }
    }
    let db = db.expect("缺少 --db");
    let out_dir = out_dir.expect("缺少 --out-dir");
    std::fs::create_dir_all(&out_dir).unwrap();

    let pool = init_pool_unencrypted(&db).await.expect("建池");
    for exclude in [true, false] {
        let r = plaintext_export_api::export_plaintext_json(&pool, exclude)
            .await
            .expect("plaintext export");
        let path = out_dir.join(format!("counts_{name}_{tag}_{exclude}.json"));
        std::fs::write(
            &path,
            serde_json::to_string_pretty(&serde_json::json!(r.table_counts)).unwrap(),
        )
        .unwrap();
        println!("COUNT {exclude} -> {} {:?}", path.display(), r.table_counts);
    }
    for year in YEARS {
        let agg = stats_api::aggregate(&pool, Some(year))
            .await
            .expect("stats");
        let path = out_dir.join(format!("stats_{name}_{tag}_{year}.json"));
        std::fs::write(
            &path,
            serde_json::to_string_pretty(&serde_json::to_value(&agg).unwrap()).unwrap(),
        )
        .unwrap();
        println!("STATS {year} -> {}", path.display());
    }
    println!("E2E_DUMP_DONE {name}");
}
