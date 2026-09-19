//! 云同步稳定性矩阵（第五轮探查 Wave 5 / F25）
//!
//! 用 `tests/common` 的零依赖假服务把 S3 与 WebDAV 的线上行为变成可控夹具：
//! 四类操作（上传/下载/更新/删除）× 七种故障（5xx、限流、半截体、停滞、
//! 列举截断、412 冲突、忽略条件头）。取代原先依赖本机 8123 端口真 WebDAV 的
//! 环境敏感用例——干净机器上 `cargo test --workspace` 必须全绿。
//!
//! 重点是 `cas_conditional_headers_reach_the_wire_*`：清单乐观锁此前在生产链路
//! 从未发出过条件头（F22），单元测试因 mock 比生产实现更强而长期假绿，
//! 这里是它唯一的网络级证据。

mod common;

use std::path::PathBuf;
use std::sync::atomic::Ordering;

use common::{FAKE_BUCKET, FakeCloud, Protocol};
use orbit_core::api::cloud_sync_api;
use orbit_core::cloud_sync::engine::SyncEngine;
use orbit_core::cloud_sync::progress::SyncOrigin;
use orbit_core::context;
use orbit_core::sync::engine::SyncConfig;
use orbit_core::sync_crypto::SyncCryptoService;
use sqlx::SqlitePool;

const PASSWORD: &str = "matrix-sync-pass-123456";
const BASE_PATH: &str = "orbit-matrix";

fn webdav_config(cloud: &FakeCloud, device: &str) -> SyncConfig {
    SyncConfig {
        adapter_type: "webdav".into(),
        endpoint: cloud.base_url.clone(),
        bucket: String::new(),
        region: String::new(),
        access_key: "matrix".into(),
        secret_key: "matrix-pass".into(),
        base_path: BASE_PATH.into(),
        device_id: device.into(),
        device_name: device.into(),
        timeout_secs: 15,
        skip_tls_verify: false,
    }
}

fn s3_config(cloud: &FakeCloud, device: &str) -> SyncConfig {
    SyncConfig {
        adapter_type: "s3".into(),
        timeout_secs: 15,
        bucket: FAKE_BUCKET.into(),
        region: "us-east-1".into(),
        ..webdav_config(cloud, device)
    }
}

/// 一台「设备」：临时数据目录 + 明文测试库 + 迁移 + 引擎 + 同步配置
struct Node {
    _tmp: tempfile::TempDir,
    dir: PathBuf,
    pool: SqlitePool,
    engine: SyncEngine,
    cfg: SyncConfig,
}

impl Node {
    async fn new(tag: &str, cfg: SyncConfig) -> Self {
        context::set_device_id(tag.to_string()).ok();
        let tmp = tempfile::tempdir().expect("tempdir");
        let dir = tmp.path().to_path_buf();
        let pool = orbit_core::db::pool::init_pool_unencrypted(&dir.join("orbit.db"))
            .await
            .expect("建池");
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .expect("迁移");
        let crypto = SyncCryptoService::new(&dir);
        crypto.init(PASSWORD).expect("init crypto");
        let engine = cloud_sync_api::create_engine_noop(pool.clone(), crypto, &dir);
        engine.set_sync_password(PASSWORD.to_string());
        Self {
            _tmp: tmp,
            dir,
            pool,
            engine,
            cfg,
        }
    }

    fn attachments_dir(&self) -> String {
        self.dir.join("attachments").to_str().unwrap().to_string()
    }

    /// 完整同步轮（pull → push，与启动页同口径）
    async fn sync(&self) -> orbit_core::cloud_sync::engine::SyncResult {
        self.try_sync().await.expect("同步轮不得外抛")
    }

    /// 同上，但把引擎外抛的错误交给调用方判定（限流这类致命分类要能断言）
    async fn try_sync(
        &self,
    ) -> Result<
        orbit_core::cloud_sync::engine::SyncResult,
        orbit_core::cloud_sync::error::CloudSyncError,
    > {
        cloud_sync_api::pull_then_push(
            &self.engine,
            &self.cfg,
            SyncOrigin::Manual,
            &self.cfg.device_id,
            &self.attachments_dir(),
        )
        .await
    }

    async fn seed(&self, uuid: &str, title: &str) {
        // 时间戳走逻辑时钟（与生产写路径同口径，F41 水位线判据的前提）
        let now = orbit_core::db::clock::next_ms();
        sqlx::query(
            "INSERT INTO todo_tasks (uuid, title, status, done, position, created_at, updated_at, version) \
             VALUES (?, ?, 'pending', 0, 1, ?, ?, 1)",
        )
        .bind(uuid)
        .bind(title)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await
        .expect("seed task");
    }

