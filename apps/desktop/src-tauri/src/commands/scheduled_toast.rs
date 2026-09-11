//! scheduled_toast — Windows 计划通知（托盘退出后的离线提醒）
//!
//! 场景：用户从托盘菜单「退出」应用后进程结束，轮询守护随之死亡——
//! 此前未来提醒全部静默。退出前把未来 24h 内的提醒注册进 Windows
//! 系统 Toast 调度器（AddToSchedule），到点由操作系统直接弹出，
//! 不依赖任何进程存活；下次启动时清除（RemoveFromSchedule）全部
//! 计划，防止与运行中的轮询通道双弹。
//!
//! 与 notify-rust 直发通道的分工：
//! - 运行中（含关窗驻留托盘）：notification_scheduler 轮询 → 系统通知
//!   （带推迟按钮，回调进程内处理）+ in-app toast
//! - 退出后：本模块的 Scheduled Toast（纯提醒文本，无按钮——进程不在，
//!   action 回调无人接，按钮只会给用户假交互）
//!
//! app_id 与 notify-rust 通道一致（cn.wait.orbit），系统按 AUMID 归组
//! 通知来源；WinRT DateTime 为 1601 元年 100ns 单位（Unix ms 换算见
//! `winrt_datetime`）。

use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::DateTime;
use windows::UI::Notifications::{ScheduledToastNotification, ToastNotificationManager};
use windows::core::HSTRING;

use crate::AppState;

/// 计划窗口：只注册未来 24h 内的提醒（对齐轮询通道的 24h 补扫上限；
/// 超出的下次启动重排——长期提醒注册进系统调度器意义有限且占槽位）
pub const SCHEDULE_WINDOW_MS: i64 = 86_400_000;

/// 计划通知的 AUMID（与 notify-rust 直发通道同口径，通知按来源归组；
/// 单一真相源在 aumid_registry——那里注册 DisplayName/IconUri 身份）
#[cfg(target_os = "windows")]
const SCHEDULED_TOAST_APP_ID: &str = crate::commands::aumid_registry::APP_ID;

/// Unix epoch ms → WinRT DateTime（1601 元年起 100ns 刻度）。
/// 纯函数便于单测（11644473600000 = 1970-1601 的 ms 差）。
pub fn winrt_datetime(unix_ms: i64) -> i64 {
    (unix_ms + 11_644_473_600_000) * 10_000
}

/// 计划提醒的 toast XML（ToastGeneric 两行：任务标题 + 提醒时刻）。
/// 纯函数便于单测；title 需 XML 转义（用户自由输入）。
pub fn scheduled_toast_xml(title: &str, time_label: &str) -> String {
    format!(
        r#"<toast scenario="reminder">
            <visual>
                <binding template="ToastGeneric">
                    <text>{}</text>
                    <text>{}</text>
                </binding>
            </visual>
            <audio src="ms-winsoundevent:Notification.Reminder"/>
        </toast>"#,
        xml_escape(title),
        xml_escape(time_label),
    )
}

/// 最小 XML 文本转义（& < > " '）
pub fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// 退出前：把 DB 未来 24h 内未删提醒全部注册进系统调度器。
/// 失败静默（DB 未解锁/未初始化时无计划提醒，退出流程不应被打断）。
/// 同步签名（quit_app 退出路径顺序执行）；DB 查询经 block_on
/// （与 notification_scheduler 的 wait_for_action 线程同款做法）。
pub fn schedule_all_on_quit(app: &tauri::AppHandle) {
    use tauri::Manager as _;
    let Some(state) = app.try_state::<AppState>() else {
        return; // DB 未就绪（未解锁即退出）：无提醒可排
    };
    let pool = state.pool.clone();

    let rows = tauri::async_runtime::block_on(async {
        let now_ms = chrono::Utc::now().timestamp_millis();
        sqlx::query_as::<_, (i64, String, i64)>(
            "SELECT r.id, t.title, r.remind_at \
             FROM todo_reminders r \
             JOIN todo_tasks t ON t.id = r.task_id \
             WHERE r.is_deleted = 0 AND t.is_deleted = 0 \
               AND r.remind_at > ?1 AND r.remind_at <= ?2 \
             ORDER BY r.remind_at ASC",
        )
        .bind(now_ms)
        .bind(now_ms + SCHEDULE_WINDOW_MS)
        .fetch_all(&pool)
        .await
    });

    let Ok(rows) = rows else { return };

    for (_id, title, remind_at) in rows {
        let _ = add_to_schedule(&title, remind_at);
    }
}

/// 启动时：清除本应用名下全部计划通知（运行中由轮询通道接管，
/// 防止同一提醒双弹）。失败静默——无计划时返回空集合。
pub fn clear_schedule_on_startup() {
    let _ = clear_scheduled_toasts();
}

/// 清空本 AUMID 名下的全部计划通知
fn clear_scheduled_toasts() -> windows::core::Result<()> {
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(
        SCHEDULED_TOAST_APP_ID,
    ))?;
    let schedule = notifier.GetScheduledToastNotifications()?;
    for scheduled in schedule {
        notifier.RemoveFromSchedule(&scheduled)?;
    }
    Ok(())
}

/// 注册单条计划通知（标题 + 到点时刻）
fn add_to_schedule(title: &str, remind_at_ms: i64) -> windows::core::Result<()> {
    use chrono::TimeZone;
    let time_label = chrono::Local
        .timestamp_millis_opt(remind_at_ms)
        .single()
        .map(|t| t.format("%m-%d %H:%M").to_string())
        .unwrap_or_default();

    let xml = scheduled_toast_xml(title, &format!("待办提醒 · {time_label}"));
    let doc = XmlDocument::new()?;
    doc.LoadXml(&HSTRING::from(&xml))?;

    let toast = ScheduledToastNotification::CreateScheduledToastNotification(
        &doc,
        DateTime {
            UniversalTime: winrt_datetime(remind_at_ms),
        },
    )?;
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(
        SCHEDULED_TOAST_APP_ID,
    ))?;
    notifier.AddToSchedule(&toast)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn winrt_epoch_offset() {
        // 1970-01-01 00:00:00 UTC = WinRT 116444736000000000
        assert_eq!(winrt_datetime(0), 116_444_736_000_000_000);
        // 已知锚点：2020-01-01 00:00:00 UTC = 1577836800000 ms
        assert_eq!(winrt_datetime(1_577_836_800_000), 132_223_104_000_000_000);
    }

    #[test]
    fn xml_escapes_user_input() {
        assert_eq!(xml_escape("A&B"), "A&amp;B");
        assert_eq!(xml_escape("<b>"), "&lt;b&gt;");
        assert_eq!(xml_escape("Task > done"), "Task &gt; done");
        assert_eq!(xml_escape("\""), "&quot;");
        assert_eq!(xml_escape("it's"), "it&apos;s");
    }

    #[test]
    fn toast_xml_contains_escaped_title() {
        let xml = scheduled_toast_xml("任务<A>&\"B\"", "待办提醒 · 09-06 12:00");
        assert!(xml.contains("任务&lt;A&gt;&amp;&quot;B&quot;"));
        assert!(xml.contains("scenario=\"reminder\""));
        assert!(xml.contains("Notification.Reminder"));
    }
}
