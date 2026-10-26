//! orbit_desktop_lib — Tauri 2 桌面端壳入口（显示名「循迹」/ 进程名 orbit）
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

/// 探测日志目录是否可写（决定 log 插件是否挂 LogDir 目标）
///
/// 路径口径与 Tauri 的 `app_log_dir()` 一致：macOS 取 `~/Library/Logs/<bundle identifier>`，
/// 其余平台取 `data_local_dir()/<bundle identifier>/logs`。注意这里用的是**发布标识**
/// `cn.wait.orbit`：dev 构建的库虽落在 `.dev` 目录，日志仍写发布目录
/// （Tauri 只认 tauri.conf.json 的 identifier）。
///
/// 探测方式 = 按插件自身的方式建目录 + 追加打开 `app_log.log`
/// （插件用 `dir.join(file_name).with_extension("log")`），任一步失败即判不可写。
/// 动因：tauri-plugin-log 的 LogDir 目标初始化失败会让整个 `Builder::build()`
/// 返回 Err，只读 AppData（企业策略 / 受限沙箱 / 磁盘满）下日志旁路会把启动带崩。
fn log_dir_writable() -> bool {
    #[cfg(target_os = "macos")]
    let dir = dirs::home_dir()
        .map(|home| home.join("Library/Logs").join(commands::data_dir::APP_IDENTIFIER));
    #[cfg(not(target_os = "macos"))]
    let dir = dirs::data_local_dir()
        .map(|base| base.join(commands::data_dir::APP_IDENTIFIER).join("logs"));
    let Some(dir) = dir else {
        return false;
    };
    if !dir.exists() && std::fs::create_dir_all(&dir).is_err() {
        return false;
    }
    let ok = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("app_log.log"))
        .is_ok();
    if !ok {
        // logger 此时尚未安装，只能走 stderr（dev 终端 / 打包后丢弃）
        eprintln!(
            "[log] 日志目录不可写，本次仅输出到 stdout: {}",
            dir.display()
        );
    }
    ok
}

/// window-state 插件的状态标志：位置/尺寸/最大化/装饰/全屏，**刻意剔除 VISIBLE**
///
/// 保留 VISIBLE 会让插件在 `on_window_ready`（WebView 还没加载出首帧）就
/// `show() + set_focus()`：冷启动直接绕过 `tauri.conf.json` 的 `visible: false`，
/// 闪出一帧空壳窗（透明窗无内容，观感即白屏/闪窗）——尤其状态文件缺失时走
/// `WindowState::default()`（`visible: true`）必现；开机自启 `--hidden` 的静默
/// 驻留也会被它强行弹窗，与前端 startup_cmd 判定相悖。
/// 显隐时机统一归前端 `main.tsx`（探 startup_launched_hidden 后再 show），
/// 壳层与插件只负责几何状态。窗口回收重建路径的 `restore_state` 复用同一组
/// 标志（src/commands/window_recycler.rs），两处口径不得漂移。
#[cfg(desktop)]
pub(crate) fn window_state_flags() -> tauri_plugin_window_state::StateFlags {
    use tauri_plugin_window_state::StateFlags;
    StateFlags::all() & !StateFlags::VISIBLE
}

