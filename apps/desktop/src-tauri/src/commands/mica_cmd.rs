//! Mica 云母材质（Windows 专用）
//!
//! 为什么不用 Tauri 原生 `windowEffects`：
//! 实测 Tauri v2 的 `windowEffects: ["mica"]` 在本项目的无边框（decorations:false）
//! 窗口上始终不被应用（transparent 开/关都一样）。根因是 Tauri/wry 在无边框窗口
//! 上对 Mica（DWMWA_SYSTEMBACKDROP_TYPE）的处理存在局限。
//!
//! 本模块改为绕过 Tauri，直接在窗口就绪阶段调用 Windows DWM API 设置
//! `DWMSBT_MAINWINDOW`，这是社区（52pojie 实践帖）已验证可在无边框窗口渲染真 Mica 的路径。

use serde::Serialize;

#[cfg(target_os = "windows")]
use tauri::Manager;
#[cfg(target_os = "windows")]
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
#[cfg(target_os = "windows")]
use windows::Win32::Foundation::HWND;
#[cfg(target_os = "windows")]
use windows::Win32::UI::WindowsAndMessaging::{
    GetParent, GetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOREDIRECTIONBITMAP,
};
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Dwm::{
    DwmSetWindowAttribute, DwmGetWindowAttribute, DWMWA_SYSTEMBACKDROP_TYPE,
    DWMSBT_MAINWINDOW, DWMSBT_NONE,
};
#[cfg(target_os = "windows")]
use windows::Win32::System::SystemInformation::{GetVersionExW, OSVERSIONINFOW};

/// 诊断快照：返回 Mica 链路上每个关键环节的实测状态，
/// 供前端调试时一次性看清「卡在哪一层」。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MicaDiagnostics {
    pub platform: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub windows_build: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub windows_major: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub windows_minor: Option<u32>,
    /// Mica 需要 build >= 22000；Windows 10 及以下完全不支持
    pub mica_supported: bool,
    /// 系统「设置 → 个性化 → 颜色 → 透明效果」是否开启。
    /// 为 false 时 DWM 会静默忽略背景类型设置，Mica 不会渲染
    /// （DwmSetWindowAttribute 仍返回成功、读回值也正常，极具迷惑性）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transparency_enabled: Option<bool>,
    /// 顶层 HWND（十六进制字符串，便于日志对照）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_hwnd: Option<String>,
    /// 是否具备 WS_EX_NOREDIRECTIONBITMAP（Mica 渲染必需）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_no_redirection_bitmap: Option<bool>,
    /// 设置前 DWM 已生效的背景类型（0=None, 1=Mica, 2=Acrylic, 3=Tabbed）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backdrop_before: Option<i32>,
    /// 设置后读回的背景类型
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backdrop_after: Option<i32>,
    /// apply_mica_dwm 调用结果
    pub apply_result: String,
}

/// 通过 Windows DWM API 为 main 窗口设置 Mica 云母材质。
///
/// 关键细节：Tauri 的 WebView 可能嵌套在多层父窗口内，必须循环 `GetParent`
/// 找到真正的顶层 HWND，否则 `DwmSetWindowAttribute` 会落到子窗口而静默无效。
#[cfg(target_os = "windows")]
pub fn apply_mica_dwm(app: &tauri::AppHandle) -> Result<(), String> {
    set_backdrop(app, DWMSBT_MAINWINDOW)
}

/// 关闭 Mica，将窗口背景类型还原为 `DWMSBT_NONE`。
///
/// 暗色主题下叠加 Mica 会显著降低前景文字对比度，故前端切到暗色时调用本函数。
#[cfg(target_os = "windows")]
pub fn disable_mica_dwm(app: &tauri::AppHandle) -> Result<(), String> {
    set_backdrop(app, DWMSBT_NONE)
}

/// 为 main 窗口的顶层 HWND 设置 DWM 背景类型。
///
/// 注意：即便本调用返回 Ok，若系统「设置 → 个性化 → 颜色 → 透明效果」处于关闭状态，
/// DWM 也会静默忽略该属性，窗口将退化为不透明纯色背景。
#[cfg(target_os = "windows")]
fn set_backdrop(
    app: &tauri::AppHandle,
    backdrop: windows::Win32::Graphics::Dwm::DWM_SYSTEMBACKDROP_TYPE,
) -> Result<(), String> {
    let (hwnd, _webview_hwnd) = resolve_top_hwnd(app)?;
    let value = backdrop;
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &value as *const _ as *const std::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        )
        .map_err(|e| format!("DwmSetWindowAttribute failed: {e}"))?;
    }
    Ok(())
}

/// 解析 main 窗口的顶层 HWND，顺带返回 WebView 自身 HWND（用于诊断）。
#[cfg(target_os = "windows")]
fn resolve_top_hwnd(
    app: &tauri::AppHandle,
) -> Result<(HWND, HWND), String> {
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| "main window not found".to_string())?;
    let handle = window
        .window_handle()
        .map_err(|e| format!("get window handle failed: {e}"))?;

    let webview_hwnd = match handle.as_raw() {
        RawWindowHandle::Win32(h) => {
            HWND(h.hwnd.get() as *mut std::ffi::c_void)
        }
        _ => return Err("not a win32 window".to_string()),
    };

    // 循环向上查找真正的顶层父窗口
    let mut current = webview_hwnd;
    unsafe {
        loop {
            match GetParent(current) {
                Ok(parent) if parent.0 != std::ptr::null_mut() => current = parent,
                _ => break,
            }
        }
    }
    Ok((current, webview_hwnd))
}

