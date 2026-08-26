//! db_cmd - 数据库生命周期命令（Orbit 裁剪版）
//!
//! 前端启动流程（03 文档 §四）：
//!   1. master_auth_has() -> 是否设置主密码
//!   2a. 未设置 -> db_init_plaintext() 明文库
//!   2b. 已设置 -> 解锁页 master_auth_unlock(pw) -> db_init_encrypted(db_key_hex)

use orbit_core::context;
use orbit_core::db::migrate::{
    finalize_encrypted_migration, finalize_migration, migrate_to_encrypted, migrate_to_plaintext,
};
use orbit_core::db::pool::{init_pool, init_pool_unencrypted};
use orbit_core::eventbus::EVENT_BUS;
use tauri::{AppHandle, Emitter, Manager};

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;

/// 初始化明文数据库（未设置主密码时使用）
///
/// 在 app_data_dir 下创建/打开 wait_home.db，不加密。
/// 初始化后 manage AppState，并启动事件转发任务。
#[tauri::command]
pub async fn db_init_plaintext(app: AppHandle) -> Result<(), String> {
    if app.try_state::<AppState>().is_some() {
        return Err("数据库已初始化，请勿重复调用".to_string());
    }

    let dir = resolve_app_data_dir(&app)?;
    let db_path = orbit_core::db::lifecycle::db_path(&dir);

    let pool = init_pool_unencrypted(&db_path)
        .await
        .map_err(|e| format!("数据库初始化失败: {}", e))?;

    app.manage(AppState::new(pool));
    start_event_forwarding(app);

    Ok(())
}

/// 初始化加密数据库（已解锁主密码后使用）
///
/// 使用 master_auth_unlock 返回的 db_key_hex 打开 SQLCipher 加密数据库。
/// hex 格式 key 会被转换为 SQLCipher 的 `x'...'` 格式。
#[tauri::command]
pub async fn db_init_encrypted(app: AppHandle, db_key_hex: String) -> Result<(), String> {
    if app.try_state::<AppState>().is_some() {
        return Err("数据库已初始化，请勿重复调用".to_string());
    }

    let dir = resolve_app_data_dir(&app)?;
    let db_path = orbit_core::db::lifecycle::db_path(&dir);

    // hex 格式 key → SQLCipher 的 x'...' 格式
    let pragma_key = format!("x'{}'", db_key_hex);

    let pool = init_pool(&db_path, Some(&pragma_key))
        .await
        .map_err(|e| format!("加密数据库初始化失败: {}", e))?;

    app.manage(AppState::new(pool));
    start_event_forwarding(app);

    Ok(())
}

/// 查询数据库是否已初始化
///
/// 前端据此判断是否需要显示解锁页面。
#[tauri::command]
pub async fn db_is_ready(app: AppHandle) -> bool {
    app.try_state::<AppState>().is_some()
}

/// 启动事件转发任务：EVENT_BUS → Tauri emit("db-change")
///
/// 从 db_init_* 命令内部调用，确保 pool 就绪后才开始转发。
fn start_event_forwarding(app: AppHandle) {
    let emit_handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut rx = EVENT_BUS.subscribe();
        while let Ok(event) = rx.recv().await {
            let _ = emit_handle.emit("db-change", &event);
        }
    });
}

/// 加密→明文数据库迁移（清除主密码场景）
///
/// 将当前加密数据库原子性导出为明文数据库，替换原加密文件。
/// 迁移成功后旧连接池将被关闭，AppState 被移除，
/// 前端应调用 master_auth_clear() 并提示用户重启应用以明文模式重新打开。
///
/// # 前置条件
/// - 数据库已初始化（AppState 已 manage）
/// - 当前数据库为加密模式
///
/// # 流程
/// 1. 克隆 pool（SqlitePool 为 Arc，clone 廉价）避免借用冲突
/// 2. migrate_to_plaintext：WAL checkpoint → ATTACH 明文临时库 → sqlcipher_export → DETACH
/// 3. 关闭旧连接池（释放文件句柄）
/// 4. finalize_migration：用明文临时文件替换加密数据库文件
/// 5. unmanage AppState（pool 已关闭，不可再用）
#[tauri::command]
pub async fn db_migrate_to_plaintext(app: AppHandle) -> Result<(), String> {
    // 克隆 pool 避免 unmanage 时的借用冲突
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "数据库未初始化".to_string())?
        .pool
        .clone();

    let dir = resolve_app_data_dir(&app)?;
    let db_path = orbit_core::db::lifecycle::db_path(&dir);

    // 1. 加密→明文导出（数据写入 .plain_tmp 临时文件）
    migrate_to_plaintext(&pool, &db_path)
        .await
        .map_err(|e| format!("数据库迁移失败: {}", e))?;

    // 2. 关闭旧连接池（释放对加密数据库的文件句柄）
    pool.close().await;

    // 3. 用明文临时文件替换加密数据库文件
    finalize_migration(&db_path).map_err(|e| format!("数据库文件替换失败: {}", e))?;

    // 4. 移除旧 AppState（pool 已关闭，后续命令需重新初始化）
    // unmanage 在 Tauri 2.0 被标记 deprecated（可能产生悬垂引用），
    // 但本场景中 pool 已 close 且无其他引用持有 AppState，使用安全。
    #[allow(deprecated)]
    app.unmanage::<AppState>();

    Ok(())
}

// Phase 9F: 全局上下文初始化（device_id）
//
// 对应移动端 FRB 启动流程：数据库初始化后调用 set_device_id 写入 OnceCell，
// 供 generic_repo 在 create/update/delete 时自动填充 device_id 列。
// =============================================================================

/// 写入当前设备 ID（进程级 OnceCell，仅可调用一次）
///
/// 前端应在数据库初始化 + 设备注册完成后立即调用。
/// 重复调用返回错误（通常意味着启动流程异常）。
#[tauri::command]
pub async fn db_set_device_id(device_id: String) -> Result<(), String> {
    context::set_device_id(device_id)
}

/// 读取当前设备 ID（未设置时返回空字符串）
#[tauri::command]
pub async fn db_get_device_id() -> Result<String, String> {
    context::get_device_id()
        .map(String::from)
        .or_else(|_| Ok(String::new()))
}

/// 明文→加密数据库迁移（设置主密码场景，与 migrate_to_plaintext 对称）
///
/// 流程：sqlcipher_export 到加密临时文件 -> 关闭旧连接池 -> 文件替换 -> 移除 AppState。
/// 前端随后调用 master_auth_init 持久化 meta（应先行），再 db_init_encrypted 重开。
#[tauri::command]
pub async fn db_migrate_to_encrypted(app: AppHandle, db_key_hex: String) -> Result<(), String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "数据库未初始化".to_string())?
        .pool
        .clone();

    let dir = resolve_app_data_dir(&app)?;
    let db_path = orbit_core::db::lifecycle::db_path(&dir);

    migrate_to_encrypted(&pool, &db_path, &db_key_hex)
        .await
        .map_err(|e| format!("数据库加密迁移失败: {}", e))?;

    pool.close().await;

    finalize_encrypted_migration(&db_path).map_err(|e| format!("数据库文件替换失败: {}", e))?;

    #[allow(deprecated)]
    app.unmanage::<AppState>();

    Ok(())
}
