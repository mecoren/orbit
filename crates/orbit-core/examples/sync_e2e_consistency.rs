//! 云同步端到端一致性测试台（三实例 × S3 / WebDAV）。
//!
//! 三个彼此独立的「设备目录」各自持有 orbit.db / sync_state.json /
//! sync_crypto_meta.json / attachments，走生产 `cloud_sync_api::pull_then_push`
//! 与真实 HTTP 适配器；不经过 GUI 壳层（业务逻辑全在 orbit-core）。
//!
//! 运行示例：
//! ```bash
//! cargo run --release -p orbit-core --example sync_e2e_consistency -- \
//!   --protocol webdav --base-path orbit-sync-test/20261110-run2/webdav \
//!   --secrets target/sync-e2e/e2e-secrets.json \
//!   --seed-db target/sync-e2e/seed2/orbit.db \
//!   --attachments target/sync-e2e/seed2/attachments \
//!   --run-dir target/sync-e2e/round-webdav
//! ```
//!
//! 证据写入 `--run-dir`：timeline.jsonl（时序/计数/耗时）、
//! counts_*.json（plaintext_export_json 的 table_counts）、state_*.json、
//! stats_*.json，DB 与附件目录保留原位供 `verify_consistency.py` 抽样比对。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use orbit_core::api::{cloud_sync_api, plaintext_export_api, stats_api};
use orbit_core::cloud_sync::engine::{SyncEngine, SyncResult};
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::sync::engine::SyncConfig;
use orbit_core::sync_crypto::SyncCryptoService;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

const YEARS: [i64; 4] = [1999, 2005, 2018, 2026];

#[derive(Debug, Deserialize)]
struct ProtocolSecrets {
    endpoint: String,
    #[serde(default)]
    bucket: String,
    #[serde(default)]
    region: String,
    access_key: String,
    secret_key: String,
}

#[derive(Debug, Deserialize)]
struct Secrets {
    s3: ProtocolSecrets,
    webdav: ProtocolSecrets,
    test_password: String,
}

#[derive(Debug)]
struct Args {
    protocol: String,
    base_path: String,
    secrets: PathBuf,
    seed_db: PathBuf,
    attachments: PathBuf,
    run_dir: PathBuf,
    phase5: bool,
    /// 只跑 5.3 错密分类（定向复跑，不重跑阶段 3/4）
    only_wrong_password: bool,
}

fn parse_args() -> Args {
    let mut map: BTreeMap<String, String> = BTreeMap::new();
    let mut it = std::env::args().skip(1);
    while let Some(k) = it.next() {
        if let Some(key) = k.strip_prefix("--") {
            match key {
                "phase5" | "only-wrong-password" => {
                    map.insert(key.to_string(), "1".into());
                }
                _ => {
                    let v = it.next().unwrap_or_else(|| panic!("缺少 --{key} 的值"));
                    map.insert(key.to_string(), v);
                }
            }
        }
    }
    let get = |k: &str| map.get(k).cloned().unwrap_or_else(|| panic!("缺少 --{k}"));
    Args {
        protocol: get("protocol"),
        base_path: get("base-path"),
        secrets: PathBuf::from(get("secrets")),
        seed_db: PathBuf::from(get("seed-db")),
        attachments: PathBuf::from(get("attachments")),
        run_dir: PathBuf::from(get("run-dir")),
        phase5: map.contains_key("phase5"),
        only_wrong_password: map.contains_key("only-wrong-password"),
    }
}

fn copy_dir_all(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let to = dst.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_all(&entry.path(), &to)?;
        } else {
            fs::copy(entry.path(), to)?;
        }
    }
    Ok(())
}

struct Node {
    dir: PathBuf,
    pool: SqlitePool,
    engine: Arc<SyncEngine>,
    cfg: SyncConfig,
}

