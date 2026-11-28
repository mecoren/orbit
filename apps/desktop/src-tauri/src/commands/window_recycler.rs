//! window_recycler — 主窗唤起统一收口 + 隐藏超时销毁（2026-09-10 内存优化）
//!
//! 背景（实测驱动）：托盘驻留期间 WebView2 整树 ~330MB 提交内存纯闲置
//! （渲染器 121MB + GPU 117MB），且隐藏后 Chromium 不做后台裁剪。本模块
//! 两层回收策略：
//!
//! 1. 唤起统一入口 `show_or_create_main_window`：
//!    - 窗口在（隐藏驻留态）→ show/unminimize/focus + 档位恢复 Normal；
//!    - 窗口已被回收 → 按 tauri.conf 窗口配置重建 + Mica 重应用 +
//!      意图补发（销毁期间托盘/热键的快速新建请求经 PENDING_QUICK_ADD
//!      标志转交重建后的前端）；
//!    - 两条分支都先 `startup_cmd::mark_activated()` 清除「静默驻留」标志：
//!      `--hidden` 自启的进程被唤起后，重建窗口的 webview 重跑 main.tsx
//!      不得再跳过 show（否则只剩后台 WebView、界面永不出现）。
//!    - 托盘单击/菜单、全局热键（前端 invoke）共用本入口，替代此前
//!      「窗口 API 直接 show」的三处散落实现（热键路径原本无法处理窗口
//!      不存在的场景）。
//!
//! 2. 隐藏驻留超时销毁 `schedule_recycle_on_hide` / `cancel_recycle_on_show`：
//!    - 关窗隐藏即排程；超时（RECYCLE_AFTER_SECS）窗口仍未显示 → 物理销毁
//!      主窗，进程与四个后台守护（同步 60s tick/提醒 20s 轮询/回收站 TTL/
//!      节假日）继续常驻——常驻内存从 ~330MB 回落到宿主 ~40MB；
//!    - 隐藏期间再次唤起 → 取消排程（快速隐藏-唤起不触发回收）。
//!
//! 隐性成本（事件不排队的兜底）——销毁期间后台守护继续 emit 的事件
//! 无人接收属预期；全部通道有冷启动自愈路径：
//! - sync-progress / db-change：重建 = 前端冷启动，React Query 空缓存
//!   全量重拉；useStartupSync 重跑 pull_then_push 补一轮同步；
//! - sync-key-mismatch：useStartupSync 冷启动重新捕获并导航恢复页；
//! - tray-quick-add / 热键意图：销毁期请求经 PENDING_QUICK_ADD 补发
//!   （ReadyShell 挂载后 bump，与事件实时路径同消费方）。
//!
//! 窗口状态恢复：window-state 插件对重建窗口自动恢复缓存的位置/尺寸
//! （销毁时窗口为隐藏态 → 恢复 visible=false 不闪窗，前端启动流程
//! main.tsx 主动 show，与冷启动路径一致）。
//!
//! 唤起置前（2026-11-25 反馈「点托盘/任务栏再也打不开界面」的修复）：
//! 重建窗口的显示由前端 main.tsx 首帧后 `show()` 承担（防空窗闪白），但
//! Windows 前台锁只放行「持有前台权」的进程调 `SetForegroundWindow`——托盘
//! 单击与通知正文点击的输入都发生在 shell / 通知宿主进程里，本进程不是前台
//! 进程，`show()` 会把窗口「显示」在**其它应用后面**且拒绝激活。实测：300s
//! 回收销毁后点托盘，窗口确实重建成功、webview 也起来了，但前台窗口始终是
//! 别的应用——用户观感就是「点了完全没反应、界面打不开」，且反复点也一样。
//! 故唤起路径统一由 `activate_window` 收口：show/unminimize 之外，Windows 上
//! 补 `HWND_TOP` 置前（即使前台锁拒绝激活也保证「看得见」）+ AttachThreadInput
//! 绕前台锁拿焦点；重建分支再起一个守候泵（`watch_rebuilt_window`），窗口一
//! 出现就补最大化保留 + 置前聚焦，5s 仍不显示则壳层兜底 show。
//! 另一处实测缺口：window-state 插件对重建窗口的 `restore_state` 只恢复了
//! 位置/尺寸，**最大化态没生效**（重建后回到 1280×832）——故销毁前把
//! `is_maximized` 记进 `RESTORE_MAXIMIZED`，重建后由壳层补一次。
//!
//! 执行上下文（2026-11-28 挂死修复）：唤起/重建只能在 tao 的事件回调上下文里
//! 做，不能在窗口过程（托盘 WndProc / 单实例 WM_COPYDATA / 热键 WndProc）里
//! 同步做，否则窗口事件会被内联派发、与插件的 `restore_state` 锁互等，主线程
//! 永久卡死（现场见 `show_or_create_main_window` 文档）。因此本模块所有窗口
//! 侧动作都经「工作线程 → `run_on_main_thread`」投递，调用点保持薄。

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_window_state::WindowExt as _;