    async fn edit(&self, uuid: &str, title: &str) {
        sqlx::query("UPDATE todo_tasks SET title=?, version=version+1, updated_at=? WHERE uuid=?")
            .bind(title)
            .bind(orbit_core::db::clock::next_ms())
            .bind(uuid)
            .execute(&self.pool)
            .await
            .expect("edit task");
    }

    /// 登记本地附件记录（内容寻址：文件名即 sha256）
    ///
    /// `cached=true` 把二进制落到 `attachments_dir/{hash}`（待上传态）；
    /// `false` 是 LRU 逐出后的「有记录、本地无二进制」态（待下载态）。
    /// 只动 `sys_attachments`：跨设备搬运关联行的坑另见 F47，本用例刻意绕开。
    async fn register_asset(&self, hash: &str, bytes: &[u8], cached: bool) {
        if cached {
            let dir = self.dir.join("attachments");
            std::fs::create_dir_all(&dir).expect("附件目录");
            std::fs::write(dir.join(hash), bytes).expect("写附件文件");
        }
        let now = orbit_core::db::clock::next_ms();
        sqlx::query(
            "INSERT INTO sys_attachments (hash, original_name, mime_type, size_bytes, local_path, \
             is_uploaded, is_local_cached, created_at, last_accessed_at) \
             VALUES (?, ?, 'application/octet-stream', ?, NULL, 0, ?, ?, ?)",
        )
        .bind(hash)
        .bind(format!("{hash}.bin"))
        .bind(bytes.len() as i64)
        .bind(cached as i64)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await
        .expect("登记附件");
    }

    /// 把附件挂到**本地**存活任务上（pull 侧 S31 活跃引用过滤的依据）
    async fn link_asset(&self, hash: &str, task_uuid: &str) {
        let now = orbit_core::db::clock::next_ms();
        let (task_id,): (i64,) = sqlx::query_as("SELECT id FROM todo_tasks WHERE uuid=?")
            .bind(task_uuid)
            .fetch_one(&self.pool)
            .await
            .expect("任务存在");
        sqlx::query(
            "INSERT INTO todo_task_attachments (uuid, task_id, hash, is_deleted, created_at, \
             updated_at, version) VALUES (?, ?, ?, 0, ?, ?, 1)",
        )
        .bind(format!("link-{task_uuid}-{hash}"))
        .bind(task_id)
        .bind(hash)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await
        .expect("挂载附件");
    }

    /// 软删（墓碑语义，同步链路的删除全靠它）
    async fn soft_delete(&self, uuid: &str) {
        let now = orbit_core::db::clock::next_ms();
        sqlx::query(
            "UPDATE todo_tasks SET is_deleted=1, deleted_at=?, version=version+1 WHERE uuid=?",
        )
        .bind(now)
        .bind(uuid)
        .execute(&self.pool)
        .await
        .expect("soft delete");
    }

    async fn title(&self, uuid: &str) -> Option<String> {
        sqlx::query_as::<_, (String,)>("SELECT title FROM todo_tasks WHERE uuid=? AND is_deleted=0")
            .bind(uuid)
            .fetch_optional(&self.pool)
            .await
            .expect("query title")
            .map(|t| t.0)
    }
}

/// 四类操作一轮跑通：上传→下载收敛→更新→删除不复活
async fn four_ops_converge(protocol: Protocol) {
    let cloud = FakeCloud::spawn(protocol);
    let cfg = |dev: &str| match protocol {
        Protocol::WebDav => webdav_config(&cloud, dev),
        Protocol::S3 => s3_config(&cloud, dev),
    };
    let a = Node::new("node-a", cfg("device-a")).await;
    let b = Node::new("node-b", cfg("device-b")).await;

    // 上传 + 下载
    a.seed("m-1", "矩阵任务").await;
    let r1 = a.sync().await;
    assert!(r1.errors.is_empty(), "干净轮次不得有错: {:?}", r1.errors);
    assert!(r1.pushed_modules > 0, "A 应推桶: {r1:?}");
    let r2 = b.sync().await;
    assert!(r2.pulled_modules > 0, "B 应拉桶: {r2:?}");
    assert_eq!(b.title("m-1").await.as_deref(), Some("矩阵任务"));

    // 更新（B 改 → A 收敛）
    b.edit("m-1", "矩阵任务-已编辑").await;
    b.sync().await;
    a.sync().await;
    assert_eq!(a.title("m-1").await.as_deref(), Some("矩阵任务-已编辑"));

    // 删除（A 软删 → B 收敛且不复活）
    a.soft_delete("m-1").await;
    a.sync().await;
    let rb = b.sync().await;
    assert!(rb.errors.is_empty(), "删除轮不得有错: {:?}", rb.errors);
    assert_eq!(b.title("m-1").await, None, "删除应以墓碑语义收敛");

    // 第二轮零重传：指纹相等 → 不重复上传（增量语义的线上证据）
    let again = a.sync().await;
    assert_eq!(
        again.pushed_modules, 0,
        "无本地变更的第二轮不应重推桶: {again:?}"
    );
}