impl Node {
    async fn new(
        name: &str,
        root: &Path,
        args: &Args,
        secrets: &Secrets,
        with_seed: bool,
        password_override: Option<&str>,
    ) -> Self {
        let dir = root.join(name);
        fs::create_dir_all(dir.join("attachments")).unwrap();
        let db_path = dir.join("orbit.db");
        if with_seed {
            fs::copy(&args.seed_db, &db_path).unwrap();
            copy_dir_all(&args.attachments, &dir.join("attachments")).unwrap();
        }
        let pool = orbit_core::db::pool::init_pool_unencrypted(&db_path)
            .await
            .expect("建池");
        if !with_seed {
            sqlx::migrate!("./src/db/migrations")
                .run(&pool)
                .await
                .expect("迁移");
        }
        let password = password_override
            .unwrap_or(&secrets.test_password)
            .to_string();
        let crypto = SyncCryptoService::new(&dir);
        crypto.init(&password).expect("init crypto");
        let engine = Arc::new(cloud_sync_api::create_engine_noop(
            pool.clone(),
            crypto,
            &dir,
        ));
        engine.set_sync_password(password);

        let p = match args.protocol.as_str() {
            "s3" => &secrets.s3,
            "webdav" => &secrets.webdav,
            other => panic!("未知协议 {other}"),
        };
        let cfg = SyncConfig {
            adapter_type: args.protocol.clone(),
            endpoint: p.endpoint.clone(),
            bucket: p.bucket.clone(),
            region: p.region.clone(),
            access_key: p.access_key.clone(),
            secret_key: p.secret_key.clone(),
            base_path: args.base_path.clone(),
            device_id: name.to_string(),
            device_name: name.to_string(),
            timeout_secs: 60,
            skip_tls_verify: false,
            session_token: String::new(),
        };
        Self {
            dir,
            pool,
            engine,
            cfg,
        }
    }

    fn attachments_dir(&self) -> String {
        self.dir.join("attachments").to_str().unwrap().to_string()
    }

    async fn sync(&self, mode: &str) -> Result<SyncResult, String> {
        let origin = SyncOrigin::Manual;
        let dir = self.attachments_dir();
        let r = match mode {
            "push" => {
                cloud_sync_api::push_only(
                    &self.engine,
                    &self.cfg,
                    origin,
                    &self.cfg.device_id,
                    &dir,
                )
                .await
            }
            _ => {
                cloud_sync_api::pull_then_push(
                    &self.engine,
                    &self.cfg,
                    origin,
                    &self.cfg.device_id,
                    &dir,
                )
                .await
            }
        };
        r.map_err(|e| format!("{e:?}"))
    }
}

fn write_json(path: &Path, value: &Value) {
    fs::write(path, serde_json::to_string_pretty(value).unwrap()).unwrap();
}

async fn timed_step(
    nodes: &BTreeMap<String, Node>,
    timeline: &mut Vec<Value>,
    label: &str,
    node: &str,
    mode: &str,
) -> Result<SyncResult, String> {
    let n = &nodes[node];
    let started_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let t0 = Instant::now();
    let res = n.sync(mode).await;
    let ms = t0.elapsed().as_millis() as u64;
    match &res {
        Ok(r) => {
            let entry = json!({
                "step": label, "node": node, "mode": mode,
                "started_at": started_at, "duration_ms": ms, "result": r,
            });
            println!("[{}] {} {} {:?} {}ms", label, node, mode, r, ms);
            timeline.push(entry);
        }
        Err(e) => {
            let entry = json!({
                "step": label, "node": node, "mode": mode,
                "started_at": started_at, "duration_ms": ms, "error": e,
            });
            eprintln!("[{}] {} {} ERROR {} {}ms", label, node, mode, e, ms);
            timeline.push(entry);
        }
    }
    res
}

async fn edit_task(pool: &SqlitePool, uuid: &str, title: &str) {
    let now = orbit_core::db::clock::next_ms();
    sqlx::query("UPDATE todo_tasks SET title=?, version=version+1, updated_at=? WHERE uuid=?")
        .bind(title)
        .bind(now)
        .bind(uuid)
        .execute(pool)
        .await
        .expect("edit task");
}