// 移动端已拆分为独立 Flutter 应用（apps/mobile），本壳仅服务桌面，
// 不再声明 tauri::mobile_entry_point。
pub fn run() {
    // WebView2 内存参数（2026-09-12 F5/M3，Windows）：
    // - --disk-cache-size=52428800：磁盘缓存 50MB 封顶，防附件/图片
    //   预览撑大 cache 目录。
    //
    // 2026-10-14（内存专项 A12）**删掉**原 `--js-flags=--max-old-space-size=512`：
    // V8 老生代限额属「治标且可能把 OOM 变成用户可见崩溃」，ADR 0006 §五已否决，
    // 本轮把残留参数清掉。当初设它的动因是万级任务下堆只增不减（09-10 实测隐藏
    // 75s 不降反升），该线性项已由 A14（逾期置顶段并入同一条虚拟流）从源头消除，
    // 并有 `perf-metrics/growth-curve.mjs` 门禁拦回退——不再需要靠限额促 GC。
    // 仅 Windows WebView2 生效（macOS WKWebView / Linux webkitgtk 忽略），
    // 须在 webview 创建前设置，故放 run() 最前。
    #[cfg(target_os = "windows")]
    {
        const ARGS: &str = "--disk-cache-size=52428800";
        // 已有外部覆盖（调试场景）时不强写。set_var 在 Rust 2024 是 unsafe：
        // 安全前提 = run() 由 main 单线程进入、此时尚无其他线程存活
        // （Tauri runtime/守护线程都在 builder.run 之后才起）。
        if std::env::var_os("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").is_none() {
            unsafe { std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", ARGS) };
        }
    }

    // 通用插件：双端无条件注册。
    // 日志插件（S10）不在此链上——见 setup 开头的运行时注册及其注释。
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
            .with_state_flags(window_state_flags())
            .build(),
    );

    // 全局热键插件（07 #16 快速捕捉）：热键由前端 use-global-quick-add
    // 注册（Alt+Shift+O：唤起主窗 + 聚焦快速输入栏）
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_global_shortcut::Builder::new().build());

    // 应用内更新（07 backlog #20，tauri-plugin-updater）：检查/下载/安装
    // 由前端设置页驱动（updater-section）；endpoint 走 GitHub Releases 的
    // latest.json（release.yml createUpdaterArtifacts 产出）。签名密钥未
    // 注入时产物不签名——更新包安装会被 updater 校验拒绝，设置页检查
    // 更新将提示未配置（ADR 0004「物料未注入走未签名路径」口径）。
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_updater::Builder::new().build());

    // process 插件（updater 配套）：安装完成后 relaunch 重启进新版本
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_process::init());

    // 开机自启（07 backlog #51，tauri-plugin-autostart）：设置页「通用」开关
    // 读写系统注册项（Windows HKCU Run / macOS LaunchAgent plist / Linux XDG
    // .desktop）；args 注入 --hidden，自启拉起走静默驻留形态（startup_cmd）。
    // 已知口径：底层 auto-launch 在 Windows 拼注册值时不给路径加引号，
    // 安装路径含空格（Program Files / 用户名带空格）时自启会被系统解析坏。
    #[cfg(desktop)]
    let builder = builder.plugin(
        tauri_plugin_autostart::Builder::new()
            .args(["--hidden"])
            .build(),
    );

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
                    // 托盘不可用（Low 完整性 / IDE 终端降权启动，Shell_NotifyIcon
                    // 被拒）时「关窗驻留」= 幽灵进程：没有托盘入口，用户只能靠
                    // 全局热键或任务管理器找回。此时关闭即真退出——mark_quitting
                    // 放行 run 回调里的 ExitRequested 拦截。数据无虞（本地库已写，
                    // 云同步由 60s 调度器与下次启动兜底）。
                    if !commands::tray::is_tray_available() {
                        commands::window_recycler::mark_quitting();
                        return;
                    }
                    let _ = window.emit("tray-close-hint", ());
                    window.hide().ok();
                    commands::webview_low_power::set_memory_usage_level(window.app_handle(), true);
                    commands::window_recycler::schedule_recycle_on_hide(window.app_handle());
                    api.prevent_close();
                }
            }
        })
        .setup(|_app| {
            // 日志插件（S10，2026-09-13 探查）：依赖早已声明但从未注册——
            // orbit-core 引擎全部 log::info!（探针/rekey/with_retry 重试记录）
            // 此前无处输出，同步失败零引擎侧日志可查。
            // targets=stdout+logdir：dev 可见 + 用户报障可取 app_log.log。
            //
            // 2026-10-22 改为 setup 期运行时注册（AppHandle::plugin）：
            // 挂在 Builder 主链上时，LogDir 打不开日志文件会让
            // Builder::build() 整体失败，壳入口 .expect() 直接 panic——
            // 窗口/托盘/守护全都不出现（当日实测：预探通过后插件仍可能
            // 撞上瞬时拒绝访问 os error 5，预探挡不住这个窗口）。日志只是
            // 旁路观测，不该有否决启动的权力：注册失败仅丢日志。预探
            // （log_dir_writable）仍保留——不可写时优雅退化为仅 stdout，
            // 不打错误行。
            if let Err(e) = _app.handle().plugin({
                let mut targets =
                    vec![tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout)];
                if log_dir_writable() {
                    targets.push(tauri_plugin_log::Target::new(
                        tauri_plugin_log::TargetKind::LogDir {
                            file_name: Some("app_log".into()),
                        },
                    ));
                }
                tauri_plugin_log::Builder::new()
                    .targets(targets)
                    .level(log::LevelFilter::Info)
                    .build()
            }) {
                eprintln!("[log] 日志插件注册失败（不影响启动，仅无日志）: {e}");
            }

            // 系统托盘（07 报告 #16）：菜单=显示主窗/快速新建/退出，
            // 快速新建经 tray-quick-add 事件由前端聚焦快速输入栏
            #[cfg(desktop)]
            if let Err(e) = commands::tray::setup_tray(_app.handle()) {
                eprintln!("[tray] 托盘初始化失败（不影响主功能）: {e}");
            }

            // 开机自启拉起（注册项带 --hidden）：静默驻留形态——前端
            // main.tsx 经 startup_launched_hidden 命令判定后跳过主窗 show，
            // 壳层同步接上隐藏回收链（降 WebView2 档位 + 排程超时销毁），
            // 窗口回收后进程与四个守护继续常驻（内存 ~330MB → ~40MB），
            // 托盘/热键唤起走 window_recycler 重建，与关窗驻留同一路径。
            if commands::startup_cmd::resolve_launch_mode() {
                commands::webview_low_power::set_memory_usage_level(_app.handle(), true);
                commands::window_recycler::schedule_recycle_on_hide(_app.handle());
            }

            // 冷启动显隐安全网：主窗 visible:false，显示完全依赖前端 main.tsx
            // 的 show()。前端链路任何一环失败（权限被拒 / JS 异常 / devUrl 不可达）
            // 窗口就永不出现——「不出现」比「迟 8 秒出现」严重得多，8 秒仍不可见
            // 即由壳层兜底 show。--hidden 自启（静默驻留）不适用本兜底。
            // 窗口重建路径无需覆盖：重建后 webview 重跑启动链，失败可经托盘/热键
            // 的 Rust 侧 show_main_window_cmd 唤起。
            #[cfg(desktop)]
            {
                let handle = _app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(8));
                    if commands::startup_cmd::is_launched_hidden() {
                        return;
                    }
                    if let Some(win) = handle.get_webview_window("main")
                        && !win.is_visible().unwrap_or(true)
                    {
                        eprintln!("[startup] 前端 show 未达（8s 兜底），主窗由壳层显示");
                        let _ = win.show();
                    }
                });
            }

            // Mica 云母材质：绕过 Tauri 原生 windowEffects 在无边框窗口上的局限，
            // 直接在窗口就绪阶段通过 Windows DWM API 设置 DWMSBT_MAINWINDOW。
            // 亮暗切换由前端 use-mica-effect 经 apply_mica/disable_mica 联动。
            #[cfg(all(desktop, target_os = "windows"))]
            if let Err(e) = mica_cmd::apply_mica_dwm(_app.handle()) {
                eprintln!("[mica] dwm apply failed: {e}");
            }

            // Windows Toast 通知身份注册（AUMID DisplayName=循迹 + 图标）+
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
            // F80：DB Key hex 进程内暂存区（解锁/初始化解出 → db_init_* 取用，
            // 密钥材料不穿过 webview）
            _app.manage(commands::crypto_cmd::PendingDbKey(
                std::sync::Mutex::new(None),
            ));
            if let Err(e) = commands::sync_runtime::register_global_encrypted_storage(_app.handle())
            {
                eprintln!("[sync-runtime] 加密配置存储注册失败（降级明文）: {e}");
            }
            commands::sync_scheduler::sync_scheduler_start(_app.handle().clone());
            commands::sync_scheduler::sync_on_change_watcher_start(_app.handle().clone());

            // 节假日自动更新守护（60s tick；每月一次，跨月首次启动即补更）
            commands::holiday_scheduler::holiday_scheduler_start(_app.handle().clone());
            // 节假日范围补写进度泵（转发 core 进度广播为 holiday-progress 事件）
            commands::holiday_scheduler::holiday_progress_pump_start(_app.handle().clone());

            // 回收站 TTL 清理守护（60s tick；每日最多一次，启动首轮即补清）
            commands::trash_scheduler::trash_scheduler_start(_app.handle().clone());

            // 首屏之后的空闲时机补一次查询计划统计（docs/13 §七 P5）：
            // 只在「从来没建过统计 + 数据到门槛」时真跑，跑过之后每次启动零成本。
            // 刻意延迟 15s，不与首屏首个列表查询抢预算（全量 ANALYZE 50k 47～88ms）。
            commands::db_maintenance_cmd::spawn_idle_plan_stats(_app.handle().clone());

            // 每日摘要提醒守护（60s tick；每日一次，2026-09-30 G3）
            commands::digest_scheduler::digest_scheduler_start(_app.handle().clone());

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
            business_cmd::todo_projects_list_archived,
            business_cmd::todo_projects_delete,
            business_cmd::todo_projects_get_by_uuid,
            // 项目回顾节奏（F1）
            business_cmd::todo_projects_due_for_review,
            business_cmd::todo_project_mark_reviewed,
            business_cmd::todo_project_set_review_interval,
            business_cmd::todo_project_snooze_review,
            // todo_tasks
            business_cmd::todo_tasks_list,
            business_cmd::todo_tasks_page,
            business_cmd::todo_task_overview,
            business_cmd::todo_tasks_board,
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
            todo_cmd::todo_subtasks_promote,
            todo_cmd::todo_tasks_update_position,
            todo_cmd::todo_projects_update_sort_order,
            todo_cmd::todo_tasks_recalc_percent,
            todo_cmd::todo_tasks_complete,
            todo_cmd::todo_tasks_duplicate,
            commands::todo_cmd::global_search,
            // 任务列表投影聚合（A4，只读：标签/提醒/关联旗标一次往返；
            // #71 加附件/未完成子任务存在旗标——筛选器存在键数据源）
            todo_cmd::task_labels_projection,
            todo_cmd::task_reminders_projection,
            todo_cmd::task_dependency_flags,
            todo_cmd::task_attachment_flags,
            todo_cmd::task_open_subtask_flags,
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
            commands::holiday_cmd::holiday_fetch_year,
            commands::holiday_cmd::holiday_fetch_range,
            commands::holiday_cmd::holiday_cancel_fetch,
            commands::holiday_cmd::holiday_set_auto_enabled,
            commands::cloud_sync_cmd::cloud_sync_now,
            commands::cloud_sync_cmd::cloud_sync_push_only,
            commands::cloud_sync_cmd::cloud_sync_pull_then_push,
            // 强制同步（进入/退出应用生命周期钩子专用）
            commands::cloud_sync_cmd::cloud_sync_force,
            // 增量同步历史（P1-17：设置页同步历史卡数据源）
            commands::cloud_sync_cmd::cloud_sync_history,
            commands::cloud_sync_cmd::cloud_sync_get_state,
            commands::cloud_sync_cmd::cloud_sync_is_running,
            commands::cloud_sync_cmd::cloud_sync_rekey,
            commands::cloud_sync_cmd::sync_disconnect,
            // 冲突败方副本（03 文档 §八 遗留项：查看 / 恢复 / 忽略 / 清空）
            commands::sync_conflict_cmd::sync_conflict_list,
            commands::sync_conflict_cmd::sync_conflict_count,
            commands::sync_conflict_cmd::sync_conflict_restore,
            commands::sync_conflict_cmd::sync_conflict_dismiss,
            commands::sync_conflict_cmd::sync_conflict_clear,
            // M3：全量备份
            commands::full_sync_cmd::full_backup_export,
            commands::full_sync_cmd::full_backup_import,
            commands::full_sync_cmd::full_backup_list_local,
            commands::full_sync_cmd::full_backup_list_cloud,
            commands::full_sync_cmd::full_backup_restore_cloud,
            commands::full_sync_cmd::full_backup_peek_local,
            commands::full_sync_cmd::full_backup_peek_cloud,
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
            commands::csv_import_cmd::csv_import_limits,
            commands::csv_import_cmd::csv_import_job_start,
            commands::csv_import_cmd::csv_import_job_status,
            commands::csv_import_cmd::csv_import_job_cancel,
            commands::csv_import_cmd::csv_import_job_drop,
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
            // 每日摘要提醒（G3：每日固定时刻汇总通知，cfg_kv 本机偏好）
            commands::digest_cmd::digest_prefs,
            commands::digest_cmd::digest_set_prefs,
            commands::digest_cmd::digest_summary,
            // 统计仪表盘（backlog #25：总览/热力图/连续天数/分布）
            commands::stats_cmd::stats_aggregate,
            // 日排程（F3：预览 + 阶段二应用 + 阶段三偏好）
            commands::planner_cmd::day_plan_preview,
            commands::planner_cmd::day_plan_apply,
            commands::planner_cmd::day_plan_prefs_get,
            commands::planner_cmd::day_plan_prefs_set,
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
            // 任务附件（上传/列表/读取/导出/卸下 + 本地 GC）
            commands::asset_cmd::task_attachment_add,
            commands::asset_cmd::task_attachment_add_from_path,
            commands::asset_cmd::task_attachments_list,
            commands::asset_cmd::task_attachment_read,
            commands::asset_cmd::task_attachment_export,
            commands::asset_cmd::task_attachment_remove,
            commands::asset_cmd::attachments_gc,
            commands::asset_cmd::attachments_unused_list,
            commands::asset_cmd::attachments_unused_delete,
            // 云端孤儿附件清理（诊断页手动触发；docs/15）
            commands::cloud_sync_cmd::cloud_unused_attachments_scan,
            commands::cloud_sync_cmd::cloud_unused_attachments_delete,
            // 孤儿数据分桶回收（#96 尾款入口，与附件清理同卡）
            commands::cloud_sync_cmd::cloud_orphan_chunks_gc,
            // 数据库维护（WAL checkpoint / 附件 GC / 查询统计 / VACUUM）
            commands::db_maintenance_cmd::db_maintenance,
            // 应用内诊断分区（只读读数：库体积 / 各表行数 / 附件缓存占用）
            commands::diagnostics_cmd::diagnostics_snapshot,
            // 主窗唤起（全局热键；窗口被超时回收后走重建路径）
            commands::window_recycler::show_main_window_cmd,
            // 冷启动首屏标记（度量专用；ORBIT_PERF_MARKER 未设置时 no-op）
            commands::perf_cmd::perf_first_screen_mark,
            // 启动形态探针（自启拉起 = --hidden 静默驻留；前端据此跳过主窗 show）
            commands::startup_cmd::startup_launched_hidden,
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
