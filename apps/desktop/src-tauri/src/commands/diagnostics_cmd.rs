//! diagnostics_cmd — 应用内诊断读数（只读，docs/09 内存专项「应用内诊断分区」）
//!
//! 薄壳包装 `orbit_core::api::diagnostics_api`：命令面只负责解析应用数据目录，
//! 读数逻辑全在 core（对齐 AGENTS「业务全部下沉 Rust 核心」）。
//!
//! 附件目录口径与 `asset_cmd` / `sync_runtime::attachments_dir` 同源——目录解析
//! 失败时降级为「不统计附件」而不是整条命令失败（诊断分区不该因为权限问题打不开）。

use orbit_core::api::diagnostics_api::{self, DiagnosticsSnapshot};
use tauri::Manager;

use crate::AppState;

#[tauri::command]
pub async fn diagnostics_snapshot(app: tauri::AppHandle) -> Result<DiagnosticsSnapshot, String> {
    let pool = app
        .try_state::<AppState>()
        .ok_or_else(|| "[database] 数据库未初始化".to_string())?
        .pool
        .clone();
    let attachments_dir = match crate::commands::data_dir::resolve_app_data_dir(&app) {
        Ok(dir) => crate::commands::sync_runtime::attachments_dir(&dir),
        Err(e) => {
            log::info!("[diagnostics] 应用数据目录不可用，本次不统计附件缓存: {e}");
            String::new()
        }
    };
    diagnostics_api::diagnostics_snapshot(&pool, &attachments_dir)
        .await
        .map_err(|e| e.to_string())
}
