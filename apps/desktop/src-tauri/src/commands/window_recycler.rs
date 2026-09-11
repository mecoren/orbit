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
//!      标志转交重建后的前端）。
//!    托盘单击/菜单、全局热键（前端 invoke）共用本入口，替代此前
//!    「窗口 API 直接 show」的三处散落实现（热键路径原本无法处理窗口
//!    不存在的场景）。
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

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_window_state::WindowExt as _;

use crate::commands::tray;
use crate::commands::webview_low_power;

/// 隐藏后多久未见再唤起即销毁主窗（秒）
pub const RECYCLE_AFTER_SECS: u64 = 300;

/// 销毁期间收到快速新建请求的补发标志（consume 语义：读即清）
static PENDING_QUICK_ADD: AtomicBool = AtomicBool::new(false);

/// 回收排程是否已挂起（防重复排程；窗口销毁/显示都会清）
static RECYCLE_SCHEDULED: AtomicBool = AtomicBool::new(false);

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

/// 唤起主窗统一入口（托盘单击/菜单、全局热键共用）
///
/// - 在：显示 + 聚焦 + 档位恢复 Normal + 取消回收排程；
/// - 不在（已被回收）：按 tauri.conf 窗口配置重建（label=main 的
///   WindowConfig），Mica 重应用，如有补发意图则 postFrame 后 bump。
pub fn show_or_create_main_window(app: &AppHandle) {
    cancel_recycle_on_show();

    match app.get_webview_window("main") {
        Some(win) => {
            let _ = win.show();
            let _ = win.unminimize();
            let _ = win.set_focus();
            webview_low_power::set_memory_usage_level(app, false);
        }
        None => {
            if let Err(e) = create_main_window(app) {
                eprintln!("[window-recycler] 主窗重建失败: {e}");
            }
        }
    }
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
    // 窗口同样生效）；重建即恢复最大化态。
    let _ = win.restore_state(Default::default());

    // Mica 云母材质须对新 HWND 重应用（与冷启动 setup 同口径）
    #[cfg(all(desktop, target_os = "windows"))]
    {
        if let Err(e) = crate::commands::mica_cmd::apply_mica_dwm(app) {
            eprintln!("[window-recycler] Mica 重应用失败（不影响功能）: {e}");
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
}