#[tokio::test]
async fn webdav_four_ops_converge() {
    four_ops_converge(Protocol::WebDav).await;
}

#[tokio::test]
async fn s3_four_ops_converge() {
    four_ops_converge(Protocol::S3).await;
}

/// F22 的网络级证据：条件头真的出现在线上，注入 412 后走 CAS 重试并收敛
async fn cas_conditional_headers_reach_the_wire(protocol: Protocol) {
    let cloud = FakeCloud::spawn(protocol);
    let cfg = |dev: &str| match protocol {
        Protocol::WebDav => webdav_config(&cloud, dev),
        Protocol::S3 => s3_config(&cloud, dev),
    };
    let a = Node::new("cas-a", cfg("cas-a")).await;
    let b = Node::new("cas-b", cfg("cas-b")).await;
    a.seed("cas-1", "冲突任务").await;
    a.sync().await;

    // 首写之后的清单更新必须带 If-Match；首次创建带 If-None-Match: *
    assert!(
        cloud.has_request_with("if-none-match=*"),
        "清单首写应发 If-None-Match: *，实际: {:?}",
        cloud.requests()
    );

    // 对端抢先改云端清单 → 本方 If-Match 失配 → 412 → 重读清单再推
    b.sync().await;
    cloud.faults.conflict.store(1, Ordering::SeqCst);
    b.edit("cas-1", "冲突任务-改").await;
    let r = b.sync().await;
    assert!(
        cloud.has_request_with("if-match="),
        "清单更新应发 If-Match，实际: {:?}",
        cloud.requests()
    );
    assert!(r.errors.is_empty(), "412 应由 CAS 重试消化: {:?}", r.errors);
    a.sync().await;
    assert_eq!(a.title("cas-1").await.as_deref(), Some("冲突任务-改"));
}

#[tokio::test]
async fn cas_conditional_headers_reach_the_wire_webdav() {
    cas_conditional_headers_reach_the_wire(Protocol::WebDav).await;
}

#[tokio::test]
async fn cas_conditional_headers_reach_the_wire_s3() {
    cas_conditional_headers_reach_the_wire(Protocol::S3).await;
}

/// 忽略条件头的兼容服务：不得报错，数据为最后写入方（写后回读兜底的已知上限）
#[tokio::test]
async fn ignore_conditional_server_still_converges() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    cloud
        .faults
        .ignore_conditional
        .store(true, Ordering::SeqCst);
    let a = Node::new("ign-a", webdav_config(&cloud, "ign-a")).await;
    let b = Node::new("ign-b", webdav_config(&cloud, "ign-b")).await;
    a.seed("ign-1", "无条件头服务").await;
    a.sync().await;
    b.sync().await;
    assert_eq!(b.title("ign-1").await.as_deref(), Some("无条件头服务"));
}

/// 5xx 与限流：可重试故障自愈，不可消化的那类必须留下错误且**不推进账本**
/// （F24 的端到端口径：`last_synced_at` 是回收站物理清理的守卫线）
#[tokio::test]
async fn transient_faults_either_recover_or_report_and_never_advance_ledger() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let cfg = webdav_config(&cloud, "flt-a");
    let a = Node::new("flt-a", cfg).await;
    a.seed("flt-1", "故障任务").await;
    a.sync().await;

    // 瞬态：先回 2 次 5xx，重试后应收敛
    cloud.faults.flaky.store(2, Ordering::SeqCst);
    a.edit("flt-1", "故障任务-1").await;
    let r = a.sync().await;
    assert_eq!(
        cloud.faults.flaky.load(Ordering::SeqCst),
        0,
        "故障额度应被耗尽"
    );
    assert!(r.errors.is_empty(), "2 次 5xx 后重试成功: {:?}", r.errors);

    // 持续限流：耗尽 HTTP 与业务两层重试 → 引擎按类型化错误外抛，账本必须不动
    // （额度取 8：够打穿两层重试又不至于让退避把用例拖到分钟级）
    insert_active_config(&a.pool).await;
    let ledger = ledger_of(&a.pool).await;
    assert!(ledger.is_none(), "起点：从未同步过");
    cloud.faults.rate_limited.store(8, Ordering::SeqCst);
    a.edit("flt-1", "故障任务-2").await;
    let r2 = a.try_sync().await;
    cloud.faults.rate_limited.store(0, Ordering::SeqCst);
    match r2 {
        Err(e) => assert!(
            matches!(
                e,
                orbit_core::cloud_sync::error::CloudSyncError::RateLimited { .. }
            ),
            "限流要保留类型化分类而非塌成通用错误: {e:?}"
        ),
        Ok(r) => assert!(!r.advances_ledger(), "限流轮次不得算干净: {r:?}"),
    }
    assert_eq!(
        ledger_of(&a.pool).await,
        ledger,
        "未推送成功的轮次不得推进 last_synced_at"
    );

    // 恢复后的干净轮次才放行账本
    let r3 = a.sync().await;
    assert!(r3.advances_ledger(), "恢复后应干净: {:?}", r3.errors);
    assert!(ledger_of(&a.pool).await.is_some());
}