async fn scalar_i64(pool: &SqlitePool, sql: &str) -> i64 {
    let (v,): (i64,) = sqlx::query_as(sql).fetch_one(pool).await.expect("scalar");
    v
}

async fn scalar_text(pool: &SqlitePool, sql: &str) -> String {
    let (v,): (String,) = sqlx::query_as(sql).fetch_one(pool).await.expect("scalar");
    v
}

async fn dump_evidence(nodes: &BTreeMap<String, Node>, args: &Args, tag: &str) {
    for (name, n) in nodes {
        for exclude in [true, false] {
            let r = plaintext_export_api::export_plaintext_json(&n.pool, exclude)
                .await
                .expect("plaintext export");
            write_json(
                &args
                    .run_dir
                    .join(format!("counts_{name}_{tag}_{exclude}.json")),
                &json!(r.table_counts),
            );
            drop(r.content);
        }
        let st = cloud_sync_api::get_state(&n.engine).expect("state");
        write_json(
            &args.run_dir.join(format!("state_{name}_{tag}.json")),
            &serde_json::to_value(&st).unwrap(),
        );
        for year in YEARS {
            let agg = stats_api::aggregate(&n.pool, Some(year))
                .await
                .expect("stats");
            write_json(
                &args.run_dir.join(format!("stats_{name}_{tag}_{year}.json")),
                &serde_json::to_value(&agg).unwrap(),
            );
        }
    }
}

