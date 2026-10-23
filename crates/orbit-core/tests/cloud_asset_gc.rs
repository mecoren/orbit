//! docs/15：云端孤儿附件扫描与删除（WebDAV / S3 各一组）
//!
//! 判据与兜底见 `cloud_sync::asset_gc` 模块文档：
//! - 引用集只认云端 `tables/todo_task_attachments/` 桶里 `is_deleted = 0` 的行；
//! - 年龄窗口 + mtime 不可得跳过（宁可漏收，不误删）；
//! - 删除前复核清单 epoch，不一致一个对象都不删。
//!
//! 夹具为零依赖内存假服务（`tests/common`），干净机器必须全绿。

mod common;

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use common::{FakeCloud, Protocol};
use orbit_core::cloud_sync::asset_gc::{
    DEFAULT_CLOUD_ASSET_MIN_AGE_SECS, delete_cloud_assets, scan_cloud_orphan_assets,
};
use orbit_core::cloud_sync::meta::{ChunkRef, Manifest, TableIndex};
use orbit_core::cloud_sync::{ChunkPayload, encrypt_payload};
use orbit_core::sync::engine::{SyncConfig, create_adapter};

const KEY: [u8; 32] = [7u8; 32];
const DAY: i64 = 24 * 3600;
const EPOCH: u64 = 7;

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

/// 64 位 hex 的假 hash（内容寻址键必须是 sha256 形态才会进入清单）
fn fake_hash(ch: char) -> String {
    ch.to_string().repeat(64)
}

fn link_row(hash: &str, is_deleted: i64) -> serde_json::Value {
    serde_json::json!({
        "uuid": format!("link-{hash}"),
        "hash": hash,
        "is_deleted": is_deleted,
        "created_at": 1,
        "updated_at": 1,
        "version": 1,
    })
}

fn seal_manifest(manifest: &Manifest) -> Vec<u8> {
    let plain = serde_json::to_vec(manifest).expect("清单序列化");
    encrypt_payload(&plain, &KEY).expect("清单加密")
}

fn seal_bucket(table: &str, bucket: u32, items: Vec<serde_json::Value>) -> Vec<u8> {
    let payload = ChunkPayload {
        table: table.to_string(),
        bucket,
        items,
    };
    let plain = serde_json::to_vec(&payload).expect("分桶序列化");
    encrypt_payload(&plain, &KEY).expect("分桶加密")
}

/// 清单只索引 `todo_task_attachments` 的 0 号桶
fn manifest_with_link_bucket(count: u64) -> Manifest {
    let mut chunks = BTreeMap::new();
    chunks.insert(
        0u32,
        ChunkRef {
            fp: "fp".to_string(),
            count,
            size: 1,
        },
    );
    let mut manifest = Manifest::empty("dev-1");
    manifest.epoch = EPOCH;
    manifest
        .tables
        .insert("todo_task_attachments".to_string(), TableIndex { chunks });
    manifest
}

