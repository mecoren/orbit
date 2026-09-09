//! tray — 桌面系统托盘 + 关窗驻留（07 报告 #16）
//!
//! 语义：
//! - 关闭主窗口 = 驻留托盘（数据守护：同步调度器 / 备份调度器 / 提醒轮询
//!   均在壳内常驻，关窗退出会中断 60s tick 与到期提醒——与「本地优先
//!   任务管理常驻」的产品定位冲突）；
//! - 托盘菜单：显示主窗 / 快速新建（前端经 quick-add-intent 事件聚焦
//!   输入）/ 退出；
//! - 单击托盘 = 显示/聚焦主窗（Windows/macOS 主流行为）；
//! - 双击主窗关闭按钮弹一次驻留提示（告知退出入口在托盘），此后静默驻留。
//!
//! 快速新建走事件而非直接路由：壳层不感知前端路由，前端监听
//! `tray-quick-add` 事件自行聚焦快速输入栏（与 taskFormIntent 意图机制同构）。

use serde::Serialize;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager};

/// 前端事件：托盘「快速新建」触发（无载荷；前端聚焦 QuickAddBar）
pub const TRAY_QUICK_ADD_EVENT: &str = "tray-quick-add";

/// 托盘菜单动作标识（与构建器注册一一对应；纯数据便于单测）
pub const MENU_ITEM_SHOW: &str = "show";
pub const MENU_ITEM_QUICK_ADD: &str = "quick_add";
pub const MENU_ITEM_QUIT: &str = "quit";

/// 菜单结构定义（纯数据；构建器消费 + `tray_menu_ids` 单测校验完整性与唯一性）
pub struct TrayMenuSpec {
    /// (id, label) 有序对：顺序即菜单展示顺序
    pub items: &'static [(&'static str, &'static str)],
}

/// 当前托盘菜单规格：显示主窗 / 快速新建 / 退出
pub const TRAY_MENU_SPEC: TrayMenuSpec = TrayMenuSpec {
    items: &[
        (MENU_ITEM_SHOW, "显示循迹"),
        (MENU_ITEM_QUICK_ADD, "快速新建任务"),
        (MENU_ITEM_QUIT, "退出"),
    ],
};

/// 退出应用：销毁主窗（绕过驻留拦截）+ app.exit。
/// 退出前把未来 24h 提醒注册进 Windows 系统 Toast 调度器——
/// 进程结束后到点由操作系统直接弹（离线提醒，无需进程存活）；
/// 下次启动时 scheduled_toast::clear_schedule_on_startup 清除，
/// 防止与运行中的轮询通道双弹。
pub fn quit_app(app: &AppHandle) {
    #[cfg(target_os = "windows")]
    crate::commands::scheduled_toast::schedule_all_on_quit(app);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.destroy();
    }
    app.exit(0);
}

