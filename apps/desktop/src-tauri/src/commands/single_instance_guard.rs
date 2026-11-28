//! single_instance_guard — 二次实例握手看门狗 + 主线程无响应留痕（2026-11-28）
//!
//! **为什么需要**（2026-11-28 实测现场）：`tauri-plugin-single-instance` 在
//! Windows 上用**同步** `SendMessageW(WM_COPYDATA, …)` 把 argv 转交给首实例
//! （插件 `platform_impl/windows.rs`，无超时）。首实例主线程一旦卡死，这次
//! 发送永不返回：二次实例既不完成启动、也不退出——每点一次图标就多一个
//! ~18MB / 2 线程的僵尸进程（现场 11 个，父进程都是 explorer），而用户看到
//! 的只是「点了完全没反应，托盘也点不开」。
//!
//! 首实例为什么卡死见 `window_recycler` 模块文档（回收销毁后重建主窗在窗口
//! 过程里同步执行，窗口事件被内联派发 → 与 window-state 插件互等）。本模块
//! 只负责「卡死之后不再无声」，两层防线：
//!
//! 1. **启动看门狗**（`arm` / `mark_ready`）：`arm()` 必须在 `run()` 最前、
//!    单实例插件注册之前调用。超时未就绪 → 先判首实例是否**真的**无响应
//!    （`IsHungAppWindow` + 1s 超时 `WM_NULL` 探测，双条件成立才算），确认
//!    卡死就结束它并重新拉起本程序（用户这一次点击就能拿回界面）；判不出来
//!    （首次冷启动慢 / 压根没有别的实例）只留痕、不动作——宁可多等，也绝不
//!    误杀正在正常启动或正在跑同步的实例。
//! 2. **主线程无响应留痕**（`start_main_thread_monitor`）：setup 完成后每 5s
//!    往事件循环投递一次心跳，连续 4 拍（>20s）没跑就写一条 crash.log。
//!    窗口与托盘全依赖主线程，卡死时用户侧没有任何可反馈线索，下一次复现
//!    才有现场可查。
//!
//! **为什么结束首实例是安全的**：它的主线程已经卡死，窗口/托盘都不可用；
//! 本地库每次写都是已提交事务（SQLite WAL，崩溃安全），进程被杀等价于任务
//! 管理器「结束任务」，且这是用户此刻唯一能拿回界面的路径。

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

/// setup 完成期限（秒）。正常冷启动 2~3s（首装后 WebView2 初始化略慢），
/// 30s 仍未就绪且首实例无响应 = 单实例握手被卡死，不再让它当僵尸。
const STARTUP_READY_DEADLINE_SECS: u64 = 30;

/// 首实例无响应判定：`WM_NULL` 探测超时（毫秒）
#[cfg(target_os = "windows")]
const PING_TIMEOUT_MS: u32 = 1_000;

/// 结束首实例后的等待上限（毫秒）：命名互斥量随进程退出释放，等它收尾再拉新进程
#[cfg(target_os = "windows")]
const TERMINATE_WAIT_MS: u32 = 3_000;

/// 主线程心跳间隔（秒）
const HEARTBEAT_INTERVAL_SECS: u64 = 5;
/// 连续丢失拍数（4 × 5s = 20s 无响应即判定卡死）
const HEARTBEAT_MISS_LIMIT: u32 = 4;
/// 心跳投递后留给事件循环的响应窗口（毫秒）
const HEARTBEAT_POLL_MS: u64 = 1_000;

/// setup 是否已完成（进程级一次；`AppHandle::plugin`/托盘/守护线程都挂在 setup 里）
static STARTUP_READY: AtomicBool = AtomicBool::new(false);
/// 事件循环心跳计数（看门狗线程每拍 +1，只增不减；u64 不会溢出到实用寿命）
static HEARTBEAT: AtomicU64 = AtomicU64::new(0);
/// 本轮卡死是否已留痕（防每拍刷一条日志；恢复后复位）
static HANG_REPORTED: AtomicBool = AtomicBool::new(false);

/// 启动看门狗：**必须在单实例插件注册之前**调用（`run()` 最前）
pub fn arm() {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(STARTUP_READY_DEADLINE_SECS));
        if STARTUP_READY.load(Ordering::SeqCst) {
            return;
        }
        on_stalled_startup();
    });
}

/// setup 末尾调用：放行启动看门狗
pub fn mark_ready() {
    STARTUP_READY.store(true, Ordering::SeqCst);
}

