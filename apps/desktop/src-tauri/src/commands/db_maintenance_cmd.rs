//! db_maintenance_cmd — 数据库维护命令（性能批次：磁盘维护 + 碎片整理）
//!
//! 薄壳包装 orbit_core::api::db_maintenance_api：
//! - `db_maintenance`：一条命令跑全套维护（WAL checkpoint → 附件 GC →
//!   全量 ANALYZE → VACUUM），返回量化结果供设置页展示。
//! - `spawn_idle_maintenance`：启动后空闲时机跑一次轻维护（WAL checkpoint →
//!   附件 GC → 缓存上限 → 日志 TTL → 统计仅在缺失时）——不是命令，由
//!   `lib.rs` 的 setup 直接调用。
//!
//! 只读维护路径：不 emit db-change（前端缓存无需失效），不进同步白名单。

use std::time::Duration;

use orbit_core::api::db_maintenance_api::{self, DbMaintenanceResult};
use tauri::Manager;

use crate::AppState;

/// 首屏之后再等多久才去跑轻维护
///
/// 取值理由：首位列表查询在首帧后几十毫秒内就会发出，而这套维护里最重的两步
/// （全量 `ANALYZE` 50k 行 47～88ms、附件 LRU 扫描）会直接吃掉 P1「首屏可交互
/// < 1.5s」的预算。15s 后用户基本已进入正常操作节奏，且「空闲时不抢 IO」比
/// 「尽早做完」更重要（收益是每次列表 10ms / 磁盘不再无界增长，晚 15s 无感）。
const IDLE_DELAY_SECS: u64 = 15;

/// 启动后空闲时机跑一次轻维护（docs/13 §七 P5 / docs/09 §八）
///
/// 走 core 的 `db_maintenance_routine`：成本与库体积无关、不跑就会无界增长的
/// 那几步（-wal 帧、孤儿附件文件、超 2GB 附件缓存、只进不出的日志表）在每次
/// 启动后收一次；`VACUUM` 不在此路径（手动「立即维护」才无条件跑）。
///
/// 与移动端 `boot_gate` 同一函数、同一顺序，避免双端维护口径漂移。
/// 失败只记日志：维护是纯优化项，缺它不影响任何正确性——绝不因为维护失败
/// 去打扰用户或阻断启动。
pub fn spawn_idle_maintenance(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(IDLE_DELAY_SECS)).await;
        let Some(state) = app.try_state::<AppState>() else {
            return; // DB 未就绪（或已卸载），静默跳过
        };
        let pool = state.pool.clone();
        let dir = match crate::commands::data_dir::resolve_app_data_dir(&app) {
            Ok(d) => d,
            Err(e) => {
                log::warn!("[maintenance] 启动轻维护跳过（数据目录不可用）: {e}");
                return;
            }
        };
        let attachments_dir = crate::commands::sync_runtime::attachments_dir(&dir);
        match db_maintenance_api::db_maintenance_routine(&pool, &attachments_dir).await {
            Ok(r) => {
                if r.attachments_cleaned > 0 || r.log_rows_pruned > 0 {
                    log::info!(
                        "[maintenance] 启动轻维护完成：孤儿附件 {} 个、过期日志 {} 行、-wal 剩余 {} 字节",
                        r.attachments_cleaned,
                        r.log_rows_pruned,
                        r.wal_bytes_after_checkpoint
                    );
                }
            }
            Err(e) => log::warn!("[maintenance] 启动轻维护失败（不影响功能）: {e}"),
        }
    });
}

/// 执行全套数据库维护（WAL checkpoint / 附件 GC / 查询统计 / VACUUM）
#[tauri::command]
pub async fn db_maintenance(app: tauri::AppHandle) -> Result<DbMaintenanceResult, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let dir = crate::commands::data_dir::resolve_app_data_dir(&app)?;
    let attachments_dir = crate::commands::sync_runtime::attachments_dir(&dir);
    db_maintenance_api::db_maintenance(&pool, &attachments_dir)
        .await
        .map_err(|e| format!("[maintenance] {e}"))
}