/// 显示并聚焦主窗（最小化态恢复）
pub fn show_main_window(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

/// 盒式下采样（区域平均）：每输出像素聚合 (sw/target)² 源像素，
/// 保真优于 shell 双线性拉伸；alpha 同步平均保持抗锯齿边缘。
fn downscale_rgba(src: &tauri::image::Image<'_>, target: u32) -> tauri::image::Image<'static> {
    let (sw, sh) = (src.width(), src.height());
    if target == sw && target == sh {
        return tauri::image::Image::to_owned(src.clone());
    }
    let rgba = src.rgba();
    let scale = sw as f64 / target as f64;
    let mut out = vec![0u8; (target as usize) * (target as usize) * 4];
    for ty in 0..target {
        for tx in 0..target {
            let x0 = (tx as f64 * scale).floor() as u32;
            let y0 = (ty as f64 * scale).floor() as u32;
            let x1 = (((tx + 1) as f64 * scale).ceil() as u32).min(sw);
            let y1 = (((ty + 1) as f64 * scale).ceil() as u32).min(sh);
            let (mut r, mut g, mut b, mut a, mut n) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for y in y0..y1 {
                for x in x0..x1 {
                    let i = ((y * sw + x) * 4) as usize;
                    r += rgba[i] as u32;
                    g += rgba[i + 1] as u32;
                    b += rgba[i + 2] as u32;
                    a += rgba[i + 3] as u32;
                    n += 1;
                }
            }
            let o = ((ty * target + tx) * 4) as usize;
            out[o] = (r / n.max(1)) as u8;
            out[o + 1] = (g / n.max(1)) as u8;
            out[o + 2] = (b / n.max(1)) as u8;
            out[o + 3] = (a / n.max(1)) as u8;
        }
    }
    tauri::image::Image::new_owned(out, target, target)
}

/// 系统托盘图标位图：Windows 下按 shell 小图标标准尺寸（SM_CXSMICON，
/// 100% 缩放 16px、随 DPI 走 20/24px+）从 default_window_icon 下采样生成。
///
/// 为什么不复用 default_window_icon（256px）：tray-icon 的 Windows 实现
/// 原样按位图尺寸 CreateIcon，shell 随后把 256px HICON 低质量拉伸到
/// ~16px 显示（模糊）；窗口图标则需要大位图供任务栏清晰缩放——两者
/// 尺寸诉求相反，故托盘持独立小图（2026-09-09 任务栏/托盘先后糊的根因）。
fn tray_icon_bitmap(app: &AppHandle) -> Option<tauri::image::Image<'static>> {
    // default_window_icon() 借 app（&Image<'a>），clone 后经 downscale_rgba
    // 产出独立 'static 位图（源借用当场结束）。
    let src = app.default_window_icon()?;
    // 托盘显示尺寸：非 Windows 无 shell 度量差异，直用源图尺寸
    #[cfg(target_os = "windows")]
    let target = {
        use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSMICON};
        let m = unsafe { GetSystemMetrics(SM_CXSMICON) };
        if m > 0 { m as u32 } else { 16 }
    };
    #[cfg(not(target_os = "windows"))]
    let target = src.width();
    Some(downscale_rgba(src, target))
}

/// 初始化系统托盘（桌面专属；setup 阶段调用一次）
///
/// 图标：托盘持精确 shell 小图标尺寸的独立位图（见 tray_icon_bitmap）；
/// 窗口图标仍是 default_window_icon 256px（任务栏清晰缩放）。
/// 菜单项点击经 on_menu_event 分发：show/quit 直处理，
/// quick_add 转发 `tray-quick-add` 事件给前端。
pub fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
    // 菜单项由 TRAY_MENU_SPEC 驱动（规格与实现同源，防漂移）
    let items: Vec<MenuItem<tauri::Wry>> = TRAY_MENU_SPEC
        .items
        .iter()
        .map(|(id, label)| MenuItem::with_id(app, *id, *label, true, None::<&str>))
        .collect::<tauri::Result<_>>()?;
    let item_refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = items
        .iter()
        .map(|i| i as &dyn tauri::menu::IsMenuItem<_>)
        .collect();
    let menu = Menu::with_items(app, &item_refs)?;

    let tray_img = tray_icon_bitmap(app).expect("default_window_icon 未配置（tauri.conf bundle.icon）");
    let mut builder = TrayIconBuilder::with_id("orbit-tray")
        .icon(tray_img)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            MENU_ITEM_SHOW => show_main_window(app),
            MENU_ITEM_QUICK_ADD => {
                let _ = app.emit(TRAY_QUICK_ADD_EVENT, TrayQuickAddPayload {});
            }
            MENU_ITEM_QUIT => quit_app(app),
            _ => {}
        });

    // 单击托盘显示主窗（Windows/macOS 主流行为；菜单在右键）
    builder = builder.on_tray_icon_event(|tray, event| {
        if let tauri::tray::TrayIconEvent::Click {
            button: tauri::tray::MouseButton::Left,
            button_state: tauri::tray::MouseButtonState::Up,
            ..
        } = event
        {
            let app = tray.app_handle().clone();
            show_main_window(&app);
        }
    });

    builder.build(app)?;
    Ok(())
}