use crate::commands::tray;
use crate::commands::webview_low_power;

/// 隐藏后多久未见再唤起即销毁主窗（秒）
pub const RECYCLE_AFTER_SECS: u64 = 300;

/// 重建窗口守候泵的单拍间隔（毫秒）
const REBUILD_POLL_MS: u64 = 125;
/// 重建窗口壳层兜底 show 的时点（毫秒）：前端启动链失败的最后防线，
/// 与冷启动的 8s 兜底同语义——「不出现」比「迟一点出现」严重得多
const REBUILD_SHOW_FALLBACK_MS: u64 = 5_000;
/// 重建窗口出现守候总时长（毫秒），超时判定唤起失败并留痕
const REBUILD_WATCH_MS: u64 = 10_000;
/// 置前后复核等待（毫秒）：前台锁竞态下再补一次激活
const REBUILD_RAISE_RECHECK_MS: u64 = 180;
/// 重建失败后的重试延迟（毫秒）
const REBUILD_RETRY_DELAY_MS: u64 = 500;

/// 隐藏超时回收销毁前记下的最大化态：重建路径靠它恢复「上一次是最大化」。
/// 为什么不让 window-state 插件独扛：实测重建窗口上插件的 `restore_state`
/// 只生效了位置/尺寸（见模块注释），最大化态必须壳层自己兜一次。
static RESTORE_MAXIMIZED: AtomicBool = AtomicBool::new(false);

/// 重建进行中（托盘连点 / 通知与托盘同时唤起时防并发建窗：
/// `WebviewWindowBuilder::build` 对同 label 的第二次调用会直接报错）
static REBUILDING: AtomicBool = AtomicBool::new(false);

/// 销毁期间收到快速新建请求的补发标志（consume 语义：读即清）
static PENDING_QUICK_ADD: AtomicBool = AtomicBool::new(false);

/// 回收排程是否已挂起（防重复排程；窗口销毁/显示都会清）
static RECYCLE_SCHEDULED: AtomicBool = AtomicBool::new(false);

/// 真退出标志（托盘 quit_app 置位）：区分「窗口回收销毁引发的
/// ExitRequested」（须阻止退出）与用户主动退出（须放行）
static QUITTING: AtomicBool = AtomicBool::new(false);

/// 用户主动关窗（CloseRequested → 隐藏驻留）标记：冷启动 8s 兜底 show 必须让路。
/// 否则启动 8s 内关掉的窗口会被兜底重新弹出来（2026-11-28 实测复现），并且
/// 窗口重新可见让回收排程判定「用户还在用」而取消，内存档位也白白切回前台。
static USER_CLOSED: AtomicBool = AtomicBool::new(false);

pub fn mark_user_close() {
    USER_CLOSED.store(true, Ordering::SeqCst);
}

/// 主窗是否是被用户主动关掉（而非前端 show 未达）
pub fn is_hidden_by_user_close() -> bool {
    USER_CLOSED.load(Ordering::SeqCst)
}

pub fn mark_quitting() {
    QUITTING.store(true, Ordering::SeqCst);
}

pub fn is_quitting() -> bool {
    QUITTING.load(Ordering::SeqCst)
}