/// 主线程无响应留痕：setup 末尾调用（此后每 5s 投递一拍心跳）
pub fn start_main_thread_monitor(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut last = HEARTBEAT.load(Ordering::SeqCst);
        let mut misses: u32 = 0;
        loop {
            std::thread::sleep(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
            // 真退出（托盘「退出」的 15s 同步窗口期）不判卡死
            if crate::commands::window_recycler::is_quitting() {
                return;
            }
            // 投递心跳：非主线程调用 → 纯投递，不阻塞；失败说明事件循环已收口
            let beat = app.clone();
            if app
                .run_on_main_thread(move || {
                    let _ = beat;
                    HEARTBEAT.fetch_add(1, Ordering::SeqCst);
                })
                .is_err()
            {
                return;
            }
            std::thread::sleep(Duration::from_millis(HEARTBEAT_POLL_MS));

            let now = HEARTBEAT.load(Ordering::SeqCst);
            if now == last {
                // 卡死判定：连续 MISS_LIMIT 拍没跑（每拍 5s 间隔 + 1s 响应窗）
                misses += 1;
                if misses >= HEARTBEAT_MISS_LIMIT {
                    report_hang(misses);
                }
                continue;
            }
            misses = 0;
            HANG_REPORTED.store(false, Ordering::SeqCst);
            last = now;
        }
    });
}

/// 连续丢失拍数达标后的留痕（只做一次，恢复后由心跳复位）
fn report_hang(misses: u32) {
    if HANG_REPORTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let window = HEARTBEAT_INTERVAL_SECS * u64::from(misses);
    let msg = format!(
        "[main-thread] 事件循环已 {window}s 无响应（{misses} 拍心跳未被执行）：窗口与托盘均不可用，\
         需结束进程；判定依据=run_on_main_thread 投递的心跳未被处理。\
         若下次再遇到，请保留 app_log.log 与 crash.log 反馈"
    );
    log::error!("{msg}");
    crate::append_crash_log(&msg);
}

/// 判首实例卡死后的处置（Windows 专属；其它平台单实例握手无同步阻塞问题）
fn on_stalled_startup() {
    #[cfg(target_os = "windows")]
    {
        let target = single_instance_window();
        let hung = target
            .as_ref()
            .map_or(false, |&(hwnd, _)| is_unresponsive(hwnd));
        let action = stall_action(true, target.is_some(), hung);
        match action {
            StallAction::Recover => {
                let (hwnd, pid) = target.expect("target 已判存在");
                let msg = format!(
                    "[single-instance] 二次实例 {STARTUP_READY_DEADLINE_SECS}s 未完成启动：\
                     首实例 pid={pid} 主线程无响应（hwnd={hwnd:?}，IsHungAppWindow + \
                     {PING_TIMEOUT_MS}ms WM_NULL 探测双超时），结束它并重新拉起"
                );
                log::error!("{msg}");
                crate::append_crash_log(&msg);
                if !terminate_and_relaunch(pid) {
                    log::error!("[single-instance] 结束首实例 / 重新拉起失败，本进程退出");
                    std::process::exit(0);
                }
            }
            StallAction::Wait => {
                // 判不出来（没有其它实例 / 首实例只是慢）：不动手，只留一条线索
                crate::append_crash_log(
                    "[single-instance] 启动看门狗超时，但未发现无响应的首实例（不再动作，继续等 setup）",
                );
            }
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        crate::append_crash_log(&format!(
            "[single-instance] 启动看门狗 {STARTUP_READY_DEADLINE_SECS}s 超时（非 Windows \
             单实例握手无同步阻塞，仅留痕，不动作）"
        ));
    }
}

/// 看门狗决策（纯函数，便于单测）：只有「期限已到 + 找到首实例 + 首实例卡死」才动手
#[derive(Debug, PartialEq, Eq)]
enum StallAction {
    /// 不动作（继续等 / 只留痕）
    Wait,
    /// 结束无响应的首实例并重新拉起
    Recover,
}

fn stall_action(deadline_passed: bool, target_found: bool, target_hung: bool) -> StallAction {
    if deadline_passed && target_found && target_hung {
        StallAction::Recover
    } else {
        StallAction::Wait
    }
}

/// 枚举属于「其它进程」的单实例窗口，返回 (hwnd, pid)
///
/// 类名 = `"{identifier}-sic"`（插件 `platform_impl/windows.rs` 的
/// `format!("{id}-sic")`；semver 特性会带版本后缀，故按后缀匹配、不写死全名）。
#[cfg(target_os = "windows")]
fn single_instance_window() -> Option<(isize, u32)> {
    use windows::Win32::Foundation::LPARAM;
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetClassNameW, GetWindowThreadProcessId,
    };
    use windows::core::BOOL;

    unsafe extern "system" fn callback(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let mut buf = [0u16; 128];
        let len = unsafe { GetClassNameW(hwnd, &mut buf) };
        if len > 0 {
            let class = String::from_utf16_lossy(&buf[..len as usize]);
            if class.ends_with("-sic") {
                let mut pid = 0u32;
                unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
                // 排除自己：极端情况下枚举到本进程的窗口不该被当成首实例
                if pid != 0 && pid != std::process::id() {
                    let slot = unsafe { &mut *(lparam.0 as *mut Option<isize>) };
                    *slot = Some(hwnd.0 as isize);
                    return BOOL(0); // 找到一个即停
                }
            }
        }
        BOOL(1)
    }

    let mut found: Option<isize> = None;
    unsafe {
        let _ = EnumWindows(Some(callback), LPARAM(&mut found as *mut _ as isize));
    }
    let hwnd = found?;
    // HWND → 进程 id（窗口已确认存在，这一步失败极罕见，交给调用方按「找不到」处理）
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(HWND(hwnd as *mut core::ffi::c_void), Some(&mut pid));
    }
    (pid != 0).then_some((hwnd, pid))
}

