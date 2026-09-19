//! auth — 主密码认证 + DB 生命周期（薄包装）
//!
//! 与桌面壳 crypto_cmd.rs / db_cmd.rs 一一对应；业务全部在 orbit_core。
//! 差异：桌面经 AppHandle 解析 app_data_dir，本层由 Dart 经 path_provider
//! 取得目录后以 base_dir 参数传入。

use std::path::PathBuf;

use orbit_core::crypto::master_auth::{
    change_master_auth_password, db_key_to_hex, init_master_auth, unlock_master_auth,
    verify_master_auth,
};
use orbit_core::db::lifecycle;
use orbit_core::db::migrate::{
    finalize_encrypted_migration, finalize_migration, migrate_to_encrypted, migrate_to_plaintext,
};

use super::state::{clear_state, set_state};

fn dir_of(base_dir: String) -> Result<PathBuf, String> {
    if base_dir.is_empty() {
        return Err("[invalid_input] base_dir 不能为空".to_string());
    }
    Ok(PathBuf::from(base_dir))
}

// ── DB 生命周期 ──

/// 初始化明文数据库（未设置主密码时使用）
///
/// 成功后全局状态就绪（事件转发由 Dart 先行调用 subscribe_db_changes 建立）。
pub async fn db_init_plaintext(base_dir: String) -> Result<(), String> {
    let dir = dir_of(base_dir)?;
    let db_path = lifecycle::db_path(&dir);

    let pool = orbit_core::db::pool::init_pool_unencrypted(&db_path)
        .await
        .map_err(|e| format!("数据库初始化失败: {e}"))?;

    set_state(pool, dir);
    Ok(())
}

/// 初始化加密数据库（已解锁主密码后使用）
///
/// hex 格式 key 转换为 SQLCipher 的 `x'...'` 格式（与桌面一致）。
pub async fn db_init_encrypted(base_dir: String, db_key_hex: String) -> Result<(), String> {
    let dir = dir_of(base_dir)?;
    let db_path = lifecycle::db_path(&dir);

    let pragma_key = format!("x'{db_key_hex}'");
    let pool = orbit_core::db::pool::init_pool(&db_path, Some(&pragma_key))
        .await
        .map_err(|e| format!("加密数据库初始化失败: {e}"))?;

    set_state(pool, dir);
    Ok(())
}

/// 查询数据库是否已初始化
pub async fn db_is_ready() -> bool {
    crate::api::state::orbit_state_initialized()
}

/// 写入当前设备 ID（进程级 OnceCell，DB 初始化后调用一次）
pub async fn db_set_device_id(device_id: String) -> Result<(), String> {
    orbit_core::context::set_device_id(device_id)
}

/// 读取当前设备 ID（未设置时返回空字符串）
pub async fn db_get_device_id() -> Result<String, String> {
    Ok(orbit_core::context::get_device_id()
        .map(String::from)
        .unwrap_or_default())
}

/// 移除状态（迁移场景：pool 已 close 后由 Dart 调用，随后重开连接池）
pub fn db_reset_state() -> Result<(), String> {
    clear_state();
    Ok(())
}

// ── 主密码认证 ──

/// 是否已设置主密码（启动门控第一步）
pub fn master_auth_has(base_dir: String) -> Result<bool, String> {
    let dir = dir_of(base_dir)?;
    Ok(lifecycle::has_master_auth(&dir))
}

/// 初始化主密码（首次设置），返回 db_key_hex
///
/// 典型流程：master_auth_init(pw) → db_init_encrypted(base_dir, dbKeyHex)
pub fn master_auth_init(base_dir: String, password: String) -> Result<String, String> {
    let dir = dir_of(base_dir)?;

    if lifecycle::has_master_auth(&dir) {
        return Err("主密码已设置，请使用 master_auth_unlock 或 change_password".to_string());
    }

    let (meta, db_key) = init_master_auth(&password).map_err(|e| e.to_string())?;
    lifecycle::save_master_auth(&dir, &meta).map_err(|e| e.to_string())?;

    Ok(db_key_to_hex(&db_key))
}

