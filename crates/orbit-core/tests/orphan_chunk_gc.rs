//! T1.3：云端孤儿分桶扫描与物理回收（WebDAV / S3 各一组）
//!
//! 判据与顺序约束见 `cloud_sync::gc` 模块文档：
//! - 清单无引用的 `tables/{table}/{bucket}.orsync` 才是孤儿；
//! - 对象 mtime 必须早于最小保留窗口（防删其他设备刚上传、清单未落定的新桶）；
//! - 服务端不提供 mtime 时跳过（宁可漏收，不误删）。
//!
//! 夹具为零依赖内存假服务，干净机器必须全绿。

mod common;

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use common::{FakeCloud, Protocol};
use orbit_core::cloud_sync::gc::{collect_and_delete_orphan_chunks, scan_orphan_chunks};
use orbit_core::cloud_sync::meta::{ChunkRef, Manifest, TableIndex};
use orbit_core::sync::engine::{SyncConfig, create_adapter};

const DAY: i64 = 24 * 3600;

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn webdav_config(base_url: &str) -> SyncConfig {
    SyncConfig {
        adapter_type: "webdav".to_string(),
        endpoint: base_url.to_string(),
        bucket: String::new(),
        region: String::new(),
        access_key: "user".to_string(),
        secret_key: "pass".to_string(),
        base_path: String::new(),
        device_id: "dev-1".to_string(),
        device_name: "测试设备".to_string(),
        timeout_secs: 10,
        skip_tls_verify: false,
        session_token: String::new(),
    }
}

fn s3_config(base_url: &str) -> SyncConfig {
    SyncConfig {
        adapter_type: "s3".to_string(),
        endpoint: base_url.to_string(),
        bucket: "bucket".to_string(),
        region: "us-east-1".to_string(),
        access_key: "AK".to_string(),
        secret_key: "SK".to_string(),
        base_path: String::new(),
        device_id: "dev-1".to_string(),
        device_name: "测试设备".to_string(),
        timeout_secs: 10,
        skip_tls_verify: false,
        session_token: String::new(),
    }
}

/// 清单只引用 `todo_tasks` 的 1 号桶
fn manifest_referencing_bucket_one() -> Manifest {
    let mut chunks = BTreeMap::new();
    chunks.insert(
        1u32,
        ChunkRef {
            fp: "fp".to_string(),
            count: 1,
            size: 1,
        },
    );
    let mut manifest = Manifest::empty("dev-1");
    manifest
        .tables
        .insert("todo_tasks".to_string(), TableIndex { chunks });
    manifest
}

async fn assert_reclaims_only_stale_orphans(
    cloud: &FakeCloud,
    object_prefix: &str,
    config: &SyncConfig,
) {
    let adapter = create_adapter(config).unwrap();
    let manifest = manifest_referencing_bucket_one();
    let now = now_secs();

    // 00：孤儿且足够旧 → 回收；01：清单引用 → 保留；02：孤儿但刚写入 → 保留
    cloud.put_object_at(
        &format!("{object_prefix}/tables/todo_tasks/00.orsync"),
        b"orphan-old",
        1_700_000_000,
    );
    cloud.put_object_at(
        &format!("{object_prefix}/tables/todo_tasks/01.orsync"),
        b"referenced",
        1_700_000_000,
    );
    cloud.put_object_at(
        &format!("{object_prefix}/tables/todo_tasks/02.orsync"),
        b"orphan-fresh",
        now,
    );

    let candidates = scan_orphan_chunks(&*adapter, &manifest, DAY, now)
        .await
        .unwrap();
    assert_eq!(
        candidates,
        vec![("todo_tasks".to_string(), 0u32)],
        "只应命中「清单无引用 + 足够旧」的 0 号桶"
    );

    let result = collect_and_delete_orphan_chunks(&*adapter, &manifest, DAY)
        .await
        .unwrap();
    assert_eq!(result.deleted_buckets, 1);
    assert!(
        result.errors.is_empty(),
        "回收不应有错误: {:?}",
        result.errors
    );

    assert_eq!(
        cloud.object_len(&format!("{object_prefix}/tables/todo_tasks/00.orsync")),
        None,
        "孤儿桶对象必须被物理删除"
    );
    assert!(
        cloud
            .object_len(&format!("{object_prefix}/tables/todo_tasks/01.orsync"))
            .is_some(),
        "清单引用的桶不得删除"
    );
    assert!(
        cloud
            .object_len(&format!("{object_prefix}/tables/todo_tasks/02.orsync"))
            .is_some(),
        "刚写入的孤儿桶必须留给下一轮（防删上传中的对象）"
    );
}

#[tokio::test]
async fn webdav_reclaims_stale_orphan_chunks_only() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let config = webdav_config(&cloud.base_url);
    assert_reclaims_only_stale_orphans(&cloud, "", &config).await;
}

#[tokio::test]
async fn s3_reclaims_stale_orphan_chunks_only() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    let config = s3_config(&cloud.base_url);
    assert_reclaims_only_stale_orphans(&cloud, "/bucket", &config).await;
}
