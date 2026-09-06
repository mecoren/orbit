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

/// 初始化系统托盘（桌面专属；setup 阶段调用一次）
///
/// 图标复用应用图标（tauri.conf 的 bundle icon 首个 PNG）。
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

    let mut builder = TrayIconBuilder::with_id("orbit-tray")
        .icon(app.default_window_icon().cloned().unwrap().clone())
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
}
