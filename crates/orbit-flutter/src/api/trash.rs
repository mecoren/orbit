//! trash — 移动端桥接层回收站域（用户需求：删除的任务进回收站，保留时间可配，可恢复）
//!
//! 与桌面壳命令一一对应（业务全部在 orbit_core::api::trash_api）：
//! - trash_tasks_list → 桌面 trash_tasks_list；恢复/彻底删除/清空 → 桌面同名命令；
//! - trash_meta / trash_set_retention_days → 桌面同名命令（cfg_kv 本地偏好，不同步）。
//!
//! ## DTO 镜像模式
//! 回收站行直接复用 [super::dto] 的 TodoTask（含 deleted_at）；TrashMeta /
//! TrashPurgeStats 为本模块本地 DTO（同 [super::holiday] 的 HolidayMeta 规则）。
//!
//! ## 移动端 TTL 清理调度（手机被杀后无 Dart 进程，与桌面常驻 tick 不同）
//! `start_trash_scheduler` 为 FRB 运行时上的 Rust 守护（同
//! [super::holiday] 的 start_holiday_scheduler 模式）：60s tick +
//! should_purge_now 每日判定。关键时序：
//! - **启动补清**：应用多日没开 → 打开时 db_init 后 Dart 调本函数，
//!   首轮 tick 即补清过期间隔的过期任务；
//! - **每日最多一次**：当天清过则 tick 静默跳过（记账在 cfg_kv，重启不丢）；
//! - 同步守卫在 core maybe_purge_expired 内部（启用云同步时只清已 push 的墓碑）。

use std::sync::atomic::{AtomicBool, Ordering};

use orbit_core::api::trash_api;
use serde::Serialize;

pub use super::dto::TodoTask;

/// TTL 清理统计（镜像 core trash_api::PurgeStats）
#[derive(Debug, Clone, Serialize)]
pub struct TrashPurgeStats {
    pub purged: u64,
    pub guarded: u64,
    pub ran: bool,
}

impl From<trash_api::PurgeStats> for TrashPurgeStats {
    fn from(s: trash_api::PurgeStats) -> Self {
        Self {
            purged: s.purged,
            guarded: s.guarded,
            ran: s.ran,
        }
    }
}

/// 回收站元数据（镜像 core trash_api::TrashMeta）
#[derive(Debug, Clone, Serialize)]
pub struct TrashMeta {
    /// 保留天数（0 = 永久；默认 30，档位 7/30/90/0）
    pub retention_days: i64,
    /// 上次 TTL 自动清理时间（ms；0 = 从未执行）
    pub last_purge_ms: i64,
}

impl From<trash_api::TrashMeta> for TrashMeta {
    fn from(m: trash_api::TrashMeta) -> Self {
        Self {
            retention_days: m.retention_days,
            last_purge_ms: m.last_purge_ms,
        }
    }
}

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// tick 周期：60s（判定轻量；实际清理每日最多一次）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动回收站 TTL 清理守护（幂等；Dart 在 DB 就绪后调用一次，BootGate 接线）
///
/// 每日最多实际清理一次；应用多日未开时下次启动首轮 tick 即补清。
pub fn start_trash_scheduler() {
    if SCHEDULER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    super::events::spawn_on_bridge_runtime(async {
        loop {
            tick_once().await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

async fn tick_once() {
    let Ok(pool) = pool() else {
        return; // DB 未就绪，静默跳过（下轮 tick 自动开始工作）
    };
    // 永久档/当日已清/无过期时内部静默返回
    if let Err(e) = trash_api::maybe_purge_expired(&pool).await {
        eprintln!("[trash-scheduler] TTL 清理失败（下轮重试）: {e}");
    }
    // 日志表 TTL（30 天；本地轨迹不进同步白名单，只进不出会持续涨表——
    // 桌面 trash_scheduler 同口径接线）
    const LOG_TTL_DAYS: i64 = 30;
    if let Err(e) = orbit_core::api::notification_log_api::prune_old(&pool, LOG_TTL_DAYS).await {
        eprintln!("[trash-scheduler] 通知日志 TTL 清理失败（下轮重试）: {e}");
    }
    if let Err(e) = orbit_core::api::activity_log_api::prune_old(&pool, LOG_TTL_DAYS).await {
        eprintln!("[trash-scheduler] 活动日志 TTL 清理失败（下轮重试）: {e}");
    }
}

// ── FRB 导出 ──

/// 回收站任务列表（最近删除排最前；对应桌面 trash_tasks_list）
pub async fn trash_tasks_list() -> Result<Vec<TodoTask>, String> {
    let pool = pool()?;
    let items = trash_api::list_trashed_tasks(&pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(items.into_iter().map(TodoTask::from).collect())
}

/// 恢复任务（原项目已删则落未分组；对应桌面 trash_task_restore）
pub async fn trash_task_restore(id: i64) -> Result<TodoTask, String> {
    let pool = pool()?;
    trash_api::restore_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
        .map(TodoTask::from)
}

/// 彻底删除单个回收站任务（对应桌面 trash_task_purge）
pub async fn trash_task_purge(id: i64) -> Result<(), String> {
    let pool = pool()?;
    trash_api::purge_todo_task(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

/// 清空回收站，返回删除数（对应桌面 trash_purge_all）
pub async fn trash_purge_all() -> Result<u64, String> {
    let pool = pool()?;
    trash_api::purge_all_trashed_tasks(&pool)
        .await
        .map_err(|e| e.to_string())
}

/// TTL 过期清理一次（对应桌面 trash_purge_expired；通常由守护触发）
pub async fn trash_purge_expired() -> Result<TrashPurgeStats, String> {
    let pool = pool()?;
    trash_api::maybe_purge_expired(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(TrashPurgeStats::from)
}

/// 回收站元数据（对应桌面 trash_meta）
pub async fn trash_meta() -> Result<TrashMeta, String> {
    let pool = pool()?;
    trash_api::trash_meta(&pool)
        .await
        .map_err(|e| e.to_string())
        .map(TrashMeta::from)
}

/// 设置保留天数（档位 7/30/90/0=永久；对应桌面 trash_set_retention_days）
pub async fn trash_set_retention_days(days: i64) -> Result<(), String> {
    let pool = pool()?;
    trash_api::set_trash_retention_days(&pool, days)
        .await
        .map_err(|e| e.to_string())
}
