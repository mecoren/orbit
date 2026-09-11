//! backup_scheduler — 定时全量备份守护（core v4 调度器桌面端接线）
//!
//! 60s tick（与 sync_scheduler 口径一致）：
//! - DB 未就绪 / schedule_type=off → 静默跳过
//! - next_backup_at 未初始化（0）→ 计算并持久化后本轮跳过
//! - now < next_backup_at → 跳过；RUNNING 原子锁防重入
//! - 钥匙串无缓存同步密码 → 跳过且不推进 next_backup_at
//!   （用户解锁后下一轮自动补跑错过的备份）
//! - 触发：export_full_sync_backup_with_cloud（受偏好本地/云端开关控制）；
//!   成功 → update_scheduler_state_after_trigger 推进 last/next；
//!   失败 → 仅推进 next（last 保留"最近一次成功"语义）
//! - 结果均 emit("auto-backup-finished", payload) 供设置页刷新与提示

use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::json;
use tauri::{AppHandle, Emitter, Manager};

use orbit_core::api::full_sync_backup_api;
use orbit_core::full_sync_backup::backup_prefs::{BackupPrefs, ScheduleType};
use orbit_core::full_sync_backup::save_prefs;
use orbit_core::full_sync_backup::scheduler::calculate_next_backup_at;

use crate::AppState;
use crate::commands::data_dir::resolve_app_data_dir;
use crate::commands::sync_runtime;

/// tick 周期：60s
const TICK_SECS: u64 = 60;

static STARTED: AtomicBool = AtomicBool::new(false);
/// 防重入：备份导出较重，重叠触发直接跳过
static RUNNING: AtomicBool = AtomicBool::new(false);

/// 启动定时备份守护（幂等；lib.rs setup 阶段调用）
/// 移动端不启动（依赖钥匙串密码缓存），仅 backup_prefs_* 命令双端注册
#[cfg_attr(not(desktop), allow(dead_code))]
pub fn backup_scheduler_start(app: AppHandle) {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        loop {
            tick(&app).await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

/// 单轮判定与触发
async fn tick(app: &AppHandle) {
    let Some(state) = app.try_state::<AppState>() else {
        return; // DB 未就绪静默跳过
    };
    let Ok(dir) = resolve_app_data_dir(app) else {
        return;
    };

    let mut prefs = match full_sync_backup_api::get_backup_prefs(&dir).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[backup-scheduler] 读取备份偏好失败: {e}");
            return;
        }
    };
    if prefs.schedule_type == ScheduleType::Off {
        return;
    }

    let now_ts = chrono::Utc::now().timestamp();
    // 首次启用：初始化 next_backup_at 后等待到点
    if prefs.next_backup_at == 0 {
        prefs.next_backup_at = calculate_next_backup_at(now_ts, &prefs);
        let _ = save_prefs(&dir, &prefs);
        return;
    }
    if now_ts < prefs.next_backup_at || prefs.validate_schedule().is_err() {
        return;
    }
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }

    // 无缓存同步密码：无法加密备份包，跳过（不推进时间，解锁后补跑）
    let Some(password) = sync_runtime::read_cached_sync_password() else {
        RUNNING.store(false, Ordering::SeqCst);
        return;
    };

    // 云端配置按开关取用；未配置云同步时 None（云端阶段静默跳过）
    let cloud_config = if prefs.cloud_backup_enabled {
        full_sync_backup_api::get_active_cloud_config_from_db(&state.pool)
            .await
            .unwrap_or(None)
    } else {
        None
    };

    let result = full_sync_backup_api::export_full_sync_backup_with_cloud(
        &state.pool,
        &dir,
        &password,
        cloud_config,
    )
    .await;

    match result {
        Ok(r) => {
            // 本地写入失败（磁盘满等）不算成功：不推进 last_backup_at
            //（next 照常推进避免风暴），emit ok:false 供前端警示——
            // P1-15 修复：原实现不检查 local_error 即报 ok:true，用户静默丢备份
            let local_failed = prefs.local_backup_enabled && r.local_error.is_some();
            if local_failed {
                eprintln!(
                    "[backup-scheduler] 定时备份本地写入失败: {}",
                    r.local_error.as_deref().unwrap_or("未知")
                );
                if let Ok(mut p) = full_sync_backup_api::get_backup_prefs(&dir).await {
                    p.next_backup_at = calculate_next_backup_at(now_ts, &p);
                    let _ = save_prefs(&dir, &p);
                }
            } else {
                let _ = full_sync_backup_api::update_scheduler_state_after_trigger(&dir, now_ts)
                    .await;
            }
            let _ = app.emit(
                "auto-backup-finished",
                json!({
                    "ok": !local_failed,
                    "local_path": r.local_path,
                    "local_error": r.local_error,
                    "cloud_uploaded": r.cloud_uploaded,
                    "cloud_error": r.cloud_error,
                    "error": if local_failed { r.local_error.clone() } else { None },
                }),
            );
        }
        Err(e) => {
            eprintln!("[backup-scheduler] 定时备份失败: {e}");
            // 仅推进 next，避免同一时刻反复重试；last_backup_at 保留成功语义
            if let Ok(mut p) = full_sync_backup_api::get_backup_prefs(&dir).await {
                p.next_backup_at = calculate_next_backup_at(now_ts, &p);
                let _ = save_prefs(&dir, &p);
            }
            let _ = app.emit(
                "auto-backup-finished",
                json!({ "ok": false, "error": e.to_string() }),
            );
        }
    }
    RUNNING.store(false, Ordering::SeqCst);
}

// ============================================================================
// 偏好读写命令（设置页自动备份卡数据源）
// ============================================================================

/// 读取备份偏好（无文件返回默认值：off + 双开关关）
#[tauri::command]
pub async fn backup_prefs_get(app: AppHandle) -> Result<BackupPrefs, String> {
    let dir = resolve_app_data_dir(&app)?;
    full_sync_backup_api::get_backup_prefs(&dir)
        .await
        .map_err(|e| format!("[backup] {e}"))
}

/// 保存备份偏好（校验调度配置；返回回填 next_backup_at 后的完整偏好）
///
/// 调度变更时在壳层统一重算 next_backup_at：
/// - off → 0（取消调度）
/// - 其余 → 从当前时间起算的下一次触发点
#[tauri::command]
pub async fn backup_prefs_save(app: AppHandle, prefs: BackupPrefs) -> Result<BackupPrefs, String> {
    let dir = resolve_app_data_dir(&app)?;

    let mut prefs = prefs;
    prefs.next_backup_at = if prefs.schedule_type == ScheduleType::Off {
        0
    } else {
        calculate_next_backup_at(chrono::Utc::now().timestamp(), &prefs)
    };

    full_sync_backup_api::save_backup_prefs(&dir, &prefs)
        .await
        .map_err(|e| format!("[backup] {e}"))?;
    Ok(prefs)
}
