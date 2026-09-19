//! 5.x 同步链路端到端集成测试（活体真服务端诊断用例）
//!
//! **默认不跑**（`#[ignore]`）：本用例探不到外部 WebDAV 时会 panic，曾是
//! 干净机器 `cargo test --workspace` 必红的根因（第五轮探查 F25）。
//! 无外部依赖的等价覆盖（含四类操作 × 七种故障、清单 CAS 的网络级证据）
//! 在 `tests/sync_fault_matrix.rs`，用同仓假服务随时可跑。
//!
//! 本用例保留的价值是「真服务端方言」：wsgidav / 群晖 / 坚果云对 PROPFIND
//! 形态、MKCOL 409 语义、ETag 引号的处理各家不同，假服务证明不了这些。
//!
//! 场景（对齐 docs/superpowers/plans/2026-08-24-m4-device-checklist.md §五）：
//! - 5.2/5.3：sync_data_key → push（设备 A 上传）→ 设备 B pull 收敛
//! - 5.4：`sync_config.json` 明文降级文件落盘验证（save_with_plaintext_fallback，
//!   不依赖网络，普通 `cargo test` 即跑）
//!
//! 运行：`ORBIT_TEST_WEBDAV=http://127.0.0.1:8123 cargo test -p orbit-core \
//!   --test m4_sync_e2e -- --ignored`（先起服务器，如
//!   `python .m4-evidence/dav_probe.py`）

use std::path::PathBuf;

use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::context;
use orbit_core::sync_crypto::SyncCryptoService;
use sqlx::SqlitePool;

fn test_webdav_endpoint() -> String {
    std::env::var("ORBIT_TEST_WEBDAV").unwrap_or_else(|_| "http://127.0.0.1:8123".into())
}

/// 每轮唯一 base_path：起跑态天然为空，无需再维护一份「删除上次残留」的路径清单
/// （旧清理清单停在 `_meta.orsync`/`modules` 老布局，从未删过现布局，
/// 收敛用例的结论其实依赖云端残留——第五轮探查 F25）
fn test_base_path() -> String {
    format!("orbit-m4-e2e-{}", std::process::id())
}

fn sync_config(endpoint: &str, device_id: &str) -> orbit_core::sync::engine::SyncConfig {
    orbit_core::sync::engine::SyncConfig {
        adapter_type: "webdav".into(),
        endpoint: endpoint.into(),
        bucket: String::new(),
        region: String::new(),
        access_key: "m4tester".into(),
        secret_key: "m4pass123".into(),
        base_path: test_base_path(),
        device_id: device_id.into(),
        device_name: device_id.into(),
        timeout_secs: 15,
        skip_tls_verify: false,
    }
}

async fn setup_db(tag: &str) -> (SqlitePool, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let data_dir: PathBuf = dir.path().to_path_buf();
    let db_path = data_dir.join("orbit.db");
    let pool = orbit_core::db::pool::init_pool_unencrypted(&db_path)
        .await
        .expect("create pool");
    sqlx::migrate!("./src/db/migrations")
        .run(&pool)
        .await
        .expect("migrate");
    context::set_device_id(tag.to_string()).ok();
    (pool, data_dir)
}

