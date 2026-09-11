//! webview_low_power — 隐藏驻留时 WebView2 内存档位降 Low（2026-09-10 实测驱动）
//!
//! 背景：实测隐藏主窗 75s 后 WebView2 整树内存不降反微升（工作集
//! 479→541MB）——Chromium 对隐藏窗口不做后台裁剪。WebView2 提供
//! `ICoreWebView2_19::SetMemoryUsageTargetLevel` 官方降档信号
//! （运行时 ≥114 可用，更老运行时静默 no-op）：
//! - Low（1）= 前台切后台，WebView2 主动释放可重建的渲染资源；
//! - Normal（0）= 恢复前台。
//!
//! 挂点：lib.rs 关窗驻留隐藏处（Low）+ 唤起处（Normal：托盘 show_main_window
//! / 前端 getCurrentWindow().show()）。档位只影响内存策略，不暂停 JS——
//! 后台同步进度事件、db-change 仍可达（与方案③的销毁重建不同）。
//!
//! 直调 COM 接口而非 wry `set_memory_usage_level`：后者是 wry::WebView
//! 的扩展 trait，tauri 2.11 未透出 wry 实例（PlatformWebview 只给
//! controller/environment），走 controller.CoreWebView2() → cast 同构。

use tauri::AppHandle;
use tauri::Manager as _;

#[cfg(target_os = "windows")]
pub fn set_memory_usage_level(app: &AppHandle, low: bool) {
    use webview2_com_sys::Microsoft::Web::WebView2::Win32::{
        COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW, COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL,
        ICoreWebView2_19,
    };
    use windows_core::Interface as _;

    let Some(win) = app.get_webview_window("main") else {
        return;
    };
    // with_webview 在主线程派发；失败静默（运行时不支持即 no-op）
    if let Err(e) = win.with_webview(move |webview| {
        let controller = webview.controller();
        let core = unsafe { controller.CoreWebView2() }.and_then(|w| w.cast::<ICoreWebView2_19>());
        if let Ok(core) = core {
            let level = if low {
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW
            } else {
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL
            };
            let _ = unsafe { core.SetMemoryUsageTargetLevel(level) };
        }
    }) {
        eprintln!("[webview-low-power] 档位设置失败（不影响功能）: {e}");
    }
}

/// 非 Windows 平台：WebView 各平台无等价档位 API，静默 no-op
/// （macOS WKWebView 隐藏即挂起、Linux webkit2gtk 无该概念）。
#[cfg(not(target_os = "windows"))]
pub fn set_memory_usage_level(_app: &AppHandle, _low: bool) {}

#[cfg(test)]
mod tests {
    /// Low/Normal 枚举值契约：WebView2 SDK 固定值（0/1），防绑定升级漂移
    #[test]
    fn memory_level_constants() {
        #[cfg(target_os = "windows")]
        {
            use webview2_com_sys::Microsoft::Web::WebView2::Win32::{
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL, COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW,
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL,
            };
            assert_eq!(
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL,
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL(0)
            );
            assert_eq!(
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW,
                COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL(1)
            );
        }
    }
}
