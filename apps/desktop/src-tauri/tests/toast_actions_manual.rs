//! Windows 系统通知三按钮手动验证（P2 提醒升级）。
//!
//! 独立可执行验证：不依赖 Tauri App / vite dev server，直接以
//! notify-rust 发一条带三档推迟按钮的系统 Toast（与本 App
//! notification_scheduler::notify_system 完全同口径），点击按钮后
//! 在 stdout 打印收到的 action id——供真机验收「右下角弹窗带推迟
//! 按钮 + 点击回调链路」。
//!
//! 运行：
//! ```text
//! cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml \
//!   --test toast_actions_manual -- --ignored --nocapture
//! ```
//! 手动测试（#[ignore]：需要真人点按钮，不进 CI）。

use notify_rust::Notification;

/// 与 notification_scheduler::SNOOZE_ACTIONS 同口径
const SNOOZE_ACTIONS: &[(&str, &str)] = &[
    ("snooze_10", "推迟10分钟"),
    ("snooze_30", "推迟30分钟"),
    ("snooze_60", "推迟1小时"),
];

#[test]
#[ignore = "手动验收：弹出真实系统通知，需点击按钮观察回调"]
fn toast_with_snooze_buttons() {
    let mut n = Notification::new();
    #[cfg(target_os = "windows")]
    {
        n.app_id("cn.wait.orbit");
    }
    #[cfg(not(target_os = "windows"))]
    {
        n.appname("Orbit");
    }

    let n = n
        .summary("手动验收：待办提醒（通知按钮）")
        .body("点一个推迟按钮，终端将打印收到的 action id")
        .timeout(notify_rust::Timeout::Never);

    let mut n = n;
    for (id, label) in SNOOZE_ACTIONS {
        n = n.action(id, label);
    }

    let handle = n.show().expect("系统通知发送失败");
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    handle.wait_for_action(move |a| {
        let _ = tx.send(a.to_string());
    });
    let action = rx.recv().expect("等待 action 回调通道关闭");
    println!("[toast_manual] received action: {action}");
    assert!(
        SNOOZE_ACTIONS.iter().any(|(id, _)| *id == action),
        "应收到三个推迟 action 之一，实际收到: {action}"
    );
    println!("[toast_manual] PASS：三按钮通知 + 回调链路正常");
}