#[tokio::main]
async fn main() {
    let args = parse_args();
    orbit_core::context::set_device_id("sync-e2e-harness".to_string()).ok();
    fs::create_dir_all(&args.run_dir).unwrap();
    let secrets: Secrets =
        serde_json::from_str(&fs::read_to_string(&args.secrets).unwrap()).unwrap();

    println!(
        "E2E_START protocol={} base_path={} seed={:?} run_dir={:?}",
        args.protocol, args.base_path, args.seed_db, args.run_dir
    );

    if args.only_wrong_password {
        let entry = check_wrong_password(&args, &secrets).await;
        println!("ONLY_WRONG_PASSWORD {entry}");
        return;
    }

    let mut nodes = BTreeMap::new();
    for (name, seeded) in [("m1", true), ("m2", false), ("desktop", false)] {
        nodes.insert(
            name.to_string(),
            Node::new(name, &args.run_dir, &args, &secrets, seeded, None).await,
        );
    }

    let mut timeline: Vec<Value> = Vec::new();
    timeline.push(json!({
        "step": "phase0", "protocol": args.protocol,
        "base_path": args.base_path,
        "seed_db": args.seed_db.to_string_lossy(),
        "seed_bytes": fs::metadata(&args.seed_db).unwrap().len(),
        "attachments": fs::read_dir(&args.attachments).unwrap().count(),
    }));

    // ── 阶段 3：全量 push / pull / 幂等 / 跨端回流 ──
    let t_all = Instant::now();
    if timed_step(&nodes, &mut timeline, "3.1_m1_push", "m1", "full")
        .await
        .is_err()
    {
        persist(&args, &timeline, &nodes, "aborted");
        panic!("阶段 3.1 失败，见 timeline.jsonl");
    }
    timed_step(&nodes, &mut timeline, "3.2_m2_full_pull", "m2", "full")
        .await
        .expect("阶段 3.2");
    timed_step(&nodes, &mut timeline, "3.3_m2_idempotent", "m2", "full")
        .await
        .expect("阶段 3.3");
    timed_step(
        &nodes,
        &mut timeline,
        "3.4_desktop_full_pull",
        "desktop",
        "full",
    )
    .await
    .expect("阶段 3.4");

    let target_uuid = scalar_text(
        &nodes["m1"].pool,
        "SELECT uuid FROM todo_tasks WHERE is_deleted=0 ORDER BY uuid LIMIT 1",
    )
    .await;
    println!("TARGET_UUID={target_uuid}");
    timeline.push(json!({"step":"target","uuid":target_uuid}));

    // 3.5 桌面改标题 + 新建项目
    let now = orbit_core::db::clock::next_ms();
    edit_task(&nodes["desktop"].pool, &target_uuid, "E2E-桌面改写标题").await;
    sqlx::query(
        "INSERT INTO todo_projects (uuid, title, sort_order, created_at, updated_at, version) \
         VALUES ('e2e-new-project', 'E2E-桌面新建项目', 99999, ?, ?, 1)",
    )
    .bind(now)
    .bind(now)
    .execute(&nodes["desktop"].pool)
    .await
    .expect("new project");
    timed_step(
        &nodes,
        &mut timeline,
        "3.5_desktop_push_edit",
        "desktop",
        "full",
    )
    .await
    .expect("阶段 3.5");
    timed_step(&nodes, &mut timeline, "3.6_m2_pull_edit", "m2", "full")
        .await
        .expect("阶段 3.6");
    timeline.push(json!({
        "step": "3.6_verify",
        "m2_title": scalar_text(&nodes["m2"].pool,
            &format!("SELECT title FROM todo_tasks WHERE uuid='{target_uuid}'")).await,
        "m2_new_project": scalar_i64(&nodes["m2"].pool,
            "SELECT COUNT(*) FROM todo_projects WHERE uuid='e2e-new-project'").await,
    }));

    // 3.7 移动2 改回 + 桌面回流
    edit_task(&nodes["m2"].pool, &target_uuid, "E2E-移动2改回标题").await;
    timed_step(&nodes, &mut timeline, "3.7_m2_push_revert", "m2", "full")
        .await
        .expect("阶段 3.7");
    timed_step(
        &nodes,
        &mut timeline,
        "3.8_desktop_pull_revert",
        "desktop",
        "full",
    )
    .await
    .expect("阶段 3.8");
    timeline.push(json!({
        "step": "3.8_verify",
        "desktop_title": scalar_text(&nodes["desktop"].pool,
            &format!("SELECT title FROM todo_tasks WHERE uuid='{target_uuid}'")).await,
    }));

    // 让所有节点看到同一清单（含 3.5-3.8 的增量）
    timed_step(&nodes, &mut timeline, "3.9_m1_final_pull", "m1", "full")
        .await
        .expect("阶段 3.9");

    println!("PHASE3_TOTAL_MS={}", t_all.elapsed().as_millis());

    // ── 阶段 4：证据落盘（逐表行数 / 云端视图 / 统计）──
    dump_evidence(&nodes, &args, "phase4").await;
    let snap = args.run_dir.join("phase4_snapshot");
    fs::create_dir_all(&snap).unwrap();
    let mut snap_paths = serde_json::Map::new();
    for (name, n) in &nodes {
        // WAL 归位后再冻结快照，保证阶段 5 的后续改动不污染阶段 4 比对
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(&n.pool)
            .await
            .expect("checkpoint");
        let dst = snap.join(name);
        fs::create_dir_all(&dst).unwrap();
        fs::copy(n.dir.join("orbit.db"), dst.join("orbit.db")).unwrap();
        snap_paths.insert(name.clone(), json!(dst.join("orbit.db").to_string_lossy()));
    }
    let db_paths = json!({
        "m1": snap_paths["m1"],
        "m2": snap_paths["m2"],
        "desktop": snap_paths["desktop"],
        "attachments": {
            "m1": nodes["m1"].attachments_dir(),
            "m2": nodes["m2"].attachments_dir(),
            "desktop": nodes["desktop"].attachments_dir(),
        },
    });
    write_json(&args.run_dir.join("db_paths.json"), &db_paths);
    write_json(&args.run_dir.join("db_paths_phase4.json"), &db_paths);
    persist(&args, &timeline, &nodes, "phase4");
    println!("PHASE4_EVIDENCE_OK run_dir={:?}", args.run_dir);

    // ── 阶段 5：冲突 / 墓碑 / 错密 / 取消（仅 S3 轮）──
    if args.phase5 {
        phase5(&nodes, &args, &secrets, &target_uuid, &mut timeline).await;
    }

    println!(
        "E2E_DONE protocol={} total_ms={}",
        args.protocol,
        t_all.elapsed().as_millis()
    );
}