/// 销毁期间的快速新建热键兜底：窗口销毁 → 前端 useGlobalQuickAdd 随之
/// 消亡，热键 Alt+Shift+O 无人响应——由壳层 Rust 侧注册兜底 handler
/// （唤起 + 意图补发，与托盘「快速新建」销毁态分支同语义）；重建后
/// 前端 hook 重新注册（插件同 id 热键重复注册由内部去重合并）。
#[cfg(desktop)]
fn register_hotkey_fallback(app: &AppHandle) {
    use tauri_plugin_global_shortcut::GlobalShortcutExt as _;

    let gs = app.global_shortcut();
    // 与前端 useGlobalQuickAdd 同一快捷键：注册成功即接管（销毁期前端
    // 已不在，无抢占冲突）；失败静默（运行环境不支持全局热键时托盘仍在）
    let _ = gs.on_shortcut("Alt+Shift+O", |app, _shortcut, _event| {
        show_or_create_main_window(app);
        PENDING_QUICK_ADD.store(true, Ordering::SeqCst);
    });
}

/// 唤起主窗统一入口（托盘单击/菜单、全局热键、通知正文点击、重复双击 exe 共用）
///
/// **执行上下文（2026-11-28 挂死根因）**：本入口会被窗口过程里同步调用——
/// 托盘图标的 WndProc、单实例插件 `WM_COPYDATA` 的 WndProc、全局热键的
/// WndProc 都跑在主线程的消息派发里，而不是 tao 的事件回调里。在那里直接
/// 建窗/改窗会踩两类事故：
/// 1. tao 事件循环状态机被重入（`crash.log` 里的 "cannot move state from
///    Destroyed" panic 就是这个类）；
/// 2. 此时 tao 不在回调内（`in_callback == 0`），窗口几何突变产生的
///    Moved/Resized 会被 `send_event` **内联**派发进 tauri 的事件链，和
///    正在持锁执行 `restore_state` 的 window-state 插件互相等待 → 主线程
///    卡在 futex 上永不返回。真实现场（2026-11-28）：回收销毁后点图标，主窗
///    建出来但永不显示，主线程停在 `ntdll!ZwWaitForAlertByThreadId`；此后
///    托盘完全无响应，每点一次 exe 还多一个卡在同步 `SendMessage` 的僵尸进程。
///
/// 故本函数只做**原子量**状态切换（取消回收排程 / 退出静默驻留姿态），窗口
/// 侧动作一律投递到事件循环执行：`run_on_main_thread` 只在**非主线程**调用时
/// 才是投递（主线程调用会内联执行），所以先进一条工作线程再投递——两跳之后
/// 一定落在 tao 的事件回调上下文里，窗口事件会被排队而不是内联。
pub fn show_or_create_main_window(app: &AppHandle) {
    cancel_recycle_on_show();

    // 用户显式唤起（托盘/热键/重复双击 exe）即脱离「静默驻留」姿态：
    // 重建路径下新 webview 会重跑 main.tsx 启动链，若仍按启动期 --hidden
    // 判定就会跳过 show，界面永不出现（见 startup_cmd::mark_activated）。
    crate::commands::startup_cmd::mark_activated();

    let app = app.clone();
    std::thread::spawn(move || {
        let handle = app.clone();
        if let Err(e) = app.run_on_main_thread(move || wake_main_window(&handle)) {
            log::error!("[window-recycler] 唤起任务投递失败: {e}");
        }
    });
}

/// 事件循环回调上下文里的唤起实现（上下文约束见 `show_or_create_main_window`）
fn wake_main_window(app: &AppHandle) {
    match app.get_webview_window("main") {
        Some(win) => {
            activate_window(&win, false);
            webview_low_power::set_memory_usage_level(app, false);
        }
        None => {
            // 托盘连点 / 通知正文点击与托盘同时到：只允许一个重建者，
            // 否则第二次 build 撞同 label 直接报错（还会刷一条误导日志）
            if REBUILDING.swap(true, Ordering::SeqCst) {
                log::info!("[window-recycler] 主窗重建进行中，重复唤起已忽略");
                return;
            }
            rebuild_main_window(app);
        }
    }
}