/// 双协议共用断言（`prefix` 是假服务的对象键前缀：WebDAV 空、S3 `/{bucket}/`）
async fn assert_scan_and_delete(cloud: &FakeCloud, config: &SyncConfig, prefix: &str) {
    let adapter = create_adapter(config).expect("构造适配器");
    let now = now_secs();
    let old = now - DEFAULT_CLOUD_ASSET_MIN_AGE_SECS - DAY;

    let referenced = fake_hash('a');
    let tombstoned = fake_hash('b');
    let orphan_whole = fake_hash('c');
    let orphan_chunked = fake_hash('d');
    let fresh = fake_hash('e');
    let no_mtime = fake_hash('f');

    // 引用桶：a 存活、b 已删（墓碑行不构成引用）
    let bucket = seal_bucket(
        "todo_task_attachments",
        0,
        vec![link_row(&referenced, 0), link_row(&tombstoned, 1)],
    );
    cloud.put_object_at(
        &format!("{prefix}tables/todo_task_attachments/00.orsync"),
        &bucket,
        now,
    );

    // 清单（epoch = EPOCH）
    cloud.put_object_at(
        &format!("{prefix}manifest.orsync"),
        &seal_manifest(&manifest_with_link_bucket(2)),
        now,
    );

    // 整包对象：引用中 / 墓碑态 / 孤儿（旧） / 刚写入 / mtime 不可得
    cloud.put_object_at(
        &format!("{prefix}assets/{referenced}.orsync"),
        b"referenced",
        old,
    );
    cloud.put_object_at(&format!("{prefix}assets/{tombstoned}.orsync"), b"tomb", old);
    cloud.put_object_at(
        &format!("{prefix}assets/{orphan_whole}.orsync"),
        b"orphan",
        old,
    );
    cloud.put_object_at(&format!("{prefix}assets/{fresh}.orsync"), b"fresh", now);
    cloud.put_object_at(&format!("{prefix}assets/{no_mtime}.orsync"), b"no-mtime", 0);

    // 分片孤儿：head.json + 一个数据片（目录 mtime 取子项 mtime = old）
    cloud.put_object_at(
        &format!("{prefix}assets_parts/{orphan_chunked}/head.json"),
        b"{}",
        old,
    );
    cloud.put_object_at(
        &format!("{prefix}assets_parts/{orphan_chunked}/000000.bin"),
        b"part",
        old,
    );

    // 1) 扫描：只认「云端无引用 + 足够旧 + mtime 可得」
    let manifest = manifest_with_link_bucket(2);
    let orphans = scan_cloud_orphan_assets(
        &*adapter,
        &KEY,
        &manifest,
        DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .expect("扫描必须成功");
    let hashes: Vec<&str> = orphans.iter().map(|o| o.hash.as_str()).collect();
    assert!(
        hashes.contains(&tombstoned.as_str()),
        "墓碑行的对象不再被引用，足够旧 → 应判孤儿；实际 {hashes:?}"
    );
    assert!(hashes.contains(&orphan_whole.as_str()));
    assert!(
        hashes.contains(&orphan_chunked.as_str()),
        "分片形态同样要判孤儿（WebDAV 并集 assets_parts/）"
    );
    assert!(
        !hashes.contains(&referenced.as_str()),
        "云端仍被引用的附件不得进入清理清单"
    );
    assert!(
        !hashes.contains(&fresh.as_str()),
        "年龄窗口内的对象必须留给下一轮"
    );
    assert!(
        !hashes.contains(&no_mtime.as_str()),
        "服务端不提供 mtime 时一律跳过（宁可漏收，不误删）"
    );

    // 2) 删除：引用中的 hash 在复核阶段被跳过
    let deleted = delete_cloud_assets(
        &*adapter,
        &KEY,
        EPOCH,
        &[
            orphan_whole.clone(),
            orphan_chunked.clone(),
            referenced.clone(),
        ],
        DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .expect("删除必须成功");
    assert!(!deleted.stale_manifest);
    assert_eq!(deleted.skipped_referenced, 1, "引用中的 hash 必须跳过");
    assert_eq!(deleted.deleted_assets, 2);
    assert!(
        deleted.errors.is_empty(),
        "删除不应有错误: {:?}",
        deleted.errors
    );
    assert_eq!(
        cloud.object_len(&format!("{prefix}assets/{orphan_whole}.orsync")),
        None,
        "整包孤儿必须被物理删除"
    );
    assert_eq!(
        cloud.object_len(&format!("{prefix}assets_parts/{orphan_chunked}/head.json")),
        None,
        "分片清单 head.json 必须被删除"
    );
    assert_eq!(
        cloud.object_len(&format!("{prefix}assets_parts/{orphan_chunked}/000000.bin")),
        None,
        "分片数据必须被删除"
    );
    assert!(
        cloud
            .object_len(&format!("{prefix}assets/{referenced}.orsync"))
            .is_some(),
        "引用中的附件对象不得删除"
    );

    // 3) 幂等：再删一轮已消失的 hash 不报错
    let again = delete_cloud_assets(
        &*adapter,
        &KEY,
        EPOCH,
        &[orphan_whole.clone()],
        DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .expect("幂等重跑必须成功");
    assert_eq!(again.deleted_assets, 1, "已不存在的 hash 按幂等计为已处理");
    assert!(again.errors.is_empty());

    // 4) epoch 复核：扫描后他端 push 过（epoch 变了）→ 一个对象都不删
    let stale = delete_cloud_assets(
        &*adapter,
        &KEY,
        EPOCH - 1,
        &[tombstoned.clone()],
        DEFAULT_CLOUD_ASSET_MIN_AGE_SECS,
        now,
    )
    .await
    .expect("复核路径不报错");
    assert!(stale.stale_manifest, "epoch 不一致必须拒绝执行");
    assert_eq!(stale.deleted_assets, 0);
    assert!(
        cloud
            .object_len(&format!("{prefix}assets/{tombstoned}.orsync"))
            .is_some(),
        "拒绝执行时不得删任何对象"
    );
}

#[tokio::test]
async fn webdav_reclaims_only_cloud_orphan_assets() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let config = webdav_config(&cloud.base_url);
    // WebDAV 假服务按请求路径（带前导 `/`）精确匹配对象键
    assert_scan_and_delete(&cloud, &config, "/").await;
}

#[tokio::test]
async fn s3_reclaims_only_cloud_orphan_assets() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    let config = s3_config(&cloud.base_url);
    assert_scan_and_delete(&cloud, &config, "/bucket/").await;
}