/// 解锁主密码，返回 db_key_hex；密码错误抛异常
pub fn master_auth_unlock(base_dir: String, password: String) -> Result<String, String> {
    let dir = dir_of(base_dir)?;

    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;

    let (db_key, upgraded_meta) =
        unlock_master_auth(&password, &meta).map_err(|e| e.to_string())?;

    // v1→v2 自动升级持久化（与桌面一致，避免每次解锁重复升级）
    if let Some(new_meta) = upgraded_meta {
        lifecycle::save_master_auth(&dir, &new_meta).map_err(|e| e.to_string())?;
    }

    Ok(db_key_to_hex(&db_key))
}

/// 仅验证主密码是否正确（敏感操作前二次确认）
pub fn master_auth_verify(base_dir: String, password: String) -> Result<bool, String> {
    let dir = dir_of(base_dir)?;
    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;
    Ok(verify_master_auth(&password, &meta))
}

/// 修改主密码（校验旧密码后重写 master_auth.json；数据库 Key 不变）
///
/// 对齐桌面 `master_auth_change_password`。注意：本函数只换「开屏密码包装」，
/// 数据库文件的加密 Key 不受影响，故无需重开连接池。
pub fn master_auth_change_password(
    base_dir: String,
    old_password: String,
    new_password: String,
) -> Result<(), String> {
    let dir = dir_of(base_dir)?;
    let meta = lifecycle::load_master_auth(&dir)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未设置主密码".to_string())?;

    let (new_meta, _) = change_master_auth_password(&old_password, &new_password, &meta)
        .map_err(|e| e.to_string())?;
    lifecycle::save_master_auth(&dir, &new_meta).map_err(|e| e.to_string())
}

/// 清除主密码（删除 master_auth.json，此后以明文模式打开）
///
/// 对齐桌面 `master_auth_clear`。**调用前必须已完成
/// [db_migrate_to_plaintext]**，否则加密数据库将无法打开。
pub fn master_auth_clear(base_dir: String) -> Result<(), String> {
    let dir = dir_of(base_dir)?;
    lifecycle::clear_master_auth(&dir).map_err(|e| e.to_string())
}

// ── 加密 ↔ 明文库迁移（对齐桌面 db_cmd.rs） ──

/// 加密库 → 明文库迁移（设置页「关闭加密」场景）
///
/// 流程与桌面一致：WAL checkpoint → ATTACH 明文临时库 → sqlcipher_export →
/// 关闭旧连接池 → 用明文文件替换 → 清空全局状态。
/// **调用方（Dart）在返回后须重新走 db_init_plaintext 才可继续操作**，
/// 否则后续命令报 `[not_initialized]`。
pub async fn db_migrate_to_plaintext() -> Result<(), String> {
    let (pool, dir) = super::state::with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let db_path = lifecycle::db_path(&dir);

    migrate_to_plaintext(&pool, &db_path)
        .await
        .map_err(|e| format!("数据库迁移失败: {e}"))?;

    pool.close().await;
    finalize_migration(&db_path).map_err(|e| format!("数据库文件替换失败: {e}"))?;
    super::state::clear_state();
    Ok(())
}

/// 明文库 → 加密库迁移（首次设置主密码场景）
///
/// 流程与桌面一致：sqlcipher_export 到加密临时文件 → 关闭旧连接池 →
/// 文件替换 → 清空全局状态。**调用方须先 master_auth_init 持久化 meta，
/// 返回后再 db_init_encrypted(db_key_hex) 重开**。
pub async fn db_migrate_to_encrypted(db_key_hex: String) -> Result<(), String> {
    let (pool, dir) = super::state::with_state(|s| Ok((s.pool.clone(), s.base_dir.clone())))?;
    let db_path = lifecycle::db_path(&dir);

    migrate_to_encrypted(&pool, &db_path, &db_key_hex)
        .await
        .map_err(|e| format!("数据库加密迁移失败: {e}"))?;

    pool.close().await;
    finalize_encrypted_migration(&db_path).map_err(|e| format!("数据库文件替换失败: {e}"))?;
    super::state::clear_state();
    Ok(())
}
