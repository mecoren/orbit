//! sync_conflict_cmd — 冲突败方副本的查看与处置（03 文档 §八 遗留项兑现）
//!
//! 薄壳转发 `orbit_core::api::sync_conflict_api`：列表 / 计数 / 恢复 / 忽略 / 清空。
//! 「恢复」会在业务表上发起一次真实写入并广播 db-change，因此前端缓存与
//! 下一轮同步都会自然跟进。

use tauri::{AppHandle, Manager};

use orbit_core::api::sync_conflict_api::{self, SyncConflict};

use crate::AppState;

/// 取数据库连接池（未初始化时给出可读错误）
fn pool_of(app: &AppHandle) -> Result<sqlx::SqlitePool, String> {
    Ok(app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone())
}

/// 列出冲突记录（`resolution` 为 None 时返回全部；按时间倒序分页）
#[tauri::command]
pub async fn sync_conflict_list(
    app: AppHandle,
    resolution: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<Vec<SyncConflict>, String> {
    let pool = pool_of(&app)?;
    sync_conflict_api::list_conflicts(&pool, resolution, limit, offset)
        .await
        .map_err(|e| e.to_string())
}

/// 统计冲突记录数（设置页角标：传 "unresolved" 只要待处理）
#[tauri::command]
pub async fn sync_conflict_count(
    app: AppHandle,
    resolution: Option<String>,
) -> Result<i64, String> {
    let pool = pool_of(&app)?;
    sync_conflict_api::count_conflicts(&pool, resolution)
        .await
        .map_err(|e| e.to_string())
}

/// 恢复某条冲突的败方内容（返回被写回的原行 id）
#[tauri::command]
pub async fn sync_conflict_restore(app: AppHandle, id: i64) -> Result<i64, String> {
    let pool = pool_of(&app)?;
    sync_conflict_api::restore_conflict(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 忽略某条冲突（不改业务数据）
#[tauri::command]
pub async fn sync_conflict_dismiss(app: AppHandle, id: i64) -> Result<(), String> {
    let pool = pool_of(&app)?;
    sync_conflict_api::dismiss_conflict(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 清空冲突记录（`resolution` 为 None 时清全部），返回删除条数
#[tauri::command]
pub async fn sync_conflict_clear(
    app: AppHandle,
    resolution: Option<String>,
) -> Result<u64, String> {
    let pool = pool_of(&app)?;
    sync_conflict_api::clear_conflicts(&pool, resolution)
        .await
        .map_err(|e| e.to_string())
}