fn persist(args: &Args, timeline: &[Value], nodes: &BTreeMap<String, Node>, tag: &str) {
    let mut out = String::new();
    for v in timeline {
        out.push_str(&serde_json::to_string(v).unwrap());
        out.push('\n');
    }
    fs::write(
        args.run_dir.join(format!("timeline_{tag}.jsonl")),
        out.clone(),
    )
    .unwrap();
    fs::write(args.run_dir.join("timeline.jsonl"), out).unwrap();
    let mut states = serde_json::Map::new();
    for (name, n) in nodes {
        if let Ok(st) = cloud_sync_api::get_state(&n.engine) {
            states.insert(name.clone(), serde_json::to_value(st).unwrap());
        }
    }
    write_json(
        &args.run_dir.join(format!("states_{tag}.json")),
        &Value::Object(states),
    );
}

/// 5.3 错密：独立实例用错误密码指向同一 base_path，不得清本地数据
///
/// 独立成函数是为了支持 `--only-wrong-password` 定向复跑（全量轮 ~6 分钟，
/// 只验错误分类时不必重跑阶段 3/4）。
async fn check_wrong_password(args: &Args, secrets: &Secrets) -> Value {
    let bad = Node::new(
        "wrongpw",
        &args.run_dir,
        args,
        secrets,
        true,
        Some("definitely-wrong-password"),
    )
    .await;
    let before = scalar_i64(&bad.pool, "SELECT COUNT(*) FROM todo_tasks").await;
    let t0 = Instant::now();
    let r = bad.sync("full").await;
    let err = match &r {
        Ok(x) => format!("NO_ERROR result={x:?}"),
        Err(e) => e.clone(),
    };
    let after = scalar_i64(&bad.pool, "SELECT COUNT(*) FROM todo_tasks").await;
    // 直接解锁路径的精确错误分类（UI 输错密码走的就是这一条）
    let verify_dir = args.run_dir.join("wrongpw-unlock-check");
    fs::create_dir_all(&verify_dir).unwrap();
    let svc = SyncCryptoService::new(&verify_dir);
    svc.init(&secrets.test_password)
        .expect("init verify crypto");
    svc.lock();
    let unlock_err = format!("{:?}", svc.unlock("definitely-wrong-password").unwrap_err());
    json!({
        "step": "5.3_wrong_password", "duration_ms": t0.elapsed().as_millis(),
        "sync_error": err, "unlock_error": unlock_err,
        "rows_before": before, "rows_after": after,
    })
}

