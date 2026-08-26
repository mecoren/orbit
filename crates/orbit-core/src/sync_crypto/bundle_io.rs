//! bundle_io — crypto/config 云端上传/下载
//!
//! 统一多设备 Data Key 同步入口：A 设备上传 crypto/config，B 设备下载并导入。
//! 移动端 FRB 桥接与桌面端 Tauri 命令均调用本模块，行为完全一致。
//!
//! ## 路径策略（P2 变更）
//! 历史版本 `crypto/config` 存放在云端根目录（不拼接 base_path），与模块数据
//! (`{base_path}/modules/...`) 分离，导致：
//! - 多用户/多配置共享同一云端时 crypto/config 互相覆盖
//! - 与"所有同步数据集中在 base_path 下"的设计原则不一致
//!
//! 新版本改为 `{base_path}/crypto/config`，并提供双读回退兼容旧数据：
//! - `upload_crypto_bundle_with_base_path`: 上传到 `{base_path}/crypto/config`
//! - `download_and_import_crypto_bundle_with_base_path`:
//!   1. 先读 `{base_path}/crypto/config`（新路径）
//!   2. 404 时回退到根目录 `crypto/config`（旧路径）
//!   3. 旧路径读取成功后自动迁移到新路径（上传到新路径 + 删除旧路径）
//!
//! 路径常量 `CRYPTO_CONFIG_PATH` 集中管理在 `cloud_sync::paths`，本模块 re-export
//! 以保持调用方兼容。该路径保持无扩展名（用户明确要求），不随 .waitsync 迁移改动。

use crate::sync_adapters::traits::SyncAdapter;
use crate::sync_crypto::error::SyncCryptoError;
use crate::sync_crypto::meta_store::SyncCryptoMeta;
use crate::sync_crypto::service::SyncCryptoService;

/// 云端 crypto/config 文件路径（re-export 自 cloud_sync::paths）
///
/// 语义：相对路径，由 `*_with_base_path` 函数拼接 `base_path` 前缀后使用。
/// 调用方应优先使用 `_with_base_path` 变体；旧版 `upload_crypto_bundle` /
/// `download_and_import_crypto_bundle` 保留供兼容性回退使用（直接用根目录路径）。
pub use crate::cloud_sync::paths::CRYPTO_CONFIG_PATH;

/// 旧版 crypto/config 路径（云端根目录，无 base_path 前缀）
///
/// 仅用于双读回退：当新路径 `{base_path}/crypto/config` 404 时，
/// 回退到此根目录路径读取旧版本数据。
pub const CRYPTO_CONFIG_LEGACY_PATH: &str = "crypto/config";

/// 拼接 base_path 与相对路径
///
/// - base_path 为空（或仅含斜杠）：原样返回 path（退化为根目录路径）
/// - 否则：返回 `{trimmed_base_path}/{path_trimmed_leading_slash}`
///
/// 与 `cloud_sync_api::BasePathAdapter::join` 行为一致，但本模块不依赖 api 层，
/// 避免循环依赖。base_path 处理需保留协议头中的 "//"（如 https://），
/// 但 crypto/config 路径不含协议头，故直接 trim_matches('/') 即可。
fn join_base_path(base_path: &str, path: &str) -> String {
    let trimmed = base_path.trim_matches('/');
    if trimmed.is_empty() {
        return path.to_string();
    }
    let p = path.trim_start_matches('/');
    if p.is_empty() {
        trimmed.to_string()
    } else {
        format!("{}/{}", trimmed, p)
    }
}

/// 判断 SyncError 是否表示「资源不存在」（404）
///
/// 复用 `cloud_sync::paths::is_not_found_error`，保留此函数以维持模块独立性。
fn is_not_found(err: &crate::sync::error::SyncError) -> bool {
    crate::cloud_sync::paths::is_not_found_error(err)
}

// ============================================================================
// 旧版 API（保留供兼容性回退使用，不建议新代码调用）
// ============================================================================