/// 半截响应体与停滞连接：传输层错误不得被当成成功，本地数据不得被截断体污染
#[tokio::test]
async fn truncated_and_stalled_bodies_are_not_accepted() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let a = Node::new("tr-a", webdav_config(&cloud, "tr-a")).await;
    let b = Node::new("tr-b", webdav_config(&cloud, "tr-b")).await;
    a.seed("tr-1", "截断任务").await;
    a.sync().await;

    // 声明完整长度只写一半：Content-Length 不符 → 读失败 → 重试后收敛，数据仍正确
    cloud.faults.drop_mid_body.store(1, Ordering::SeqCst);
    let r = b.sync().await;
    assert_eq!(
        cloud.faults.drop_mid_body.load(Ordering::SeqCst),
        0,
        "半截体故障应被命中"
    );
    assert_eq!(
        b.title("tr-1").await.as_deref(),
        Some("截断任务"),
        "重试后必须收敛: {:?}",
        r.errors
    );

    // 真停滞：1s 读超时掐断（超时线见 HttpClient read_timeout）
    let mut stalled = webdav_config(&cloud, "tr-c");
    stalled.timeout_secs = 1;
    let c = Node::new("tr-c", stalled).await;
    cloud.faults.stall.store(1, Ordering::SeqCst);
    c.sync().await;
    assert_eq!(
        cloud.faults.stall.load(Ordering::SeqCst),
        0,
        "停滞应被触发一次"
    );
}

/// 列举 XML 中途截断：解析失败必须报错，不得当成「云端为空」清空本地
#[tokio::test]
async fn short_list_response_is_not_read_as_empty_cloud() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let a = Node::new("sl-a", webdav_config(&cloud, "sl-a")).await;
    a.seed("sl-1", "截断列举").await;
    a.sync().await;

    let b = Node::new("sl-b", webdav_config(&cloud, "sl-b")).await;
    b.seed("sl-2", "本地独有").await;
    cloud.faults.short_list.store(1, Ordering::SeqCst);
    let r = b.sync().await;
    assert_eq!(
        cloud.faults.short_list.load(Ordering::SeqCst),
        0,
        "截断故障应被命中"
    );
    assert!(
        !r.advances_ledger() || b.title("sl-2").await.is_some(),
        "截断列举要么报错、要么不得清空本地: {r:?}"
    );
    assert_eq!(
        b.title("sl-2").await.as_deref(),
        Some("本地独有"),
        "本地独有行必须还在"
    );
}