/// tray-quick-add 事件载荷（占位结构；前端仅依赖事件名）
#[derive(Debug, Clone, Serialize)]
pub struct TrayQuickAddPayload {}

#[cfg(test)]
mod tests {
    use super::*;

    /// 菜单规格完整性：三项齐全且唯一（缺失即菜单构建遗漏）
    #[test]
    fn tray_menu_ids_complete_and_unique() {
        let items = TRAY_MENU_SPEC.items;
        assert_eq!(items.len(), 3);
        let ids: Vec<&str> = items.iter().map(|(id, _)| *id).collect();
        for expected in [MENU_ITEM_SHOW, MENU_ITEM_QUICK_ADD, MENU_ITEM_QUIT] {
            assert!(ids.contains(&expected), "菜单缺项: {expected}");
        }
        // 唯一性
        let mut sorted = ids.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), ids.len(), "菜单 id 重复");
        // label 非空（展示项）
        for (_, label) in items {
            assert!(!label.is_empty(), "菜单 label 为空");
        }
    }

    /// 事件名稳定：前端监听依赖字符串契约
    #[test]
    fn tray_event_name_stable() {
        assert_eq!(TRAY_QUICK_ADD_EVENT, "tray-quick-add");
    }

    /// 盒式下采样：输出尺寸精确 = 目标尺寸
    #[test]
    fn downscale_output_dimensions() {
        // 4x4 纯色 → 2x2
        let src = tauri::image::Image::new_owned(vec![255u8; 4 * 4 * 4], 4, 4);
        let out = downscale_rgba(&src, 2);
        assert_eq!((out.width(), out.height()), (2, 2));
        // 同尺寸直通
        let out = downscale_rgba(&src, 4);
        assert_eq!((out.width(), out.height()), (4, 4));
    }

    /// 盒式下采样：区域平均正确（2x2 混合色块 → 1x1 均值）
    #[test]
    fn downscale_box_average() {
        // 左半红 (255,0,0) 右半蓝 (0,0,255)，缩 2→1 后应为 (127,0,127)
        let mut rgba = vec![0u8; 2 * 2 * 4];
        for i in 0..4 {
            let red = i % 2 == 0;
            rgba[i * 4] = if red { 255 } else { 0 };
            rgba[i * 4 + 2] = if red { 0 } else { 255 };
            rgba[i * 4 + 3] = 255;
        }
        let src = tauri::image::Image::new_owned(rgba, 2, 2);
        let out = downscale_rgba(&src, 1);
        let px = out.rgba();
        assert_eq!(&px[..3], &[127, 0, 127]);
        assert_eq!(px[3], 255);
    }

    /// 盒式下采样：透明区域保持全透明（alpha 同步平均，不残留灰底）
    #[test]
    fn downscale_preserves_transparency() {
        // 4x4 全透明 → 2x2 输出 alpha 应为 0
        let src = tauri::image::Image::new_owned(vec![0u8; 4 * 4 * 4], 4, 4);
        let out = downscale_rgba(&src, 2);
        assert!(out.rgba().iter().skip(3).step_by(4).all(|a| *a == 0));
    }

    /// 非整倍缩放（256→16，scale=16 整除；换 5→2 覆盖 ceil/floor 边界）
    #[test]
    fn downscale_non_integer_scale() {
        // 5px 宽度缩到 2px：像素盒 0-2.5/2.5-5 → 输出聚合 3+2 源列，不越界
        let mut rgba = vec![0u8; 5 * 5 * 4];
        for px in rgba.chunks_exact_mut(4) {
            px[0] = 200;
            px[3] = 255;
        }
        let src = tauri::image::Image::new_owned(rgba, 5, 5);
        let out = downscale_rgba(&src, 2);
        assert_eq!((out.width(), out.height()), (2, 2));
        assert!(out.rgba().chunks_exact(4).all(|p| p[0] == 200 && p[3] == 255));
    }
}