/// 上传同步加密元数据到云端根目录 `crypto/config`（旧版，无 base_path 前缀）
///
/// **已弃用**：新代码应使用 [`upload_crypto_bundle_with_base_path`]。
/// 本函数保留供：
/// - 测试场景（直接上传到根目录模拟旧版本数据）
/// - bundle_io 内部双读回退逻辑（旧路径下载后用本函数迁移到新路径不需要，
///   迁移逻辑直接调用 `upload_crypto_bundle_with_base_path`）
///
/// A 设备首次配置同步时调用：将本地 `sync_crypto_meta.json` 内容上传到 `crypto/config`。
pub async fn upload_crypto_bundle(
    adapter: &dyn SyncAdapter,
    meta: &SyncCryptoMeta,
) -> Result<(), SyncCryptoError> {
    let json = serde_json::to_vec(meta).map_err(|e| SyncCryptoError::Bundle {
        message: format!("序列化 crypto bundle 失败: {e}"),
    })?;
    adapter
        .upload(CRYPTO_CONFIG_PATH, &json)
        .await
        .map_err(SyncCryptoError::from)?;
    Ok(())
}

/// 从云端根目录 `crypto/config` 下载并导入同步加密元数据（旧版，无 base_path 前缀）
///
/// **已弃用**：新代码应使用 [`download_and_import_crypto_bundle_with_base_path`]。
/// 本函数保留供测试场景与极端兼容性回退使用。
///
/// 返回值：
/// - `Ok(Some(data_key))`：导入了云端 bundle，返回解密后的 Data Key
/// - `Ok(None)`：云端无 crypto/config（404），或本地 meta 与云端完全一致（无需导入）
pub async fn download_and_import_crypto_bundle(
    adapter: &dyn SyncAdapter,
    service: &SyncCryptoService,
    sync_password: &str,
) -> Result<Option<Vec<u8>>, SyncCryptoError> {
    download_and_import_inner(adapter, CRYPTO_CONFIG_PATH, service, sync_password).await
}

/// 仅下载云端 `crypto/config`（不导入），用于比对/诊断（旧版，无 base_path 前缀）
pub async fn download_crypto_bundle(
    adapter: &dyn SyncAdapter,
) -> Result<Option<SyncCryptoMeta>, SyncCryptoError> {
    let bytes = adapter
        .download(CRYPTO_CONFIG_PATH)
        .await
        .map_err(SyncCryptoError::from)?;

    let meta: SyncCryptoMeta =
        serde_json::from_slice(&bytes).map_err(|e| SyncCryptoError::Bundle {
            message: format!("解析 crypto bundle 失败: {e}"),
        })?;
    Ok(Some(meta))
}

// ============================================================================
// 新版 API（P2：路径迁移到 {base_path}/crypto/config + 双读回退 + 自动迁移）
// ============================================================================

/// 上传同步加密元数据到云端 `{base_path}/crypto/config`（新版）
///
/// A 设备首次配置同步时调用：将本地 `sync_crypto_meta.json` 内容上传到
/// `{base_path}/crypto/config`，与模块数据同目录。
///
/// - `base_path` 为空：退化为根目录 `crypto/config`（兼容无 base_path 配置）
/// - `base_path` 非空：拼接为 `{base_path}/crypto/config`
///
/// 其他设备用相同同步密码 + 相同 base_path 即可下载并还原 Data Key。
pub async fn upload_crypto_bundle_with_base_path(
    adapter: &dyn SyncAdapter,
    base_path: &str,
    meta: &SyncCryptoMeta,
) -> Result<(), SyncCryptoError> {
    let json = serde_json::to_vec(meta).map_err(|e| SyncCryptoError::Bundle {
        message: format!("序列化 crypto bundle 失败: {e}"),
    })?;
    let new_path = join_base_path(base_path, CRYPTO_CONFIG_PATH);
    log::info!("[bundle_io] 上传 crypto bundle 到新路径: {}", new_path);
    adapter
        .upload(&new_path, &json)
        .await
        .map_err(SyncCryptoError::from)?;
    Ok(())
}