/// 把主窗送到用户眼前：显示 + 取消最小化 +（可选）补最大化 + 置前 + 聚焦。
///
/// 为什么不只 `show() + set_focus()`：见模块注释「唤起置前」——后台进程
/// 调 `SetForegroundWindow` 会被前台锁拒绝，窗口停在其它应用后面，用户观感
/// 就是「点了没反应」。`restore_geometry=true` 只在重建分支用一次（把
/// 销毁前记下的最大化态补回来）。
fn activate_window(win: &tauri::WebviewWindow, restore_geometry: bool) {
    let _ = win.show();
    let _ = win.unminimize();
    if restore_geometry {
        restore_maximized(win);
    }
    #[cfg(target_os = "windows")]
    force_foreground(win);
    let _ = win.set_focus();
}

/// 回收销毁前记下最大化态（仅重建路径消费；非最大化时写入 false）
fn remember_geometry(win: &tauri::WebviewWindow) {
    RESTORE_MAXIMIZED.store(win.is_maximized().unwrap_or(false), Ordering::SeqCst);
}

/// 恢复「销毁前是最大化」——读一次即清，只在重建窗口上生效一次。
///
/// 位置/尺寸由 window-state 插件恢复；实测插件的 `restore_state` 在重建
/// 窗口上没把最大化态落到实处，故壳层再兜一次（幂等：已最大化则跳过）。
fn restore_maximized(win: &tauri::WebviewWindow) {
    let want = RESTORE_MAXIMIZED.swap(false, Ordering::SeqCst);
    if !want || win.is_maximized().unwrap_or(false) {
        return;
    }
    match win.maximize() {
        Ok(()) => log::info!("[window-recycler] 重建窗口已补回最大化态"),
        Err(e) => log::warn!("[window-recycler] 重建窗口最大化失败（不影响可交互）: {e}"),
    }
}

/// Windows 前台锁绕行（见模块注释「唤起置前」）。
///
/// 全程静默失败：调用方已经 show 过，最差只是「窗口可见但不聚焦」，
/// 绝不会让界面消失或卡住。
#[cfg(target_os = "windows")]
fn force_foreground(win: &tauri::WebviewWindow) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
    use windows::Win32::UI::WindowsAndMessaging::{
        BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, HWND_TOP, IsIconic,
        SW_RESTORE, SW_SHOW, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SetForegroundWindow,
        SetWindowPos, ShowWindow,
    };

    let Ok(raw) = win.hwnd() else { return };
    let hwnd = HWND(raw.0 as _);
    unsafe {
        let _ = ShowWindow(
            hwnd,
            if IsIconic(hwnd).as_bool() {
                SW_RESTORE
            } else {
                SW_SHOW
            },
        );
        // 顶到 z 序最前：即使前台锁拒绝激活，也必须让用户「看得见」
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOP),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
        let foreground = GetForegroundWindow();
        if foreground == hwnd {
            return;
        }
        // 经典前台锁绕行：本线程输入临时附加到当前前台线程 → SetForegroundWindow
        // 生效 → 立即解除附加（不借走别人的输入状态）
        let foreground_thread = GetWindowThreadProcessId(foreground, None);
        let current_thread = GetCurrentThreadId();
        let attached = foreground_thread != 0
            && foreground_thread != current_thread
            && AttachThreadInput(current_thread, foreground_thread, true).as_bool();
        let _ = SetForegroundWindow(hwnd);
        let _ = BringWindowToTop(hwnd);
        if attached {
            let _ = AttachThreadInput(current_thread, foreground_thread, false);
        }
    }
}

/// 重建主窗（收回 REBUILDING 标志；失败按「窗口是否真的不在」重试一次）
fn rebuild_main_window(app: &AppHandle) {
    let started = Instant::now();
    match create_main_window(app) {
        Ok(()) => {
            log::info!(
                "[window-recycler] 主窗重建成功（{}ms），等待前端首帧显示",
                started.elapsed().as_millis()
            );
            REBUILDING.store(false, Ordering::SeqCst);
            watch_rebuilt_window(app);
        }
        Err(e) => {
            // 失败可能是「另一个线程刚建成功」的假阴性：以窗口实际存在为准
            if app.get_webview_window("main").is_some() {
                REBUILDING.store(false, Ordering::SeqCst);
                activate_window_of(app, true);
                return;
            }
            log::error!(
                "[window-recycler] 主窗重建失败（{}ms），将重试一次: {e}",
                started.elapsed().as_millis()
            );
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(REBUILD_RETRY_DELAY_MS));
                let result = create_main_window(&app);
                REBUILDING.store(false, Ordering::SeqCst);
                match result {
                    Ok(()) => {
                        log::info!("[window-recycler] 主窗重建重试成功");
                        watch_rebuilt_window(&app);
                    }
                    Err(e) => log::error!(
                        "[window-recycler] 主窗重建重试仍失败（托盘菜单/热键可再试）: {e}"
                    ),
                }
            });
        }
    }
}