/// 5.2/5.3 双实例收敛：A init（上传 crypto/config + 推数据）→ B 用同密码
/// init 后 pull → 断言 B 收敛到 A 的任务集
#[tokio::test]
#[ignore = "需要本机可达的真 WebDAV 服务；无外部依赖的等价覆盖见 tests/sync_fault_matrix.rs"]
async fn two_instance_convergence_over_webdav() {
    let endpoint = test_webdav_endpoint();
    // 前置连通性：服务器不在线时跳过（不失败——CI/无网络环境下不误报）
    match reqwest::Client::new()
        .request(
            reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
            format!("{endpoint}/"),
        )
        .header("Depth", "0")
        .send()
        .await
    {
        Ok(r) if r.status().as_u16() == 207 => {}
        Ok(r) => panic!(
            "WebDAV 探针返回非 207：{}（先运行 python .m4-evidence/dav_probe.py）",
            r.status()
        ),
        Err(e) => panic!("WebDAV 探针不可达：{e}（先运行 python .m4-evidence/dav_probe.py）"),
    }

    let sync_password = "m4-sync-pass-123456";

    // ── 实例 A：init + 建任务 + push ──
    let (pool_a, dir_a) = setup_db("device-a").await;
    let crypto_a = SyncCryptoService::new(&dir_a);
    crypto_a.init(sync_password).expect("A init crypto");
    let engine_a = cloud_sync_api::create_engine_noop(pool_a.clone(), crypto_a, &dir_a);
    engine_a.set_sync_password(sync_password.to_string());

    // A 建一个任务（时间戳走逻辑时钟，与生产写路径同口径）
    let now = orbit_core::db::clock::next_ms();
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, status, done, position, created_at, updated_at, version) \
         VALUES ('e2e-a-1', 'E2E收敛任务A', 'pending', 0, 1, ?, ?, 1)",
    )
    .bind(now)
    .bind(now)
    .execute(&pool_a)
    .await
    .expect("A seed task");

    // A 同步（pull_then_push：首推 crypto/config + 模块数据）
    let cfg_a = sync_config(&endpoint, "device-a");
    let attachments = dir_a.join("attachments");
    let result_a = cloud_sync_api::pull_then_push(
        &engine_a,
        &cfg_a,
        SyncOrigin::Manual,
        "device-a",
        attachments.to_str().unwrap(),
    )
    .await
    .expect("A 同步失败");
    assert!(
        result_a.pushed_modules > 0,
        "A 应至少推送 1 个模块：{result_a:?}"
    );

    // ── 实例 B：init（同密码）+ pull → 收敛断言 ──
    let (pool_b, dir_b) = setup_db("device-b").await;
    let crypto_b = SyncCryptoService::new(&dir_b);
    // B 先 init（生成随机 key）再经 sync_data_key 从云端导入 A 的 key
    crypto_b.init(sync_password).expect("B init crypto");
    let engine_b = cloud_sync_api::create_engine_noop(pool_b.clone(), crypto_b, &dir_b);
    engine_b.set_sync_password(sync_password.to_string());

    let cfg_b = sync_config(&endpoint, "device-b");
    let result_b = cloud_sync_api::pull_then_push(
        &engine_b,
        &cfg_b,
        SyncOrigin::Manual,
        "device-b",
        dir_b.join("attachments").to_str().unwrap(),
    )
    .await
    .expect("B 同步失败");
    assert!(
        result_b.pulled_modules > 0,
        "B 应至少拉取 1 个模块：{result_b:?}"
    );

    // 收敛断言：B 库有 A 的任务
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE uuid='e2e-a-1'")
        .fetch_one(&pool_b)
        .await
        .expect("B count");
    assert_eq!(count, 1, "B 应收敛到 A 的任务（5.3 双端收敛）");

    // ── 反向：B 编辑 → A pull 收敛（双向）──
    sqlx::query(
        "UPDATE todo_tasks SET title='E2E收敛任务A-已编辑', version=version+1, updated_at=? \
         WHERE uuid='e2e-a-1'",
    )
    .bind(orbit_core::db::clock::next_ms())
    .execute(&pool_b)
    .await
    .expect("B edit");
    let _ = cloud_sync_api::push_only(
        &engine_b,
        &cfg_b,
        SyncOrigin::Manual,
        "device-b",
        dir_b.join("attachments").to_str().unwrap(),
    )
    .await
    .expect("B push 失败");
    let _ = cloud_sync_api::pull_then_push(
        &engine_a,
        &cfg_a,
        SyncOrigin::Manual,
        "device-a",
        attachments.to_str().unwrap(),
    )
    .await
    .expect("A pull 失败");
    let (title,): (String,) = sqlx::query_as("SELECT title FROM todo_tasks WHERE uuid='e2e-a-1'")
        .fetch_one(&pool_a)
        .await
        .expect("A title");
    assert_eq!(
        title, "E2E收敛任务A-已编辑",
        "A 应收敛 B 的编辑（双向收敛）"
    );

    // ── 墓碑收敛：B 删除 → A pull 后不复活 ──
    sqlx::query(
        "UPDATE todo_tasks SET is_deleted=1, deleted_at=?, updated_at=?, version=version+1 \
         WHERE uuid='e2e-a-1'",
    )
    .bind(orbit_core::db::clock::next_ms())
    .bind(orbit_core::db::clock::next_ms())
    .execute(&pool_b)
    .await
    .expect("B tombstone");
    let _ = cloud_sync_api::push_only(
        &engine_b,
        &cfg_b,
        SyncOrigin::Manual,
        "device-b",
        dir_b.join("attachments").to_str().unwrap(),
    )
    .await
    .expect("B tombstone push");
    let _ = cloud_sync_api::pull_then_push(
        &engine_a,
        &cfg_a,
        SyncOrigin::Manual,
        "device-a",
        attachments.to_str().unwrap(),
    )
    .await
    .expect("A tombstone pull");
    let (alive,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE uuid='e2e-a-1' AND is_deleted=0")
            .fetch_one(&pool_a)
            .await
            .expect("A alive count");
    assert_eq!(alive, 0, "删除以墓碑语义收敛不复活（5.3）");
}

/// 5.4 明文降级：EncryptedConfigStorage::save_with_plaintext_fallback 在
/// CekUnavailable（移动端 KeyringCekProvider 恒定契约）时产出明文
/// sync_config.json（桌面恒加密分支的移动端对照）
#[test]
fn sync_config_plaintext_fallback_file() {
    use orbit_core::config_enc::cek::{CEK_LEN, CekProvider};
    use orbit_core::config_enc::{ConfigEncError, EncryptedConfigStorage};

    /// 移动端 KeyringCekProvider 的恒定契约替身（ADR 0001）
    struct UnavailableCekProvider;
    impl CekProvider for UnavailableCekProvider {
        fn get_or_create(&self) -> Result<[u8; CEK_LEN], ConfigEncError> {
            Err(ConfigEncError::CekUnavailable("mobile: no keyring".into()))
        }
        fn is_available(&self) -> bool {
            false
        }
    }

    let dir = tempfile::tempdir().expect("tempdir");
    let app_data_dir = dir.path().to_path_buf();
    let store = EncryptedConfigStorage::new(
        std::sync::Arc::new(UnavailableCekProvider),
        app_data_dir.clone(),
    );

    // 模拟配置载荷（字段集最小化即可——降级分支只关心序列化落盘）
    let cfg = serde_json::json!({
        "protocol": "webdav",
        "endpoint": "http://127.0.0.1:8123",
        "path": "orbit",
    });

    // 无 CEK → 降级明文（不报错）
    store
        .save_with_plaintext_fallback("sync_config", &cfg)
        .expect("save fallback");

    let plaintext_path = app_data_dir.join("sync_config.json");
    assert!(
        plaintext_path.exists(),
        "明文 sync_config.json 应落盘：{}",
        plaintext_path.display()
    );
    let content = std::fs::read_to_string(&plaintext_path).expect("read plaintext");
    assert!(
        content.contains("http://127.0.0.1:8123"),
        "明文配置应含 endpoint"
    );
    assert!(
        !app_data_dir.join("sync_config.enc").exists(),
        "无 CEK 时不产出加密分支文件"
    );
}