/// 从云端下载并导入同步加密元数据（新版，双读回退 + 自动迁移）
///
/// **路径策略**：
/// 1. 先读 `{base_path}/crypto/config`（新路径）
/// 2. 404 时回退到根目录 `crypto/config`（旧路径，兼容已部署用户）
/// 3. 旧路径读取成功后自动迁移：上传到新路径 + 删除旧路径
/// 4. 双读都 404 → 返回 `Ok(None)`（云端无 crypto/config）
///
/// **返回值**：
/// - `Ok(Some(data_key))`：导入了云端 bundle（新或旧路径），返回解密后的 Data Key
/// - `Ok(None)`：云端新/旧路径都无 crypto/config（404），或本地 meta 与云端完全一致（无需导入）
///
/// **自动迁移失败处理**：迁移（上传到新路径 + 删除旧路径）失败仅记录日志，
/// 不阻塞导入流程，下次同步会再次尝试迁移。
pub async fn download_and_import_crypto_bundle_with_base_path(
    adapter: &dyn SyncAdapter,
    base_path: &str,
    service: &SyncCryptoService,
    sync_password: &str,
) -> Result<Option<Vec<u8>>, SyncCryptoError> {
    let new_path = join_base_path(base_path, CRYPTO_CONFIG_PATH);

    // 1. 先尝试新路径 {base_path}/crypto/config
    log::info!("[bundle_io] 尝试新路径下载: {}", new_path);
    match adapter.download(&new_path).await {
        Ok(bytes) => {
            log::info!("[bundle_io] 新路径下载成功: {}", new_path);
            // 新路径下载成功，直接走导入流程（无需迁移）
            return download_and_import_inner_from_bytes(
                adapter,
                &bytes,
                &new_path,
                service,
                sync_password,
                /* migrate_to_new= */ false,
                /* legacy_path= */ None,
            )
            .await;
        }
        Err(e) if is_not_found(&e) => {
            log::info!(
                "[bundle_io] 新路径 404，回退到旧路径: {} (err: {})",
                new_path,
                e
            );
            // 新路径 404，回退到旧路径
        }
        Err(e) => {
            // 其他错误（网络故障等）向上传播
            return Err(SyncCryptoError::from(e));
        }
    }

    // 2. 回退到旧路径 crypto/config（根目录）
    log::info!("[bundle_io] 尝试旧路径下载: {}", CRYPTO_CONFIG_LEGACY_PATH);
    match adapter.download(CRYPTO_CONFIG_LEGACY_PATH).await {
        Ok(bytes) => {
            log::info!(
                "[bundle_io] 旧路径下载成功: {}，触发自动迁移到新路径 {}",
                CRYPTO_CONFIG_LEGACY_PATH,
                new_path
            );
            // 旧路径下载成功，走导入流程 + 自动迁移到新路径
            return download_and_import_inner_from_bytes(
                adapter,
                &bytes,
                &new_path,
                service,
                sync_password,
                /* migrate_to_new= */ true,
                /* legacy_path= */ Some(CRYPTO_CONFIG_LEGACY_PATH),
            )
            .await;
        }
        Err(e) if is_not_found(&e) => {
            log::info!("[bundle_io] 旧路径也 404，云端无 crypto/config: {}", e);
            // 双读都 404，视为云端无 crypto/config
            Ok(None)
        }
        Err(e) => Err(SyncCryptoError::from(e)),
    }
}

/// 下载并导入的内部实现（旧版 API 共用）
///
/// 直接从指定 `path` 下载，不走双读回退。供 `download_and_import_crypto_bundle`
/// （旧版根目录路径）与测试场景使用。
async fn download_and_import_inner(
    adapter: &dyn SyncAdapter,
    path: &str,
    service: &SyncCryptoService,
    sync_password: &str,
) -> Result<Option<Vec<u8>>, SyncCryptoError> {
    let bytes = adapter
        .download(path)
        .await
        .map_err(SyncCryptoError::from)?;
    download_and_import_inner_from_bytes(
        adapter,
        &bytes,
        path,
        service,
        sync_password,
        /* migrate_to_new= */ false,
        /* legacy_path= */ None,
    )
    .await
}