/// 唤起已存在的主窗（内部辅助：仅在有窗口时操作）
fn activate_window_of(app: &AppHandle, restore_geometry: bool) {
    if let Some(win) = app.get_webview_window("main") {
        activate_window(&win, restore_geometry);
    }
}

/// 重建窗口守候泵单拍决策（纯函数，便于单测）
#[derive(Debug, PartialEq, Eq)]
enum WatchAction {
    /// 还不可见，继续等
    Wait,
    /// 已到兜底时点且仍不可见：壳层主动 show（前端启动链失败的最后防线）
    FallbackShow,
    /// 已可见：补最大化 + 置前 + 聚焦
    Raise,
    /// 超过总时长仍不可见：放弃并留痕
    GiveUp,
}

fn watch_action(visible: bool, elapsed_ms: u64, fallback_shown: bool) -> WatchAction {
    if visible {
        return WatchAction::Raise;
    }
    if !fallback_shown && elapsed_ms >= REBUILD_SHOW_FALLBACK_MS {
        return WatchAction::FallbackShow;
    }
    if elapsed_ms >= REBUILD_WATCH_MS {
        return WatchAction::GiveUp;
    }
    WatchAction::Wait
}

/// 重建窗口的出现守候：前端 main.tsx 首帧后 show 时，补「最大化 + 置前 + 聚焦」。
///
/// 为什么不在重建分支直接 show：与冷启动同口径的 `visible:false` + 前端
/// 首帧后 show 是为了防空窗闪白；但前端 show 拿不到前台（前台锁），所以
/// 这里等它可见后接管置前。5s 仍不可见则兜底 show（宁可闪一下，也不留下
/// 一个打不开的窗口）。
fn watch_rebuilt_window(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let started = Instant::now();
        let mut fallback_shown = false;
        loop {
            std::thread::sleep(Duration::from_millis(REBUILD_POLL_MS));
            let Some(win) = app.get_webview_window("main") else {
                return;
            };
            let visible = win.is_visible().unwrap_or(false);
            let elapsed = started.elapsed().as_millis() as u64;
            match watch_action(visible, elapsed, fallback_shown) {
                WatchAction::Wait => continue,
                WatchAction::FallbackShow => {
                    fallback_shown = true;
                    log::warn!(
                        "[window-recycler] 重建窗口 {REBUILD_SHOW_FALLBACK_MS}ms 仍未显示，壳层兜底 show"
                    );
                    let _ = win.show();
                }
                WatchAction::Raise => {
                    activate_window(&win, true);
                    // 一拍复核：置前后仍未聚焦（前台锁竞态）再补一次后收工
                    std::thread::sleep(Duration::from_millis(REBUILD_RAISE_RECHECK_MS));
                    if let Some(win) = app.get_webview_window("main")
                        && !win.is_focused().unwrap_or(false)
                    {
                        activate_window(&win, false);
                    }
                    if let Some(win) = app.get_webview_window("main") {
                        log::info!(
                            "[window-recycler] 重建窗口已唤起（{}ms）visible={} focused={} maximized={}",
                            elapsed,
                            win.is_visible().unwrap_or(false),
                            win.is_focused().unwrap_or(false),
                            win.is_maximized().unwrap_or(false)
                        );
                    }
                    return;
                }
                WatchAction::GiveUp => {
                    log::error!(
                        "[window-recycler] 重建窗口 {REBUILD_WATCH_MS}ms 内未显示：唤起失败（托盘菜单/热键可再试）"
                    );
                    return;
                }
            }
        }
    });
}

