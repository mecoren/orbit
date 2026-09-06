//! notification_scheduler — 待办提醒轮询守护（Orbit 裁剪版，06 任务 2.9）
//!
//! 桌面端 tauri-plugin-notification 的 show() 不支持定时触发，采用常驻轮询：
//! - 立即扫一次 + 每 20s 一轮（01 文档 DoD：20s 轮询窗口内触发率 100%）
//! - ⚖ 专用 SQL（弃用 ListFilter::default()，修复 page_size=20 漏扫隐患）：
//!   `WHERE is_deleted=0 AND remind_at <= now AND now - remind_at <= 24h`
//! - 去重集合进程内存活期，超期 24h 以上陈旧提醒不补弹
//! - 触发双通道：系统通知（notify-rust 直发，带推迟按钮，P2 升级）
//!   + emit "todo_reminder:due"（前端 toast 兜底，亦带推迟按钮）
//! - DB 未就绪：try_state 失败时静默跳过，初始化完成后自动开始工作
//!
//! P2 升级（系统通知推迟按钮）：
//! - tauri-plugin-notification 的 desktop.rs 不透传 actions，故绕开插件
//!   直用 notify-rust 4.18（三平台 action 支持矩阵见其 README：
//!   Linux XDG ✔ / macOS NSUser ✔(labels) / macOS UNUser ✔ / Windows ✔）。
//! - show() 返回 NotificationHandle；每条通知 spawn 一个阻塞线程
//!   wait_for_action（跨平台 API），收到 snooze action 后：
//!   ① 删旧建新写 DB（orbit-core business_api，桌面环境直写）；
//!   ② emit "todo_reminder:snoozed" → 前端失效详情缓存。
//! - 推迟语义与前端 toast 相同：新 remind_at = 原 remind_at + N 分钟
//!   （锚点不漂移）。
//! - Windows app_id 用进程 AUMID cn.wait.orbit；开发态（未安装）Toast
//!   显示来源为 PowerShell 系插件既有限制，不影响按钮功能。
//!
//! 已剔除 wait-home 版的 important_events 段。

use std::collections::HashSet;
use std::time::Duration;

use once_cell::sync::Lazy;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use crate::AppState;

const POLL_INTERVAL_SECS: u64 = 20;
/// 单轮最多处理的提醒数（防陈旧堆积一次性轰炸）
const BATCH_LIMIT: i64 = 100;
const DAY_MS: i64 = 86_400_000;

/// 系统通知推迟档位（action id → 分钟；与前端 SNOOZE_PRESETS 同口径）
const SNOOZE_ACTIONS: &[(&str, i64)] = &[("snooze_10", 10), ("snooze_30", 30), ("snooze_60", 60)];

static POLLER_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 已通知去重集合（reminder.id；重启后允许重新扫描历史 24h 内项）
static NOTIFIED_REMINDERS: Lazy<std::sync::Mutex<HashSet<i64>>> =
    Lazy::new(|| std::sync::Mutex::new(HashSet::new()));

#[derive(Clone, Serialize)]
struct ReminderDueEvent {
    id: i64,
    task_id: i64,
    title: String,
    remind_at: i64,
}

/// 推迟完成事件（前端失效 todo-task-detail 缓存用）
#[derive(Clone, Serialize)]
struct ReminderSnoozedEvent {
    task_id: i64,
    remind_at: i64,
}

/// 启动待办提醒轮询守护（幂等；lib.rs setup 阶段调用）
pub fn todo_reminder_start_poller(app: AppHandle) {
    use std::sync::atomic::Ordering;
    if POLLER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }

    tauri::async_runtime::spawn(async move {
        loop {
            poll_once(&app).await;
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
        }
    });
}

async fn poll_once(app: &AppHandle) {
    let Some(state) = app.try_state::<AppState>() else {
        return; // DB 未就绪，静默跳过
    };
    let pool = state.pool.clone();

    // 专用 SQL：JOIN 任务标题；仅扫「已到期且未超期 24h」的未删除提醒
    let now = chrono::Utc::now().timestamp_millis();
    let rows = sqlx::query_as::<_, (i64, i64, String, i64)>(
        "SELECT r.id, r.task_id, t.title, r.remind_at \
         FROM todo_reminders r \
         JOIN todo_tasks t ON t.id = r.task_id \
         WHERE r.is_deleted = 0 AND r.remind_at <= ?1 AND ?1 - r.remind_at <= ?2 \
         ORDER BY r.remind_at ASC LIMIT ?3",
    )
    .bind(now)
    .bind(DAY_MS)
    .bind(BATCH_LIMIT)
    .fetch_all(&pool)
    .await;

    let Ok(rows) = rows else { return };

    for (id, task_id, title, remind_at) in rows {
        // 去重：进程内存活期
        if NOTIFIED_REMINDERS.lock().unwrap().contains(&id) {
            continue;
        }

        // ① 系统通知（notify-rust 直发带推迟按钮；失败不阻塞事件通道）
        notify_system(app, id, task_id, &title, remind_at);

        // ② 无论成功与否 emit 事件 → 前端 sonner toast 兜底
        let _ = app.emit(
            "todo_reminder:due",
            ReminderDueEvent {
                id,
                task_id,
                title,
                remind_at,
            },
        );

        // ③ 记入去重集合
        NOTIFIED_REMINDERS.lock().unwrap().insert(id);
    }
}

