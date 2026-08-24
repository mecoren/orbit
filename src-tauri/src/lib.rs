//! orbit_desktop_lib — Tauri 2 桌面端壳入口（Orbit / 循迹）
//!
//! 职责：建立 Tauri 应用骨架，持有 SqlitePool，注册命令面，转发事件总线。
//! 业务逻辑全部在 orbit_core，本文件不含业务逻辑。
//!
//! 数据库延迟到 db_init_plaintext / db_init_encrypted 命令中初始化，
//! 由前端启动流程触发（未设置主密码 → 明文；已设置 → 解锁后加密）。
//!
//! 暂未平移（按里程碑推进）：
//! - mica_cmd / font_cmd（Windows 壳增强，M0.5/M2 取舍）
//! - （M3 安全与同步已平移：sync_cmd / sync_crypto_cmd / cloud_sync_cmd /
//!   full_sync_cmd + sync_runtime 单例 + sync_scheduler 60s tick 守护）
//! - （提醒轮询守护已平移：commands/notification_scheduler.rs 专用 SQL 版）
//! - （定时备份守护已接线：commands/backup_scheduler.rs，core v4 调度器）

mod commands;

use commands::notification_scheduler;
use commands::sync_runtime::SyncRuntime;
use tauri::Manager;

#[cfg(desktop)]
use commands::data_dir;
use commands::{business_cmd, crypto_cmd, db_cmd, mica_cmd, todo_cmd};
use sqlx::SqlitePool;

/// 应用全局状态：持有数据库连接池供所有 command 共享
///
/// 由 db_init_plaintext / db_init_encrypted 命令 manage 到 Tauri State；
/// 此前依赖 State<'_, AppState> 的命令会因状态未注册而失败。
pub struct AppState {
    pub pool: SqlitePool,
}