/// 按 tauri.conf 的 main 窗口配置重建主窗
///
/// visible 保持配置的 false（防闪白窗）——window-state 恢复位置尺寸后
/// 由前端启动流程（main.tsx 主题/字体初始化后 getCurrentWindow().show()）
/// 主动显示，与冷启动同路径；此处不提前 show。
fn create_main_window(app: &AppHandle) -> tauri::Result<()> {
    let config = app
        .config()
        .app
        .windows
        .iter()
        .find(|w| w.label == "main")
        .cloned()
        .ok_or_else(|| tauri::Error::WindowNotFound)?;

    let win = tauri::WebviewWindowBuilder::from_config(app, &config)?.build()?;

    // window-state 恢复缓存的位置/尺寸（on_window_ready 已在 build 内挂过
    // 监听，这里再手动 restore 一次以应用旧缓存——插件对 builder 创建的
    // 窗口同样生效）；标志与插件注册同源（crate::window_state_flags 剔除了
    // VISIBLE），故不会在此提前 show：重建后的 webview 会重跑 main.tsx 的
    // 启动链，由前端决定显隐。
    // 注意：实测这条 restore 只恢复位置/尺寸，**最大化态不生效**——最大化
    // 由 watch_rebuilt_window 在窗口可见后调 restore_maximized 补回。
    if let Err(e) = win.restore_state(crate::window_state_flags()) {
        log::warn!("[window-recycler] 重建窗口几何恢复失败（沿用默认尺寸）: {e}");
    }

    // Mica 云母材质须对新 HWND 重应用（与冷启动 setup 同口径）
    #[cfg(all(desktop, target_os = "windows"))]
    {
        if let Err(e) = crate::commands::mica_cmd::apply_mica_dwm(app) {
            log::warn!("[window-recycler] Mica 重应用失败（不影响功能）: {e}");
        }
    }

    // 补发意图：销毁期间的快速新建请求，前端就绪后再 bump（冷启动链上
    // app-shell 监听挂载需要时间，postFrame 语义用固定延迟近似——
    // ReadyShell 挂载必然先于用户可交互）
    if PENDING_QUICK_ADD.swap(false, Ordering::SeqCst) {
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            let _ = app.emit(tray::TRAY_QUICK_ADD_EVENT, tray::TrayQuickAddPayload {});
        });
    }

    Ok(())
}

/// 关窗隐藏时排程回收（lib.rs CloseRequested 钩子调用）
pub fn schedule_recycle_on_hide(app: &AppHandle) {
    if RECYCLE_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(RECYCLE_AFTER_SECS));
        // 期间被唤起（取消了排程）则不动
        if !RECYCLE_SCHEDULED.load(Ordering::SeqCst) {
            return;
        }
        // 竞态兜底：此刻恰好又显示（show 与本线程同时跑）→ 以窗口实际
        // 可见性为准，可见即放弃回收
        if let Some(win) = app.get_webview_window("main") {
            if win.is_visible().unwrap_or(false) {
                RECYCLE_SCHEDULED.store(false, Ordering::SeqCst);
                return;
            }
            // 销毁前窗口不可见 → 前端热键 handler 已随窗消亡，注册
            // Rust 侧兜底接管 Alt+Shift+O（重建后前端重新注册）
            #[cfg(desktop)]
            register_hotkey_fallback(&app);
            // 记下最大化态：重建后由壳层补回（插件的 restore_state 在重建
            // 窗口上不恢复最大化，见模块注释与 restore_maximized）
            remember_geometry(&win);
            log::info!(
                "[window-recycler] 隐藏 {}s 未唤起，回收销毁主窗（maximized={}）",
                RECYCLE_AFTER_SECS,
                RESTORE_MAXIMIZED.load(Ordering::SeqCst)
            );
            let _ = win.destroy();
            // 排程标志保留 true：destroy 后窗口不在，下一次隐藏前
            // swap 仍会排程（防「销毁-重建-再隐藏」漏排）由
            // show_or_create 路径 cancel 重置保证
        }
        RECYCLE_SCHEDULED.store(false, Ordering::SeqCst);
    });
}

/// 唤起时取消回收排程（show_or_create 主入口调用）
pub fn cancel_recycle_on_show() {
    RECYCLE_SCHEDULED.store(false, Ordering::SeqCst);
}

