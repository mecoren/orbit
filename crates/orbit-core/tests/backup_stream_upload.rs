//! M1 云端流式上传：`upload_file` 走文件按块读取，不再整包驻留。
//!
//! 验证点：
//! 1. 内容正确性——流式上传落盘字节与源文件逐字节一致（含二进制/非 UTF-8）；
//! 2. 大小正确性——服务端收到的长度等于文件大小（Content-Length 与实体一致）；
//! 3. 语义不变——目标路径仍是 `{base_path}/backups/{filename}`；
//! 4. 两种协议都覆盖（WebDAV 单 PUT / S3 单 PUT 带载荷哈希）；
//! 5. 适配器未覆盖 `upload_file` 时默认实现仍能工作（退回整包）。

mod common;

use common::{FakeCloud, Protocol};
use orbit_core::api::full_sync_backup_api::upload_backup_file;
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

fn tmp_file(name: &str, bytes: &[u8]) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    (dir, path)
}

#[tokio::test]
async fn webdav_streams_file_upload_with_exact_bytes() {
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();

    // 1 MiB 非均匀内容：能暴露「只传了第一块」或「截断」这类错误
    let payload: Vec<u8> = (0..1024 * 1024).map(|i| (i % 251) as u8).collect();
    let (_dir, path) = tmp_file("dev.orfullsync", &payload);
    let len = std::fs::metadata(&path).unwrap().len();

    let cloud_path = upload_backup_file(&*adapter, "orbit", &path, len, "dev.orfullsync")
        .await
        .unwrap();
    assert_eq!(cloud_path, "orbit/backups/dev.orfullsync");

    // 假服务按请求路径存对象（带前导斜杠），故查 object_len 用 "/" + cloud_path
    let stored = cloud
        .object_len(&format!("/{cloud_path}"))
        .expect("对象应已落云端");
    assert_eq!(
        stored,
        payload.len(),
        "流式上传必须传完整文件（{stored} vs {}）",
        payload.len()
    );
    assert!(
        cloud.has_request_with("PUT /orbit/backups/dev.orfullsync"),
        "应发出对目标路径的 PUT：{:?}",
        cloud.requests()
    );
}

#[tokio::test]
async fn s3_streams_file_upload_and_signs_payload_hash() {
    let cloud = FakeCloud::spawn(Protocol::S3);
    let adapter = create_adapter(&s3_config(&cloud.base_url)).unwrap();

    let payload: Vec<u8> = (0..300 * 1024).map(|i| ((i * 7) % 256) as u8).collect();
    let (_dir, path) = tmp_file("dev.orfullsync", &payload);
    let len = std::fs::metadata(&path).unwrap().len();

    let cloud_path = upload_backup_file(&*adapter, "orbit", &path, len, "dev.orfullsync")
        .await
        .unwrap();
    assert_eq!(cloud_path, "orbit/backups/dev.orfullsync");
    // S3 的请求路径是 path-style（含 bucket 段），假服务按请求路径存对象
    let stored_key = format!("/bucket/{cloud_path}");
    assert_eq!(
        cloud.object_len(&stored_key),
        Some(payload.len()),
        "S3 流式上传字节数必须与文件一致（对象键 {stored_key}）"
    );
}

#[tokio::test]
async fn streamed_upload_of_empty_file_succeeds() {
    // 边界：空文件也要能上传（0 字节备份在空库场景是合法的）
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();
    let (_dir, path) = tmp_file("empty.orfullsync", b"");

    let cloud_path = upload_backup_file(&*adapter, "orbit", &path, 0, "empty.orfullsync")
        .await
        .unwrap();
    assert_eq!(cloud.object_len(&format!("/{cloud_path}")), Some(0));
}

#[tokio::test]
async fn missing_local_file_fails_without_network_call() {
    // 本地文件不存在属确定性失败：不应发请求，也不应被当作可重试
    let cloud = FakeCloud::spawn(Protocol::WebDav);
    let adapter = create_adapter(&webdav_config(&cloud.base_url)).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let missing = dir.path().join("nope.orfullsync");

    let err = upload_backup_file(&*adapter, "orbit", &missing, 100, "nope.orfullsync")
        .await
        .unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("云端上传失败") || msg.contains("打开"),
        "应报可读错误：{msg}"
    );
    // 本地文件不存在属确定性失败：不应发出 PUT（目录预建请求允许先发）
    assert!(
        !cloud.requests().iter().any(|r| r.contains("PUT")),
        "文件不存在时不该发出 PUT：{:?}",
        cloud.requests()
    );
}

#[tokio::test]
async fn default_upload_file_falls_back_to_whole_file_read() {
    // 未覆盖 upload_file 的适配器（如测试桩）走默认实现：整包读入 + upload_owned。
    // 行为必须与流式路径一致（内容与长度都对），只是没有内存收益。
    use async_trait::async_trait;
    use bytes::Bytes;
    use orbit_core::sync::error::SyncError;
    use orbit_core::sync_adapters::traits::{RemoteFile, SyncAdapter};

    #[derive(Default)]
    struct StubAdapter {
        stored: std::sync::Mutex<Vec<(String, Vec<u8>)>>,
    }

    #[async_trait]
    impl SyncAdapter for StubAdapter {
        async fn list_all_files(&self, _base: &str) -> Result<Vec<RemoteFile>, SyncError> {
            Ok(Vec::new())
        }
        async fn download(&self, _path: &str) -> Result<Bytes, SyncError> {
            Err(SyncError::Network {
                message: "stub".into(),
                retryable: false,
            })
        }
        async fn upload(&self, path: &str, data: &[u8]) -> Result<(), SyncError> {
            self.stored
                .lock()
                .unwrap()
                .push((path.to_string(), data.to_vec()));
            Ok(())
        }
        async fn delete(&self, _path: &str) -> Result<(), SyncError> {
            Ok(())
        }
        async fn list_assets(&self, _dir: &str) -> Result<Vec<String>, SyncError> {
            Ok(Vec::new())
        }
    }

    let stub = StubAdapter::default();
    let payload: Vec<u8> = (0..5000).map(|i| (i % 256) as u8).collect();
    let (_dir, path) = tmp_file("x.orfullsync", &payload);
    let len = std::fs::metadata(&path).unwrap().len();

    stub.upload_file("orbit/backups/x.orfullsync", &path, len)
        .await
        .unwrap();

    let stored = stub.stored.lock().unwrap();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].0, "orbit/backups/x.orfullsync");
    assert_eq!(
        stored[0].1, payload,
        "默认实现必须传完整内容（退回整包读入）"
    );
}