impl AppState {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 通用插件：双端无条件注册
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_notification::init());

    // 桌面专属插件：window-state（窗口状态文件跟随数据目录，数据目录迁移后不丢）
    #[cfg(desktop)]
    let builder = builder.plugin(
        tauri_plugin_window_state::Builder::default()
            .with_filename(data_dir::window_state_file_early())
            .build(),
    );

    builder
        .setup(|_app| {
            // Mica 云母材质：绕过 Tauri 原生 windowEffects 在无边框窗口上的局限，
            // 直接在窗口就绪阶段通过 Windows DWM API 设置 DWMSBT_MAINWINDOW。
            // 亮暗切换由前端 use-mica-effect 经 apply_mica/disable_mica 联动。
            #[cfg(all(desktop, target_os = "windows"))]
            if let Err(e) = mica_cmd::apply_mica_dwm(_app.handle()) {
                eprintln!("[mica] dwm apply failed: {e}");
            }

            // 启动待办提醒轮询守护（每 20s 一轮；DB 就绪后自动工作；
            // 全平台启动——此前误嵌 Mica 失败分支导致成功路径下守护不运行）
            notification_scheduler::todo_reminder_start_poller(_app.handle().clone());

            // M3 同步域：manage 单例运行时 + 注册全局加密配置存储（钥匙串 CEK）+
            // 启动定时同步守护（60s tick，DB/配置/解锁三前置就绪才触发）
            _app.manage(SyncRuntime::default());
            if let Err(e) = commands::sync_runtime::register_global_encrypted_storage(_app.handle())
            {
                eprintln!("[sync-runtime] 加密配置存储注册失败（降级明文）: {e}");
            }
            commands::sync_scheduler::sync_scheduler_start(_app.handle().clone());
            commands::sync_scheduler::sync_on_change_watcher_start(_app.handle().clone());

            // 定时全量备份守护（60s tick；core v4 调度器接线，
            // 钥匙串缓存同步密码作为加密口令，无缓存时静默等待）
            // 桌面专属：依赖钥匙串密码缓存，移动端无持久凭据库
            #[cfg(desktop)]
            commands::backup_scheduler::backup_scheduler_start(_app.handle().clone());

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // 探针
            crypto_cmd::ping,
            // 主密码认证（M1.3）
            crypto_cmd::master_auth_has,
            crypto_cmd::master_auth_init,
            crypto_cmd::master_auth_unlock,
            crypto_cmd::master_auth_verify,
            crypto_cmd::master_auth_change_password,
            crypto_cmd::master_auth_clear,
            // 通用加密工具
            crypto_cmd::crypto_sha256,
            crypto_cmd::crypto_random_hex,
            // 数据库生命周期（M1.2）+ 全局上下文
            db_cmd::db_init_plaintext,
            db_cmd::db_init_encrypted,
            db_cmd::db_is_ready,
            db_cmd::db_migrate_to_plaintext,
            db_cmd::db_migrate_to_encrypted,
            db_cmd::db_set_device_id,
            db_cmd::db_get_device_id,
            // todo_projects
            business_cmd::todo_projects_list,
            business_cmd::todo_projects_get,
            business_cmd::todo_projects_create,
            business_cmd::todo_projects_update,
            business_cmd::todo_projects_delete,
            business_cmd::todo_projects_get_by_uuid,
            // todo_tasks
            business_cmd::todo_tasks_list,
            business_cmd::todo_tasks_get,
            business_cmd::todo_tasks_create,
            business_cmd::todo_tasks_update,
            business_cmd::todo_tasks_delete,
            business_cmd::todo_tasks_get_by_uuid,
            // todo_subtasks
            business_cmd::todo_subtasks_list,
            business_cmd::todo_subtasks_get,
            business_cmd::todo_subtasks_create,
            business_cmd::todo_subtasks_update,
            business_cmd::todo_subtasks_delete,
            // todo_labels
            business_cmd::todo_labels_list,
            business_cmd::todo_labels_get,
            business_cmd::todo_labels_create,
            business_cmd::todo_labels_update,
            business_cmd::todo_labels_delete,
            // todo_task_labels
            business_cmd::todo_task_labels_list,
            business_cmd::todo_task_labels_get,
            business_cmd::todo_task_labels_create,
            business_cmd::todo_task_labels_delete,
            // todo_comments
            business_cmd::todo_comments_list,
            business_cmd::todo_comments_get,
            business_cmd::todo_comments_create,
            business_cmd::todo_comments_delete,
            // todo_task_relations
            business_cmd::todo_task_relations_list,
            business_cmd::todo_task_relations_get,
            business_cmd::todo_task_relations_create,
            business_cmd::todo_task_relations_delete,
            // todo_reminders
            business_cmd::todo_reminders_list,
            business_cmd::todo_reminders_get,
            business_cmd::todo_reminders_create,
            business_cmd::todo_reminders_delete,
            // cfg_feature_modules（壳导航/强调色数据源）
            business_cmd::feature_module_list,
            business_cmd::feature_module_list_active,
            business_cmd::feature_module_list_enabled,
            business_cmd::feature_module_get,
            business_cmd::feature_module_get_by_key,
            business_cmd::feature_module_update_sort_order,
            business_cmd::feature_module_update_enabled,
            business_cmd::feature_module_delete,
            // 计数（列表页角标）
            business_cmd::business_count,
            // todo_cmd 复杂查询（7 组）
            todo_cmd::todo_tasks_get_detail,
            todo_cmd::todo_subtasks_toggle_done,
            todo_cmd::todo_tasks_update_position,
            todo_cmd::todo_projects_update_sort_order,
            todo_cmd::todo_tasks_kanban_by_project,
            todo_cmd::todo_tasks_kanban_by_status,
            todo_cmd::todo_tasks_recalc_percent,
            // Mica 云母材质（Windows DWM 直调；setup 阶段已应用，此处供主题联动兜底）
            mica_cmd::apply_mica,
            mica_cmd::disable_mica,
            mica_cmd::mica_diagnostics,
            // M3 安全与同步：同步密码 / Data Key
            commands::sync_crypto_cmd::sync_crypto_status,
            commands::sync_crypto_cmd::sync_crypto_init,
            commands::sync_crypto_cmd::sync_crypto_unlock,
            commands::sync_crypto_cmd::sync_crypto_lock,
            commands::sync_crypto_cmd::sync_crypto_change_password,
            // （不注册 rotate_key：多设备同步场景下轮换 Data Key 会令其他设备
            //   全部失效，产品决策不暴露；core 库层能力保留）
            commands::sync_crypto_cmd::sync_crypto_export_bundle,
            commands::sync_crypto_cmd::sync_crypto_import_bundle,
            commands::sync_crypto_cmd::sync_crypto_restore_session,
            commands::sync_crypto_cmd::sync_crypto_forget_session,
            // M3：连接配置
            commands::sync_cmd::sync_config_get,
            commands::sync_cmd::sync_config_save,
            commands::sync_cmd::sync_test_connection,
            // M3：云同步执行
            commands::cloud_sync_cmd::cloud_sync_now,
            commands::cloud_sync_cmd::cloud_sync_push_only,
            commands::cloud_sync_cmd::cloud_sync_pull_then_push,
            commands::cloud_sync_cmd::cloud_sync_get_state,
            commands::cloud_sync_cmd::cloud_sync_is_running,
            commands::cloud_sync_cmd::sync_disconnect,
            // M3：全量备份
            commands::full_sync_cmd::full_backup_export,
            commands::full_sync_cmd::full_backup_import,
            commands::full_sync_cmd::full_backup_list_local,
            commands::full_sync_cmd::full_backup_device_info,
            // 定时自动备份偏好（backup_scheduler 守护的数据源）
            commands::backup_scheduler::backup_prefs_get,
            commands::backup_scheduler::backup_prefs_save,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
