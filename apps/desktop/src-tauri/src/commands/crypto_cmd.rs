//! crypto command — 包装 orbit_core::crypto
//!
//! 两部分：
//! 1. 通用加密工具（sha256/random）— 无状态，直接调用
//! 2. 主密码认证（master_auth_*）— 读写 app_data_dir/master_auth.json

use tauri::{AppHandle, State};
use orbit_core::crypto::master_auth::{
    change_master_auth_password, db_key_to_hex, init_master_auth, unlock_master_auth,
    verify_master_auth,
};
use orbit_core::db::lifecycle;

use crate::commands::data_dir::resolve_app_data_dir;
use crate::AppState;

// ==================== 通用加密工具 ====================

/// 桥接探活：验证前端 invoke -> Rust -> orbit_core 通路
#[tauri::command]
pub async fn ping(state: State<'_, AppState>) -> Result<String, String> {
    let _ = state.inner();
    Ok("pong from orbit_core bridge".to_string())
}

/// SHA-256 哈希
/// 前端：invoke('crypto_sha256', { input: 'abc' }) -> hex string
#[tauri::command]
pub async fn crypto_sha256(input: String) -> Result<String, String> {
    Ok(orbit_core::crypto::sha256_hex(input.as_bytes()))
}

/// 生成密码学安全随机字节并以 hex 返回
/// 前端：invoke('crypto_random_hex', { len: 32 }) -> 64 字符 hex
#[tauri::command]
pub async fn crypto_random_hex(len: usize) -> Result<String, String> {
    let bytes = orbit_core::crypto::random_bytes(len);
    Ok(bytes.iter().map(|b| format!("{:02x}", b)).collect())
}

// ==================== 主密码认证 ====================

/// 查询是否已设置主密码
///
/// 前端启动时调用：true → 显示解锁页；false → 直接初始化明文数据库
#[tauri::command]
pub async fn master_auth_has(app: AppHandle) -> Result<bool, String> {
    let dir = resolve_app_data_dir(&app)?;
    Ok(lifecycle::has_master_auth(&dir))
}

/// 初始化主密码（首次设置）
///
/// 生成 salt + DB Key，持久化元数据到 master_auth.json。
/// 返回 db_key_hex 供前端调用 db_init_encrypted。
#[tauri::command]
pub async fn master_auth_init(app: AppHandle, password: String) -> Result<String, String> {
    let dir = resolve_app_data_dir(&app)?;

    // 已设置则拒绝重复初始化
    if lifecycle::has_master_auth(&dir) {
        return Err("主密码已设置，请使用 master_auth_unlock 或 master_auth_change_password".to_string());
    }

    let (meta, db_key) = init_master_auth(&password).map_err(|e| e.to_string())?;
    lifecycle::save_master_auth(&dir, &meta).map_err(|e| e.to_string())?;

    Ok(db_key_to_hex(&db_key))
}

/// 解锁主密码
///
/// 验证密码并解密 DB Key。成功返回 db_key_hex，前端用它调用 db_init_encrypted。
#[tauri::command]
pub async fn master_auth_unlock(app: AppHandle, password: String) -> Result<String, String> {
    let dir = resolve_app_data_dir(&app)?;

    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;

    let (db_key, upgraded_meta) = unlock_master_auth(&password, &meta).map_err(|e| e.to_string())?;

    // v1→v2 自动升级：解锁成功后持久化升级后的 meta（参考 master_auth.rs 文档）
    // 不保存会导致 v1 旧格式用户每次解锁都重复升级，永远停留在 v1
    if let Some(new_meta) = upgraded_meta {
        lifecycle::save_master_auth(&dir, &new_meta).map_err(|e| e.to_string())?;
    }

    Ok(db_key_to_hex(&db_key))
}

/// 仅验证主密码是否正确（不解锁，不返回 db_key）
///
/// 用于敏感操作前的二次确认。
#[tauri::command]
pub async fn master_auth_verify(app: AppHandle, password: String) -> Result<bool, String> {
    let dir = resolve_app_data_dir(&app)?;

    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;

    Ok(verify_master_auth(&password, &meta))
}

/// 修改主密码
///
/// 验证旧密码后用新密码重新包装 DB Key。DB Key 本身不变，无需重新加密数据库。
/// 注意：修改后需要重启应用以重新初始化数据库连接。
#[tauri::command]
pub async fn master_auth_change_password(
    app: AppHandle,
    old_password: String,
    new_password: String,
) -> Result<(), String> {
    let dir = resolve_app_data_dir(&app)?;

    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;

    let (new_meta, _) = change_master_auth_password(&old_password, &new_password, &meta)
        .map_err(|e| e.to_string())?;

    lifecycle::save_master_auth(&dir, &new_meta).map_err(|e| e.to_string())?;

    Ok(())
}

/// 清除主密码（取消开屏密码）
///
/// 删除 master_auth.json。此后数据库将以明文模式打开。
/// 注意：调用前应已完成加密→明文的数据库迁移，否则加密数据库将无法打开。
#[tauri::command]
pub async fn master_auth_clear(app: AppHandle) -> Result<(), String> {
    let dir = resolve_app_data_dir(&app)?;
    lifecycle::clear_master_auth(&dir).map_err(|e| e.to_string())?;
    Ok(())
}
