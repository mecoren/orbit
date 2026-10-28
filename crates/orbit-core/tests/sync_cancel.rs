//! sync_cancel.rs — N33 协作式取消的网络级证据
//!
//! 取消的粒度是「一片 / 一次远端调用」：适配器在每个远端调用前与分片循环
//! 每片前检查 `SyncCancelToken`，命中即停。本文件用零依赖内存假服务
//! （`tests/common`）证明三件事：
//!
//! 1. 令牌已取消时**一个请求都不发**（入口检查）；
//! 2. S3 大附件传一半取消 → 必须发起 `AbortMultipartUpload`，不得 `Complete`，
//!    云端不得留下对象；
//! 3. WebDAV 分片协议传一半取消 → 不得继续传后续分片，也不得写 `head.json`
//!    （清单是「完整」信号，缺了它就天然不可读，下轮 prepare 判定不可续传并
//!    整体清理）。
//!
//! 确定性来自假服务的 `slow_first_put_ms`：首片响应停在途，测试线程在窗口内
//! 取消，客户端返回后必然在下一片边界命中——不依赖轮询与睡眠竞速。

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use common::{FakeCloud, Protocol};
use orbit_core::crypto::sha256::sha256_hex;
use orbit_core::sync::cancel::SyncCancelToken;
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
    (0..len).map(|i| (i % 251) as u8).collect()
}

/// 已取消令牌必须在发起任何请求之前拦停上传（入口检查）
#[tokio::test]
async fn cancelled_token_blocks_upload_before_any_request() {
    for protocol in [Protocol::WebDav, Protocol::S3] {
        let cloud = FakeCloud::spawn(protocol);
        let config = match protocol {
            Protocol::WebDav => webdav_config(&cloud.base_url),
            Protocol::S3 => s3_config(&cloud.base_url),
        };
        let adapter = create_adapter(&config).unwrap();
        let token = Arc::new(SyncCancelToken::new());
        adapter.attach_cancel(token.clone());
        token.cancel();

        let dir = tempfile::TempDir::new().unwrap();
        let data = payload(9 * 1024 * 1024);
        let src = dir.path().join("big.bin");
        std::fs::write(&src, &data).unwrap();

        let err = adapter
            .upload_asset_file(&sha256_hex(&data), &src, data.len() as u64)
            .await
            .unwrap_err();
        assert!(err.is_cancelled(), "{protocol:?} 应为取消错误: {err}");
        assert!(
            cloud.requests().is_empty(),
            "{protocol:?} 已取消后不得发起任何请求: {:?}",
            cloud.requests()
        );
    }
}

/// S3：分片传一半取消 → AbortMultipartUpload 清理，不得 Complete / 落对象
#[tokio::test]
async fn s3_cancel_mid_multipart_aborts_session_without_object() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    // 首片响应停在途 400ms，给取消一个确定落点
    cloud.faults.slow_first_put_ms.store(400, Ordering::SeqCst);

    let adapter = create_adapter(&s3_config(&cloud.base_url)).unwrap();
    let token = Arc::new(SyncCancelToken::new());
    adapter.attach_cancel(token.clone());

    let dir = tempfile::TempDir::new().unwrap();
    // 12MiB = 3 片（5+5+2），取消落在第 2 片之前
    let data = payload(12 * 1024 * 1024);
    let src = dir.path().join("big.bin");
    std::fs::write(&src, &data).unwrap();

    let canceller = tokio::spawn({
        let faults = cloud.faults.clone();
        let token = token.clone();
        async move {
            // 等首片真正到达服务端（响应被扣住 400ms），此时取消必然落在
            // 「首片在途、下一片尚未开始」的窗口里，不靠睡眠竞速
            while faults.put_started.load(Ordering::SeqCst) == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            token.cancel();
        }
    });

    let err = adapter
        .upload_asset_file(&sha256_hex(&data), &src, data.len() as u64)
        .await
        .unwrap_err();
    canceller.await.unwrap();

    assert!(err.is_cancelled(), "应为取消错误: {err}");
    let requests = cloud.requests();
    assert!(
        requests
            .iter()
            .any(|r| r.starts_with("DELETE") && r.contains("uploadId=")),
        "取消必须发起 AbortMultipartUpload: {requests:?}"
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.starts_with("POST") && r.contains("uploadId=")),
        "取消后不得 Complete multipart: {requests:?}"
    );
    assert!(
        cloud.object_paths().is_empty(),
        "取消后云端不得留下对象: {:?}",
        cloud.object_paths()
    );
}

/// WebDAV：分片传一半取消 → 不传后续分片、不写 head.json（无「完整」信号）
#[tokio::test]
async fn webdav_cancel_mid_parts_stops_before_manifest() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    cloud.faults.slow_first_put_ms.store(400, Ordering::SeqCst);

    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();
    let token = Arc::new(SyncCancelToken::new());
    adapter.attach_cancel(token.clone());

    let dir = tempfile::TempDir::new().unwrap();
    // 9MiB = 2 片（5+4），取消落在第 2 片之前
    let data = payload(9 * 1024 * 1024);
    let src = dir.path().join("big.bin");
    std::fs::write(&src, &data).unwrap();

    let canceller = tokio::spawn({
        let faults = cloud.faults.clone();
        let token = token.clone();
        async move {
            while faults.put_started.load(Ordering::SeqCst) == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            token.cancel();
        }
    });

    let err = adapter
        .upload_asset_file(&sha256_hex(&data), &src, data.len() as u64)
        .await
        .unwrap_err();
    canceller.await.unwrap();

    assert!(err.is_cancelled(), "应为取消错误: {err}");
    let requests = cloud.requests();
    assert!(
        !requests
            .iter()
            .any(|r| r.contains("head.json") && !r.contains("404")),
        "取消后不得写 head.json（清单是完成信号）: {requests:?}"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.starts_with("PUT") && r.contains("000000.bin")),
        "首片应已上传（证明取消落在分片间而非入口）: {requests:?}"
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.starts_with("PUT") && r.contains("000001.bin")),
        "取消后不得继续上传后续分片: {requests:?}"
    );
}