async fn phase5(
    nodes: &BTreeMap<String, Node>,
    args: &Args,
    secrets: &Secrets,
    target_uuid: &str,
    timeline: &mut Vec<Value>,
) {
    // 5.1 双端离线并发改同一任务（>1s 间隔）→ LWW / sync_conflicts
    edit_task(&nodes["m1"].pool, target_uuid, "E2E-冲突-移动1").await;
    tokio::time::sleep(Duration::from_millis(1200)).await;
    edit_task(&nodes["m2"].pool, target_uuid, "E2E-冲突-移动2").await;
    let m1_ts = scalar_i64(
        &nodes["m1"].pool,
        &format!("SELECT updated_at FROM todo_tasks WHERE uuid='{target_uuid}'"),
    )
    .await;
    let m2_ts = scalar_i64(
        &nodes["m2"].pool,
        &format!("SELECT updated_at FROM todo_tasks WHERE uuid='{target_uuid}'"),
    )
    .await;
    timeline.push(json!({
        "step": "5.1_offline_edits", "m1_updated_at": m1_ts, "m2_updated_at": m2_ts,
        "m1_title": "E2E-冲突-移动1", "m2_title": "E2E-冲突-移动2",
    }));
    timed_step(nodes, timeline, "5.1_m1_push_conflict", "m1", "push")
        .await
        .expect("5.1 push");
    timed_step(nodes, timeline, "5.1_m2_sync_conflict", "m2", "full")
        .await
        .expect("5.1 m2 sync");
    let conflicts = scalar_i64(&nodes["m2"].pool, "SELECT COUNT(*) FROM sync_conflicts").await;
    let m2_title = scalar_text(
        &nodes["m2"].pool,
        &format!("SELECT title FROM todo_tasks WHERE uuid='{target_uuid}'"),
    )
    .await;
    let dup = scalar_i64(
        &nodes["m2"].pool,
        &format!("SELECT COUNT(*) FROM todo_tasks WHERE uuid='{target_uuid}'"),
    )
    .await;
    timeline.push(json!({
        "step": "5.1_verify", "sync_conflicts": conflicts,
        "winner_title": m2_title, "rows_with_uuid": dup,
        "lww_winner": if m2_ts > m1_ts { "m2" } else { "m1" },
    }));
    timed_step(nodes, timeline, "5.1_m1_final_pull", "m1", "full")
        .await
        .expect("5.1 converge");

    // 5.2 墓碑传播：m1 软删项目 → m2 不复活
    let now = orbit_core::db::clock::next_ms();
    sqlx::query(
        "UPDATE todo_projects SET is_deleted=1, deleted_at=?, updated_at=?, version=version+1 \
         WHERE uuid='e2e-new-project'",
    )
    .bind(now)
    .bind(now)
    .execute(&nodes["m1"].pool)
    .await
    .expect("tombstone");
    timed_step(nodes, timeline, "5.2_m1_push_tombstone", "m1", "push")
        .await
        .expect("5.2 push");
    timed_step(nodes, timeline, "5.2_m2_pull_tombstone", "m2", "full")
        .await
        .expect("5.2 pull");
    let alive = scalar_i64(
        &nodes["m2"].pool,
        "SELECT COUNT(*) FROM todo_projects WHERE uuid='e2e-new-project' AND is_deleted=0",
    )
    .await;
    let deleted_at: (Option<i64>,) =
        sqlx::query_as("SELECT deleted_at FROM todo_projects WHERE uuid='e2e-new-project'")
            .fetch_one(&nodes["m2"].pool)
            .await
            .expect("deleted_at");
    timeline.push(json!({
        "step": "5.2_verify", "alive_rows": alive, "m2_deleted_at": deleted_at.0,
    }));

    // 5.3 错密：独立实例用错误密码指向同一 base_path，不得清本地数据
    let entry = check_wrong_password(args, secrets).await;
    println!("[5.3] {entry}");
    timeline.push(entry);

    // 5.4 取消同步 → 回待命 → 再同步成功
    let n = &nodes["m2"];
    edit_task(&n.pool, target_uuid, "E2E-取消前本地改动").await;
    let eng = n.engine.clone();
    let cfg = n.cfg.clone();
    let dev = cfg.device_id.clone();
    let dir = n.attachments_dir();
    let handle = tokio::spawn(async move {
        cloud_sync_api::pull_then_push(&eng, &cfg, SyncOrigin::Manual, &dev, &dir).await
    });
    let mut waited = 0u64;
    while !n.engine.is_running() && waited < 5000 {
        tokio::time::sleep(Duration::from_millis(10)).await;
        waited += 10;
    }
    let hit = n.engine.request_cancel();
    let cancelled = handle.await.unwrap();
    let cancelled_desc = match &cancelled {
        Ok(x) => format!("OK result={x:?}"),
        Err(e) => format!("{e:?}"),
    };
    let idle = !n.engine.is_running();
    let retry = n.sync("full").await;
    timeline.push(json!({
        "step": "5.4_cancel", "wait_ms": waited, "cancel_hit": hit,
        "cancelled_result": cancelled_desc, "idle_after_cancel": idle,
        "retry_ok": retry.is_ok(),
        "retry_result": retry.as_ref().ok().map(|r| json!(r)),
        "retry_error": retry.as_ref().err(),
    }));
    println!(
        "[5.4] cancel_hit={hit} cancelled={cancelled_desc} idle={idle} retry_ok={}",
        retry.is_ok()
    );

    dump_evidence(nodes, args, "phase5").await;
    persist(args, timeline, nodes, "phase5");
}