/// 记录销毁期间的快速新建请求（托盘菜单销毁态分支调用）
pub fn mark_pending_quick_add() {
    PENDING_QUICK_ADD.store(true, Ordering::SeqCst);
}

#[tauri::command]
/// 唤起主窗（全局热键前端调用；窗口在则显示，不在则重建）
///
/// 与前端 getCurrentWindow().show() 的差别：窗口销毁后前者抛错无兜底，
/// 本命令走 Rust 统一入口完整覆盖两种状态。
pub fn show_main_window_cmd(app: AppHandle) {
    show_or_create_main_window(&app);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 回收超时常量：5 分钟（300s）——过短会打断「午休回来看一眼」的
    /// 常见驻留节奏，过长则回收收益名存实亡
    #[test]
    fn recycle_timeout_is_five_minutes() {
        assert_eq!(RECYCLE_AFTER_SECS, 300);
    }

    /// 意图标志读写语义：mark 后 consume（swap false）应返回 true 且复位
    #[test]
    fn pending_quick_add_consume_semantics() {
        // 独立原子量验证语义（不碰全局静态，避免测试间污染）
        let flag = AtomicBool::new(false);
        flag.store(true, Ordering::SeqCst);
        assert!(flag.swap(false, Ordering::SeqCst));
        assert!(!flag.swap(false, Ordering::SeqCst));
    }

    /// 守候泵决策：可见即置前；不可见先等到兜底时点，兜底过仍不可见则放弃
    #[test]
    fn watch_action_waits_then_falls_back_then_gives_up() {
        // 刚重建、窗口还没被前端 show：继续等，不做任何动作
        assert_eq!(
            watch_action(false, 0, false),
            WatchAction::Wait,
            "首拍不应 show/置前"
        );
        assert_eq!(
            watch_action(false, REBUILD_SHOW_FALLBACK_MS - 1, false),
            WatchAction::Wait
        );
        // 到兜底时点仍不可见 → 壳层兜底 show
        assert_eq!(
            watch_action(false, REBUILD_SHOW_FALLBACK_MS, false),
            WatchAction::FallbackShow
        );
        // 兜底 show 之后仍不可见 → 只能等它渲染完，不再反复 show
        assert_eq!(
            watch_action(false, REBUILD_SHOW_FALLBACK_MS + 1, true),
            WatchAction::Wait
        );
        // 前端首帧后 show 完成 → 置前 + 聚焦（无论是否兜底过）
        assert_eq!(watch_action(true, 0, false), WatchAction::Raise);
        assert_eq!(
            watch_action(true, REBUILD_SHOW_FALLBACK_MS, true),
            WatchAction::Raise
        );
        // 兜底都没触发就到总时长（理论上兜底更早，属防御）→ 仍先兜底 show
        assert_eq!(
            watch_action(false, REBUILD_WATCH_MS, false),
            WatchAction::FallbackShow
        );
        // 兜底过、到总时长仍不可见 → 放弃并留痕
        assert_eq!(
            watch_action(false, REBUILD_WATCH_MS, true),
            WatchAction::GiveUp
        );
    }

    /// 守候泵时长关系：兜底时点必须早于总时长，否则兜底永远轮不到执行
    #[test]
    fn fallback_precedes_watch_deadline() {
        assert!(REBUILD_SHOW_FALLBACK_MS < REBUILD_WATCH_MS);
        assert!(REBUILD_POLL_MS > 0 && REBUILD_POLL_MS < REBUILD_SHOW_FALLBACK_MS);
    }

    /// 最大化态记录语义：销毁前记录「是最大化」，重建后 consume 一次即清，
    /// 不会把「上一次的最大化」泄漏到后续无关的唤起
    #[test]
    fn restore_maximized_consume_semantics() {
        // 用局部原子量验证 swap 语义（全局静态被真实窗口路径使用）
        let flag = AtomicBool::new(true);
        assert!(flag.swap(false, Ordering::SeqCst), "第一次重建要补最大化");
        assert!(!flag.swap(false, Ordering::SeqCst), "之后的唤起不再重复补");
    }
}
