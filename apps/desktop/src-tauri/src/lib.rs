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

// 移动端已拆分为独立 Flutter 应用（apps/mobile），本壳仅服务桌面，
// 不再声明 tauri::mobile_entry_point。
pub fn run() {
    // WebView2 内存参数（2026-09-12 F5/M3，Windows）：
    // - --js-flags=--max-old-space-size=512：V8 老生代上限 512MB——万级任务
    //   驻留数据下默认堆无界增长后 WebView2 不主动裁剪（09-10 实测隐藏
    //   75s 不降反升）；设上限促 GC 压实，防长驻会话堆缓慢膨胀。
    // - --disk-cache-size=52428800：磁盘缓存 50MB 封顶，防附件/图片
    //   预览撑大 cache 目录。
    // 仅 Windows WebView2 生效（macOS WKWebView / Linux webkitgtk 忽略），
    // 须在 webview 创建前设置，故放 run() 最前。
    #[cfg(target_os = "windows")]
    {
        const ARGS: &str =
            "--js-flags=--max-old-space-size=512 --disk-cache-size=52428800";
        // 已有外部覆盖（调试场景）时不强写。set_var 在 Rust 2024 是 unsafe：
        // 安全前提 = run() 由 main 单线程进入、此时尚无其他线程存活
        // （Tauri runtime/守护线程都在 builder.run 之后才起）。
        if std::env::var_os("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").is_none() {
            unsafe { std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", ARGS) };
        }
    }

    // 通用插件：双端无条件注册
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_notification::init())
        // 日志插件（S10，2026-09-13 探查）：依赖早已声明但从未注册——
        // orbit-core 引擎全部 log::info!（探针/rekey/with_retry 重试记录）
        // 此前无处输出，同步失败零引擎侧日志可查。
        // targets=stdout+logdir：dev 可见 + 用户报障可取 app_log.log。
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::LogDir {
                        file_name: Some("app_log".into()),
                    }),
                ])
                .level(log::LevelFilter::Info)
                .build(),
        );

    // 桌面专属插件：window-state（窗口状态文件跟随数据目录，数据目录迁移后不丢）
    #[cfg(desktop)]
    let builder = builder.plugin(
        tauri_plugin_window_state::Builder::default()
            .with_filename(data_dir::window_state_file_early())
            .build(),
    );

    // 全局热键插件（07 #16 快速捕捉）：热键由前端 use-global-quick-add
    // 注册（Alt+Shift+O：唤起主窗 + 聚焦快速输入栏）
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_global_shortcut::Builder::new().build());

    // 关窗驻留拦截（07 报告 #16 托盘配套）：关闭主窗 = 隐藏驻留托盘，
    // 退出走托盘菜单；避免中断同步/备份调度器与提醒轮询守护。
    // tray_close_hint 事件驱动前端首次提示（localStorage 记忆不再骚扰）。
    // 隐藏即降 WebView2 内存档位 Low + 排程超时回收（唤起取消，见
    // webview_low_power / window_recycler）。
    // ExitRequested 拦截：窗口回收销毁最后一窗时 tauri 默认请求退出，
    // 须阻止（进程留守护）；真退出走托盘 quit_app（mark_quitting 放行）。
    builder
        .on_window_event(|window, event| {
            #[cfg(desktop)]
            {
                use tauri::Emitter as _;
                if window.label() == "main"
                    && let tauri::WindowEvent::CloseRequested { api, .. } = event
                {
                    let _ = window.emit("tray-close-hint", ());
                    window.hide().ok();
                    commands::webview_low_power::set_memory_usage_level(window.app_handle(), true);
                    commands::window_recycler::schedule_recycle_on_hide(window.app_handle());
                    api.prevent_close();
                }
            }
        })
        .setup(|_app| {
            // 系统托盘（07 报告 #16）：菜单=显示主窗/快速新建/退出，
            // 快速新建经 tray-quick-add 事件由前端聚焦快速输入栏
            #[cfg(desktop)]
            if let Err(e) = commands::tray::setup_tray(_app.handle()) {
                eprintln!("[tray] 托盘初始化失败（不影响主功能）: {e}");
            }

            // Mica 云母材质：绕过 Tauri 原生 windowEffects 在无边框窗口上的局限，
            // 直接在窗口就绪阶段通过 Windows DWM API 设置 DWMSBT_MAINWINDOW。
            // 亮暗切换由前端 use-mica-effect 经 apply_mica/disable_mica 联动。
            #[cfg(all(desktop, target_os = "windows"))]
            if let Err(e) = mica_cmd::apply_mica_dwm(_app.handle()) {
                eprintln!("[mica] dwm apply failed: {e}");
            }

            // Windows Toast 通知身份注册（AUMID DisplayName=Orbit + 图标）+
            // 清除上次退出前的计划通知：都是首窗显示后才可能被消费的通道
            // （AUMID 含 PNG 编码写盘+注册表写、清理是 WinRT COM 遍历——
            // 合计几十 ms 同步 IO），丢后台线程不挡 setup 返回（首帧关键
            // 路径）；两者均无需在任何 UI 前完成，失败本就静默。
            #[cfg(target_os = "windows")]
            {
                let handle = _app.handle().clone();
                std::thread::spawn(move || {
                    commands::aumid_registry::register_aumid_identity(&handle);
                    // 清除计划通知（运行中由轮询通道接管，防双弹）
                    commands::scheduled_toast::clear_schedule_on_startup();
                });
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

            // 节假日自动更新守护（60s tick；每日固定时刻一次，错过启动即补更）
            commands::holiday_scheduler::holiday_scheduler_start(_app.handle().clone());

            // 回收站 TTL 清理守护（60s tick；每日最多一次，启动首轮即补清）
            commands::trash_scheduler::trash_scheduler_start(_app.handle().clone());

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
            todo_cmd::todo_tasks_complete,
            todo_cmd::todo_tasks_duplicate,
            commands::todo_cmd::global_search,
            // Mica 云母材质（Windows DWM 直调；setup 阶段已应用，此处供主题联动兜底）
            mica_cmd::apply_mica,
            mica_cmd::disable_mica,
            mica_cmd::mica_diagnostics,
            // M3 安全与同步：同步密码 / Data Key
            commands::sync_crypto_cmd::sync_crypto_status,
            commands::sync_crypto_cmd::sync_crypto_meta_version,
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
            commands::sync_crypto_cmd::sync_crypto_upgrade_v2,
            // M3：连接配置
            commands::sync_cmd::sync_config_get,
            commands::sync_cmd::sync_config_save,
            commands::sync_cmd::sync_test_connection,
            // M3：云同步执行
            // 节假日数据（日历视图）
            commands::holiday_cmd::holidays_list,
            commands::holiday_cmd::holiday_is_on,
            commands::holiday_cmd::holidays_update,
            commands::holiday_cmd::holiday_meta,
            commands::holiday_cmd::holiday_set_fixed_hour,
            commands::cloud_sync_cmd::cloud_sync_now,
            commands::cloud_sync_cmd::cloud_sync_push_only,
            commands::cloud_sync_cmd::cloud_sync_pull_then_push,
            // 增量同步历史（P1-17：设置页同步历史卡数据源）
            commands::cloud_sync_cmd::cloud_sync_history,
            commands::cloud_sync_cmd::cloud_sync_get_state,
            commands::cloud_sync_cmd::cloud_sync_is_running,
            commands::cloud_sync_cmd::cloud_sync_rekey,
            commands::cloud_sync_cmd::sync_disconnect,
            // M3：全量备份
            commands::full_sync_cmd::full_backup_export,
            commands::full_sync_cmd::full_backup_import,
            commands::full_sync_cmd::full_backup_list_local,
            commands::full_sync_cmd::full_backup_device_info,
            // 明文数据导出（07 报告 #15：JSON 结构化 / CSV 任务视图）
            commands::plaintext_export_cmd::plaintext_export_json,
            commands::plaintext_export_cmd::plaintext_export_csv,
            // ICS 日历导出（#4：VTODO 日历，日历软件导入/订阅）
            commands::ics_export_cmd::ics_export,
            // 通知历史（#5：呈现轨迹回看）
            commands::activity_log_cmd::task_activity_list,
            commands::notification_log_cmd::notification_log_list,
            commands::notification_log_cmd::notification_log_clear,
            // CSV 导入（迁移路径：orbit 自有 / Todoist / TickTick）
            commands::csv_import_cmd::csv_import_preview,
            commands::csv_import_cmd::csv_import_execute,
            // 定时自动备份偏好（backup_scheduler 守护的数据源）
            commands::backup_scheduler::backup_prefs_get,
            commands::backup_scheduler::backup_prefs_save,
            // 回收站（任务软删恢复 + 保留时间 + TTL 清理）
            commands::trash_cmd::trash_tasks_list,
            commands::trash_cmd::trash_task_restore,
            commands::trash_cmd::trash_task_purge,
            commands::trash_cmd::trash_purge_all,
            commands::trash_cmd::trash_purge_expired,
            commands::trash_cmd::trash_meta,
            commands::trash_cmd::trash_set_retention_days,
            // 统计仪表盘（backlog #25：总览/热力图/连续天数/分布）
            commands::stats_cmd::stats_aggregate,
            // 保存的筛选器（#35：Apple Smart List 同款可保存组合条件视图）
            commands::saved_filter_cmd::saved_filters_list,
            commands::saved_filter_cmd::saved_filter_create,
            commands::saved_filter_cmd::saved_filter_update,
            commands::saved_filter_cmd::saved_filter_delete,
            // 任务模板（竞品矩阵高价值缺口：Vikunja Templates 同款可复用任务骨架）
            commands::template_cmd::templates_list,
            commands::template_cmd::template_create,
            commands::template_cmd::template_update,
            commands::template_cmd::template_delete,
            // 任务附件（上传/列表/读取/卸下 + 本地 GC）
            commands::asset_cmd::task_attachment_add,
            commands::asset_cmd::task_attachments_list,
            commands::asset_cmd::task_attachment_read,
            commands::asset_cmd::task_attachment_remove,
            commands::asset_cmd::attachments_gc,
            // 数据库维护（WAL checkpoint / 附件 GC / 查询统计 / VACUUM）
            commands::db_maintenance_cmd::db_maintenance,
            // 主窗唤起（全局热键；窗口被超时回收后走重建路径）
            commands::window_recycler::show_main_window_cmd,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app, event| {
            // 托盘驻留 + 窗口回收：最后一窗被销毁时 tauri 默认请求退出，
            // 须阻止（进程要留守护）；真退出走托盘 quit_app（mark_quitting
            // 放行）或系统终止。
            #[cfg(desktop)]
            if let tauri::RunEvent::ExitRequested { api, .. } = event
                && !commands::window_recycler::is_quitting()
            {
                api.prevent_exit();
            }
        });
}