/// 读取 Windows 内部版本号（Mica 需 build >= 22000，即 Windows 11 22H2+）。
/// 注：GetVersionExW 受 manifest 兼容性引导影响可能返回 Win8 值，
/// 仅用于粗判是否完全不支持（如 Win10），不用于精确版本断言。
#[cfg(target_os = "windows")]
fn windows_build_number() -> Option<(u32, u32, u32)> {
    unsafe {
        let mut info: OSVERSIONINFOW = std::mem::zeroed();
        info.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;
        GetVersionExW(&mut info).ok()?;
        Some((info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber))
    }
}

/// 读取 `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
/// 下的 `EnableTransparency`，即系统「透明效果」开关。
///
/// 该开关关闭时，DWM 会静默忽略 `DWMWA_SYSTEMBACKDROP_TYPE`，
/// Mica 完全不渲染，且 API 调用与读回值均显示"正常"。
#[cfg(target_os = "windows")]
fn transparency_enabled() -> Option<bool> {
    use windows::core::w;
    use windows::Win32::System::Registry::{
        RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD,
    };

    let mut value: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("EnableTransparency"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut _ as *mut std::ffi::c_void),
            Some(&mut size),
        )
    };
    if status.is_ok() {
        Some(value != 0)
    } else {
        None
    }
}

/// 读取当前 DWM 背景类型（DWMSBT_*)。
#[cfg(target_os = "windows")]
fn read_backdrop(hwnd: HWND) -> Option<i32> {
    let mut value: i32 = 0;
    unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &mut value as *mut _ as *mut std::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        )
        .ok()?;
    }
    Some(value)
}

/// 读取 GWL_EXSTYLE 并判定是否含 WS_EX_NOREDIRECTIONBITMAP。
#[cfg(target_os = "windows")]
fn has_no_redirection_bitmap(hwnd: HWND) -> Option<bool> {
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        Some((ex & (WS_EX_NOREDIRECTIONBITMAP.0 as isize)) != 0)
    }
}

/// 诊断命令：一次性返回 Mica 链路所有关键证据。
/// 前端调试时调用 `invoke('mica_diagnostics')` 即可看到卡在哪一层。
#[tauri::command]
pub fn mica_diagnostics(app: tauri::AppHandle) -> MicaDiagnostics {
    #[cfg(target_os = "windows")]
    {
        let (major, minor, build) = windows_build_number()
            .unwrap_or((0, 0, 0));
        let mica_supported = build >= 22000;

        let top_hwnd_info = resolve_top_hwnd(&app).ok().map(|(top, _wv)| {
            (top, has_no_redirection_bitmap(top))
        });

        let top_hwnd = top_hwnd_info.map(|(h, _)| format!("{:p}", h.0));
        let has_nrbitmap = top_hwnd_info.and_then(|(_, f)| f);
        let backdrop_before = top_hwnd_info.and_then(|(h, _)| read_backdrop(h));

        let apply_result = match apply_mica_dwm(&app) {
            Ok(_) => "ok".to_string(),
            Err(e) => format!("error: {e}"),
        };

        let backdrop_after = top_hwnd_info.and_then(|(h, _)| read_backdrop(h));

        MicaDiagnostics {
            platform: "windows".to_string(),
            windows_major: Some(major),
            windows_minor: Some(minor),
            windows_build: Some(build),
            mica_supported,
            transparency_enabled: transparency_enabled(),
            top_hwnd,
            has_no_redirection_bitmap: has_nrbitmap,
            backdrop_before,
            backdrop_after,
            apply_result,
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = app;
        MicaDiagnostics {
            platform: std::env::consts::OS.to_string(),
            windows_build: None,
            windows_major: None,
            windows_minor: None,
            mica_supported: false,
            transparency_enabled: None,
            top_hwnd: None,
            has_no_redirection_bitmap: None,
            backdrop_before: None,
            backdrop_after: None,
            apply_result: "skipped (non-windows)".to_string(),
        }
    }
}

/// 供前端兜底调用的命令（幂等）。setup 阶段已调用 `apply_mica_dwm`，
/// 本命令用于窗口重建等场景下重新断言材质。非 Windows 平台直接成功返回。
#[tauri::command]
pub fn apply_mica(app: tauri::AppHandle) {
    #[cfg(target_os = "windows")]
    {
        if let Err(e) = apply_mica_dwm(&app) {
            eprintln!("[mica] apply failed: {e}");
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = app;
    }
}

/// 关闭 Mica（幂等）。前端在切换到暗色主题时调用。
/// 非 Windows 平台直接成功返回。
#[tauri::command]
pub fn disable_mica(app: tauri::AppHandle) {
    #[cfg(target_os = "windows")]
    {
        if let Err(e) = disable_mica_dwm(&app) {
            eprintln!("[mica] disable failed: {e}");
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = app;
    }
}
