//! M3/T1.1：附件对象流式上传/下载的网络级证据（WebDAV / S3 各一组）
//!
//! 覆盖：
//! 1. 小附件（< 分片阈值）——`upload_asset_file` 单请求流式 PUT，
//!    `download_asset_to_file` 流式 GET 落盘，字节逐位一致；
//! 2. 大附件（≥ 8MiB）——WebDAV 走分片协议（片段从文件按块读、清单最后写），
//!    S3 走原生 multipart（片段从文件按块读），下载侧同样流式；
//! 3. 云端布局不变——对象键仍是 `{base_path}/assets/{hash}.orsync`，
//!    WebDAV 分片只在 `{base_path}/assets_parts/{hash}/` 下。
//!
//! 夹具是零依赖内存假服务（`tests/common`），干净机器上必须全绿。

mod common;

use common::{FakeCloud, Protocol};
use orbit_core::crypto::sha256::sha256_hex;
use orbit_core::sync::engine::{SyncConfig, create_adapter};

fn webdav_config(base_url: &str) -> SyncConfig {
    SyncConfig {
        adapter_type: "webdav".to_string(),
        endpoint: base_url.to_string(),
        bucket: String::new(),
        region: String::new(),
        access_key: "user".to_string(),
        secret_key: "pass".to_string(),
        base_path: "orbit".to_string(),
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
        base_path: "orbit".to_string(),
        device_id: "dev-1".to_string(),
        device_name: "测试设备".to_string(),
        timeout_secs: 10,
        skip_tls_verify: false,
        session_token: String::new(),
    }
}

fn payload(len: usize) -> Vec<u8> {
    // 非均匀内容：截断/错块会被逐位比较立刻抓到
    (0..len).map(|i| (i % 251) as u8).collect()
}

async fn upload_and_download(
    adapter: &dyn orbit_core::sync_adapters::traits::SyncAdapter,
    payload: &[u8],
) -> Vec<u8> {
    let dir = tempfile::TempDir::new().unwrap();
    let src = dir.path().join("asset.bin");
    std::fs::write(&src, payload).unwrap();
    let hash = sha256_hex(payload);
    let len = payload.len() as u64;

    adapter.upload_asset_file(&hash, &src, len).await.unwrap();

    let target = dir.path().join("restored.bin");
    let got = adapter
        .download_asset_to_file(&hash, &target)
        .await
        .unwrap();
    assert_eq!(got, len, "下载字节数必须等于对象长度");
    std::fs::read(&target).unwrap()
}

#[tokio::test]
async fn webdav_small_asset_streams_both_ways() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();
    let data = payload(1024 * 1024 + 3);
    let hash = sha256_hex(&data);

    let restored = upload_and_download(&*adapter, &data).await;
    assert_eq!(restored, data, "WebDAV 小附件必须逐位一致");

    let path = format!("assets/{hash}.orsync");
    assert_eq!(
        cloud.object_len(&format!("/{path}")),
        Some(data.len()),
        "对象键仍是 assets/{{hash}}.orsync（base_path 由引擎层包装）"
    );
    assert!(
        !cloud
            .object_paths()
            .iter()
            .any(|p| p.contains("assets_parts")),
        "低于分片阈值不得走分片协议"
    );
}

#[tokio::test]
async fn webdav_large_asset_uses_parts_from_file_and_reassembles() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();
    // 9MiB：跨过 8MiB 分片阈值（5MiB + 4MiB 两片）
    let data = payload(9 * 1024 * 1024);
    let hash = sha256_hex(&data);

    let restored = upload_and_download(&*adapter, &data).await;
    assert_eq!(restored, data, "分片拼装后必须逐位一致");

    let paths = cloud.object_paths();
    assert!(
        paths
            .iter()
            .any(|p| p == &format!("/assets_parts/{hash}/head.json")),
        "大附件必须写分片清单，实际对象: {paths:?}"
    );
    assert!(
        paths
            .iter()
            .any(|p| p == &format!("/assets_parts/{hash}/000000.bin")),
        "分片必须落在 assets_parts/{{hash}}/ 内，实际对象: {paths:?}"
    );
    assert!(
        !paths.iter().any(|p| p == &format!("/assets/{hash}.orsync")),
        "分片就位后不得残留同名单对象（读侧优先命中单对象）"
    );
    assert!(
        cloud.has_request_with("PUT /assets_parts/"),
        "必须观察到分片 PUT 请求，实际: {:?}",
        cloud.requests()
    );
}

#[tokio::test]
async fn s3_small_asset_streams_both_ways() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    let adapter = create_adapter(&s3_config(&cloud.base_url)).unwrap();
    let data = payload(1024 * 1024 + 7);
    let hash = sha256_hex(&data);

    let restored = upload_and_download(&*adapter, &data).await;
    assert_eq!(restored, data, "S3 小附件必须逐位一致");
    assert_eq!(
        cloud.object_len(&format!("/bucket/assets/{hash}.orsync")),
        Some(data.len())
    );
}

#[tokio::test]
async fn s3_large_asset_uses_multipart_from_file() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    let adapter = create_adapter(&s3_config(&cloud.base_url)).unwrap();
    // 9MiB：跨过 8MiB multipart 阈值（5MiB + 4MiB 两片）
    let data = payload(9 * 1024 * 1024);
    let hash = sha256_hex(&data);

    let restored = upload_and_download(&*adapter, &data).await;
    assert_eq!(restored, data, "multipart 拼装后必须逐位一致");
    assert_eq!(
        cloud.object_len(&format!("/bucket/assets/{hash}.orsync")),
        Some(data.len()),
        "Complete 后对象落在原键，布局与单 PUT 一致"
    );
    assert!(
        cloud.has_request_with("POST /bucket/assets/") && cloud.has_request_with("uploadId="),
        "必须观察到 Create/UploadPart/Complete 链路，实际: {:?}",
        cloud.requests()
    );
}