/// 生成不可压缩载荷：zstd-3 压不动才越得过 8MiB 分片阈值
/// （`vec![0u8; n]` 会被压成几百字节，用例会静默走单 PUT 而测不到分片协议）
fn incompressible(len: usize) -> Vec<u8> {
    let mut x: u64 = 0x243f_6a88_85a3_08d3;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

/// 验收判据 4 / F23：>8MiB 附件在 WebDAV 上真的走分片协议，
/// 分片落在 `{base_path}/assets_parts/` 之内，且「云端已有」判定看得见分片附件
#[tokio::test]
async fn webdav_large_asset_uses_chunked_parts_protocol() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let payload = incompressible(9 * 1024 * 1024);
    let hash = orbit_core::crypto::sha256::sha256_hex(&payload);

    let a = Node::new("big-a", webdav_config(&cloud, "big-a")).await;
    a.seed("big-0", "占位任务").await;
    a.register_asset(&hash, &payload, true).await;
    let r = a.sync().await;
    assert!(r.errors.is_empty(), "大附件轮不得有错: {:?}", r.errors);

    // 假服务的对象键即 URL 路径，带前导斜杠
    let parts_prefix = format!("/{BASE_PATH}/assets_parts/{hash}/");
    let paths = cloud.object_paths();
    assert!(
        paths
            .iter()
            .any(|p| p == &format!("{parts_prefix}head.json")),
        "分片清单必须落在 base_path 之内，实际: {paths:?}"
    );
    let bins: Vec<&String> = paths
        .iter()
        .filter(|p| p.starts_with(&parts_prefix) && p.ends_with(".bin"))
        .collect();
    assert!(
        bins.len() >= 2,
        "9MiB 按 5MiB 切片应有 ≥2 片，实际: {bins:?}"
    );
    assert!(
        cloud.has_request_with(&format!("PUT {parts_prefix}")),
        "分片必须经线上 PUT，实际: {:?}",
        cloud.requests()
    );
    assert!(
        !paths
            .iter()
            .any(|p| p.starts_with(&format!("/{BASE_PATH}/assets/{hash}"))),
        "走分片就不该再单 PUT 整对象: {paths:?}"
    );

    // 第二轮零重传：另一台设备本地已有同一附件（未上传标记）。列举须把分片附件
    // 认作「云端已存在」，否则每轮全量重传 9MiB（F23 的原始后果）
    let b = Node::new("big-b", webdav_config(&cloud, "big-b")).await;
    b.register_asset(&hash, &payload, true).await;
    let puts_before = cloud
        .requests()
        .iter()
        .filter(|r| r.starts_with(&format!("PUT {parts_prefix}")))
        .count();
    let rb = b.sync().await;
    assert!(rb.errors.is_empty(), "零重传轮不得有错: {:?}", rb.errors);
    assert_eq!(
        cloud
            .requests()
            .iter()
            .filter(|r| r.starts_with(&format!("PUT {parts_prefix}")))
            .count(),
        puts_before,
        "云端已有分片附件，不得重传"
    );
    let uploaded: (i64,) = sqlx::query_as("SELECT is_uploaded FROM sys_attachments WHERE hash=?")
        .bind(&hash)
        .fetch_one(&b.pool)
        .await
        .expect("读上传标记");
    assert_eq!(uploaded.0, 1, "云端已存在时要修正本地标记");
}

/// F23 的另一半：分片下载的 GET 也得带 base_path 前缀
///
/// 场景是 LRU 逐出后的真实态——`sys_attachments` 有记录、本地无二进制、
/// 任务仍挂载（S31 活跃引用过滤放行）。
#[tokio::test]
async fn webdav_chunked_asset_downloads_on_fresh_device() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let payload = incompressible(9 * 1024 * 1024);
    let hash = orbit_core::crypto::sha256::sha256_hex(&payload);

    let a = Node::new("dl-a", webdav_config(&cloud, "dl-a")).await;
    a.seed("dl-0", "占位任务").await;
    a.register_asset(&hash, &payload, true).await;
    a.sync().await;

    let b = Node::new("dl-b", webdav_config(&cloud, "dl-b")).await;
    b.seed("dl-1", "逐出后重下").await;
    b.register_asset(&hash, &payload, false).await;
    b.link_asset(&hash, "dl-1").await;
    let rb = b.sync().await;
    assert!(rb.errors.is_empty(), "分片下载轮不得有错: {:?}", rb.errors);
    let got = std::fs::read(b.dir.join("attachments").join(&hash)).expect("附件落盘");
    assert_eq!(got.len(), payload.len(), "拼装字节数必须与原文一致");
    assert_eq!(
        orbit_core::crypto::sha256::sha256_hex(&got),
        hash,
        "内容寻址校验"
    );
}

async fn insert_active_config(pool: &SqlitePool) {
    sqlx::query(
        "INSERT INTO sync_configs (protocol, endpoint, bucket, region, path, device_id, \
         credential, is_active, last_synced_at, created_at, updated_at) \
         VALUES ('webdav', 'http://127.0.0.1', '', '', ?, 'flt-a', '', 1, NULL, 1, 1)",
    )
    .bind(BASE_PATH)
    .execute(pool)
    .await
    .expect("插入激活配置（列名随迁移漂移必须立刻暴露）");
}

async fn ledger_of(pool: &SqlitePool) -> Option<i64> {
    sqlx::query_as::<_, (Option<i64>,)>(
        "SELECT last_synced_at FROM sync_configs WHERE is_active = 1",
    )
    .fetch_optional(pool)
    .await
    .expect("读账本")
    .map(|r| r.0)
    .unwrap_or(None)
}