/// 从已下载的字节流解析并导入 crypto bundle（核心逻辑）
///
/// 参数：
/// - `bytes`: 已下载的 crypto bundle 字节流
/// - `current_path`: 当前下载用的路径（用于日志）
/// - `migrate_to_new`: 是否触发自动迁移（旧路径 → 新路径）
/// - `legacy_path`: 旧路径（迁移时删除），`migrate_to_new=false` 时为 None
async fn download_and_import_inner_from_bytes(
    adapter: &dyn SyncAdapter,
    bytes: &[u8],
    current_path: &str,
    service: &SyncCryptoService,
    sync_password: &str,
    migrate_to_new: bool,
    legacy_path: Option<&str>,
) -> Result<Option<Vec<u8>>, SyncCryptoError> {
    // 1. 解析云端 meta
    let cloud_meta: SyncCryptoMeta =
        serde_json::from_slice(bytes).map_err(|e| SyncCryptoError::Bundle {
            message: format!("解析 crypto bundle 失败: {e}"),
        })?;

    // 2. 全字段比对：本地 meta 与云端 meta 完全一致才跳过（不仅是 salt）
    //    salt + encrypted_data_key + data_key_nonce + iterations 全部相同
    //    才能保证本地 Data Key 与云端一致
    if let Ok(Some(local_meta)) =
        crate::sync_crypto::meta_store::load_sync_crypto_meta(service.app_data_dir())
    {
        if local_meta == cloud_meta {
            // 日志仅输出 iterations（非密钥材料），不输出 salt/ciphertext 片段
            // （旧版日志曾输出 salt/encrypted_data_key 前 8 字符，属密钥材料卫生问题）
            log::info!(
                "[bundle_io] 跳过导入：本地 meta 与云端完全一致 (path={}, iterations={})",
                current_path,
                local_meta.iterations
            );
            // 即使跳过导入，仍触发迁移（旧路径 → 新路径）
            if migrate_to_new {
                migrate_legacy_to_new_path(adapter, current_path, legacy_path).await;
            }
            return Ok(None);
        }
        // 仅输出 iterations 对比（非密钥材料），避免泄露 salt/ciphertext 片段
        log::info!(
            "[bundle_io] 检测到 meta 差异，将导入云端 bundle (path={}): \
             local_iterations={}, cloud_iterations={}",
            current_path,
            local_meta.iterations,
            cloud_meta.iterations
        );
    }

    // 3. meta 不一致：用同步密码派生云端 master_key 解密 Data Key
    // Fix-10：此处为多设备自动对账流程（云端为准），按设计允许覆盖本地 meta，
    // 故传 force=true；手动导入命令（syncCryptoImportBundle）才需要用户确认。
    let data_key = service.import_crypto_bundle(&cloud_meta, sync_password, true)?;
    log::info!(
        "[bundle_io] 成功导入云端 Data Key ({} 字节, path={})",
        data_key.len(),
        current_path
    );

    // 4. 旧路径 → 新路径自动迁移（不阻塞导入流程）
    if migrate_to_new {
        migrate_legacy_to_new_path(adapter, current_path, legacy_path).await;
    }

    Ok(Some(data_key))
}

/// 自动迁移：将旧路径数据上传到新路径，并删除旧路径
///
/// 迁移失败仅记录日志，不阻塞主流程。下次同步会再次尝试迁移。
async fn migrate_legacy_to_new_path(
    adapter: &dyn SyncAdapter,
    new_path: &str,
    legacy_path: Option<&str>,
) {
    let Some(legacy) = legacy_path else {
        return;
    };

    // 重新读取旧路径数据（已在调用方读过的 bytes 不在此函数作用域内，
    // 为简化逻辑，重新下载一次。如果失败则跳过迁移）
    let bytes = match adapter.download(legacy).await {
        Ok(b) => b,
        Err(e) => {
            log::info!(
                "[bundle_io] 自动迁移：重新下载旧路径失败（跳过迁移）: {}",
                e
            );
            return;
        }
    };

    // 上传到新路径
    if let Err(e) = adapter.upload(new_path, &bytes).await {
        log::info!(
            "[bundle_io] 自动迁移：上传到新路径 {} 失败（不阻塞，下次重试）: {}",
            new_path,
            e
        );
        return;
    }
    log::info!("[bundle_io] 自动迁移：上传到新路径 {} 成功", new_path);

    // 删除旧路径
    if let Err(e) = adapter.delete(legacy).await {
        log::info!(
            "[bundle_io] 自动迁移：删除旧路径 {} 失败（不阻塞，下次重试）: {}",
            legacy,
            e
        );
        return;
    }
    log::info!("[bundle_io] 自动迁移：删除旧路径 {} 成功", legacy);
}