/// 系统通知直发（notify-rust，绕开 tauri 插件的 actions 缺口）。
///
/// Windows 侧 app_id 决定通知来源显示名与激活路由；用包标识
/// cn.wait.orbit（正式安装后的 AUMID）。macOS/Linux 由 notify-rust
/// 内部处理（mac 走 NSUser/UNUser 自动选择）。
fn notify_system(app: &AppHandle, reminder_id: i64, task_id: i64, title: &str, remind_at: i64) {
    let body = format!("待办提醒 · {}", fmt_time(remind_at));

    let mut n = notify_rust::Notification::new();
    // Windows 侧 app_id 决定通知来源显示名与激活路由；用包标识
    // cn.wait.orbit（正式安装后的 AUMID）。macOS/Linux 由 notify-rust
    // 内部处理（appname 对 mac 是静默 no-op）。
    #[cfg(target_os = "windows")]
    {
        n.app_id("cn.wait.orbit");
    }
    #[cfg(not(target_os = "windows"))]
    {
        n.appname("Orbit");
    }

    let n = n
        .summary(title)
        .body(&body)
        // timeout Never：带按钮的通知不该自动消失（等用户选择）；
        // mac NSUser 路径会忽略 timeout，系统默认停留后进通知中心
        .timeout(notify_rust::Timeout::Never);

    let mut n = n;
    for (action_id, _) in SNOOZE_ACTIONS {
        n = n.action(action_id, action_label(action_id));
    }

    let handle = n.show();
    let Ok(handle) = handle else { return };

    // 每条通知一个阻塞等待线程（wait_for_action 跨平台；通知关闭/超时
    // 回调 "__closed"）。桌面常驻进程模型下线程随通知生命周期结束。
    let app = app.clone();
    std::thread::spawn(move || {
        // wait_for_action 消费 handle（FnOnce 回调）；先经 channel 转出
        // action 串，把后续写库留在本线程主体（闭包内不能 async）
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        handle.wait_for_action(move |a| {
            let _ = tx.send(a.to_string());
        });
        let Ok(action) = rx.recv() else { return };
        let Some(minutes) = SNOOZE_ACTIONS
            .iter()
            .find(|(id, _)| *id == action)
            .map(|(_, m)| *m)
        else {
            return; // "__closed"（正文点击/关闭/超时）或未知 action：不处理
        };
        let next_at = remind_at + minutes * 60_000;
        // 删旧建新（business_api 软删 + 新建；锚点=原 remind_at）。
        // 失败静默：系统通知已消失，前端 toast 兜底通道仍在。
        let done = tauri::async_runtime::block_on(async {
            let Some(state) = app.try_state::<AppState>() else {
                return false;
            };
            let pool = state.pool.clone();
            let del = orbit_core::api::business_api::delete_todo_reminder(&pool, reminder_id).await;
            if del.is_err() {
                return false;
            }
            let created = orbit_core::api::business_api::create_todo_reminder(
                &pool,
                &orbit_core::models::business::TodoReminderCreateInput {
                    task_id,
                    remind_at: next_at,
                },
            )
            .await;
            created.is_ok()
        });
        if done {
            // 前端失效 todo-task-detail 缓存（详情抽屉提醒区块即时刷新）
            let _ = app.emit(
                "todo_reminder:snoozed",
                ReminderSnoozedEvent {
                    task_id,
                    remind_at: next_at,
                },
            );
        }
    });
}

/// action 显示标签（与前端 SNOOZE_PRESETS 文案一致）
fn action_label(action_id: &str) -> &'static str {
    match action_id {
        "snooze_10" => "推迟10分钟",
        "snooze_30" => "推迟30分钟",
        "snooze_60" => "推迟1小时",
        _ => "",
    }
}

fn fmt_time(ms: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_millis_opt(ms)
        .single()
        .map(|dt| dt.format("%H:%M").to_string())
        .unwrap_or_default()
}