/// 首实例主线程是否无响应：`IsHungAppWindow` 与 1s `WM_NULL` 探测**双条件**
///
/// 只用 `IsHungAppWindow` 会误杀：该标志在「消息队列连续 5s 未处理」时就为
/// true，而某些正常的长阻塞（模态确认框、系统凭据弹窗）也会短暂命中。
/// 再加一次带超时的 `WM_NULL` 探测（`SMTO_ABORTIFHUNG | SMTO_BLOCK`）要求两者
/// 同时成立，才认定「点了没反应」的那种卡死。
#[cfg(target_os = "windows")]
fn is_unresponsive(hwnd: isize) -> bool {
    use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{
        IsHungAppWindow, SMTO_ABORTIFHUNG, SMTO_BLOCK, SendMessageTimeoutW, WM_NULL,
    };

    let hwnd = HWND(hwnd as *mut core::ffi::c_void);
    if !unsafe { IsHungAppWindow(hwnd) }.as_bool() {
        return false;
    }
    let mut result = 0usize;
    let lresult = unsafe {
        SendMessageTimeoutW(
            hwnd,
            WM_NULL,
            WPARAM(0),
            LPARAM(0),
            SMTO_ABORTIFHUNG | SMTO_BLOCK,
            PING_TIMEOUT_MS,
            Some(&mut result),
        )
    };
    lresult.0 == 0
}

/// 结束无响应的首实例并重新拉起本程序（返回是否成功拉起）
///
/// 顺序：先 `TerminateProcess` + 等它真正退出（命名互斥量随进程退出释放），
/// 再从 `current_exe()` 起一个新进程——用户这次点击就能看到界面。
#[cfg(target_os = "windows")]
fn terminate_and_relaunch(pid: u32) -> bool {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE, TerminateProcess,
        WaitForSingleObject,
    };

    let Ok(handle) = (unsafe {
        OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            pid,
        )
    }) else {
        log::error!("[single-instance] OpenProcess(pid={pid}) 失败（无权限结束首实例）");
        return false;
    };
    let terminated = unsafe { TerminateProcess(handle, 1) }.is_ok();
    if terminated {
        let _ = unsafe { WaitForSingleObject(handle, TERMINATE_WAIT_MS) };
    }
    let _ = unsafe { CloseHandle(handle) };
    if !terminated {
        log::error!("[single-instance] TerminateProcess(pid={pid}) 失败");
        return false;
    }

    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    match std::process::Command::new(exe).spawn() {
        Ok(_) => true,
        Err(e) => {
            log::error!("[single-instance] 重新拉起本程序失败: {e}");
            false
        }
    }
}

#[cfg(target_os = "windows")]
use windows::Win32::Foundation::HWND;

#[cfg(test)]
mod tests {
    use super::*;

    /// 只有「期限已到 + 找到首实例 + 首实例卡死」才允许动手结束进程：
    /// 首次冷启动慢、或者没有其它实例时误杀会让用户丢掉正在启动的应用
    #[test]
    fn stall_action_requires_all_three_conditions() {
        assert_eq!(stall_action(true, true, true), StallAction::Recover);
        assert_eq!(stall_action(false, true, true), StallAction::Wait);
        assert_eq!(stall_action(true, false, true), StallAction::Wait);
        assert_eq!(stall_action(true, true, false), StallAction::Wait);
        assert_eq!(stall_action(false, false, false), StallAction::Wait);
    }

    /// 看门狗期限必须给足冷启动（首次 WebView2 初始化）且在 1 分钟内收口，
    /// 否则要么误杀、要么僵尸进程存活太久
    #[test]
    fn startup_deadline_is_reasonable() {
        assert!(STARTUP_READY_DEADLINE_SECS >= 15);
        assert!(STARTUP_READY_DEADLINE_SECS <= 60);
    }

    /// 心跳判定：4 拍 × 5s = 20s 才算卡死；判定阈值不能低于 3 拍，
    /// 否则一次磁盘卡顿/系统休眠唤醒就会误报
    #[test]
    fn heartbeat_threshold_is_20_seconds() {
        assert_eq!(
            HEARTBEAT_INTERVAL_SECS * u64::from(HEARTBEAT_MISS_LIMIT),
            20
        );
        assert!(HEARTBEAT_MISS_LIMIT >= 3);
        assert!(HEARTBEAT_POLL_MS > 0 && HEARTBEAT_POLL_MS < HEARTBEAT_INTERVAL_SECS * 1000);
    }
}
