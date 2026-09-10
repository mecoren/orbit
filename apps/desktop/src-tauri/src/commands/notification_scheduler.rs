//! notification_scheduler — 待办提醒轮询守护（Orbit 裁剪版，06 任务 2.9）
//!
//! 桌面端 tauri-plugin-notification 的 show() 不支持定时触发，采用常驻轮询：
//! - 立即扫一次 + 每 20s 一轮（01 文档 DoD：20s 轮询窗口内触发率 100%）
//! - ⚖ 扫描与到期处置口径统一下沉 orbit-core（list_due_reminders +
//!   advance_fired_reminder）：20s 窗口 / 24h 补扫 / 任务未完成未删过滤
//!   （P1#10）/ 重复任务到期删旧建新续排（防雪球守卫在引擎内）——
//!   移动端 events.rs 轮询同源，双端口径由引擎测试锁定
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

/// 启动首轮完成标记：首轮须跳过「历史遗留」过期提醒——
/// 用户未运行应用期间错过的时间点（如上午 8 点的提醒，中午 12 点才启动）
/// 不应再弹通知轰炸；只通知「启动前后 5 分钟内到期」的行。
static FIRST_ROUND_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 过期超过此时长的提醒视为历史遗留（启动轮跳过通知，静默记入去重集合）
const STALE_SKIP_MS: i64 = 5 * 60_000;

#[derive(Clone, Serialize)]
struct ReminderDueEvent {
    id: i64,
    task_id: i64,
    title: String,
    remind_at: i64,
}

/// 推迟完成事件（前端按 reminder_id 关闭对应 in-app toast +
/// 失效 todo-task-detail 缓存）
#[derive(Clone, Serialize)]
struct ReminderSnoozedEvent {
    reminder_id: i64,
    task_id: i64,
    remind_at: i64,
    title: String,
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

    // 到期扫描口径统一下沉 orbit-core（list_due_reminders）：20s 窗口 +
    // 24h 补扫 + 任务未完成/未删过滤（P1#10：完成实例不再提醒——完成命令
    // 已软删其行，此处过滤兜历史遗留与云同步落库的僵尸行）
    let now = chrono::Utc::now().timestamp_millis();
    let rows = orbit_core::api::todo_api::list_due_reminders(&pool, now, DAY_MS, BATCH_LIMIT).await;

    let Ok(rows) = rows else { return };

    for row in &rows {
        let id = row.id;
        // 去重：进程内存活期
        if NOTIFIED_REMINDERS.lock().unwrap().contains(&id) {
            continue;
        }

        // 启动首轮跳过历史遗留：过期超过 STALE_SKIP_MS 的行不再弹通知
        // （用户没开应用期间错过的时间点，重启后补弹等于轰炸——
        // 「8 点的提醒 12 点启动还提示」即此）。静默记入去重集合，
        // 后续轮次也不会再弹；应用运行期间到期的提醒走正常路径。
        let is_first_round = !FIRST_ROUND_DONE.load(std::sync::atomic::Ordering::SeqCst);
        if is_first_round && now - row.remind_at > STALE_SKIP_MS {
            NOTIFIED_REMINDERS.lock().unwrap().insert(id);
            continue;
        }

        // ⓪ 通知历史留痕（#5：呈现轨迹入 notification_log；失败静默——
        //    日志链路不阻塞主提醒流程）
        {
            let pool = pool.clone();
            let (task_id, title, remind_at, rid) =
                (row.task_id, row.title.clone(), row.remind_at, row.id);
            tauri::async_runtime::spawn(async move {
                let _ = orbit_core::api::notification_log_api::log_notification(
                    &pool,
                    "reminder_due",
                    Some(task_id),
                    &title,
                    Some(rid),
                    &format!(r#"{{"remind_at":{remind_at}}}"#),
                )
                .await;
            });
        }

        // ① 系统通知（notify-rust 直发带推迟按钮；失败不阻塞事件通道）
        notify_system(app, id, row.task_id, &row.title, row.remind_at);

        // ② 无论成功与否 emit 事件 → 前端 sonner toast 兜底
        let _ = app.emit(
            "todo_reminder:due",
            ReminderDueEvent {
                id,
                task_id: row.task_id,
                title: row.title.clone(),
                remind_at: row.remind_at,
            },
        );

        // ③ 到期处置下沉引擎（原前端续排逻辑）：重复任务删旧建新排下一次
        //    （防雪球守卫在引擎内）；非重复/已完成行清理。窗口隐藏时照常
        let pool = pool.clone();
        let row = row.clone();
        tauri::async_runtime::spawn(async move {
            let _ = orbit_core::api::todo_api::advance_fired_reminder(&pool, &row).await;
        });

        // ④ 记入去重集合
        NOTIFIED_REMINDERS.lock().unwrap().insert(id);
    }

    // 首轮标记在处理完本轮扫描后置位（无论 DB 是否就绪——未就绪时
    // poll_once 提前返回不会走到这里，首轮将顺延到 DB 就绪后的第一轮）
    FIRST_ROUND_DONE.store(true, std::sync::atomic::Ordering::SeqCst);
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
    // title 先克隆为 owned：spawn 闭包要求 'static，&str 借用逃逸不过检查
    let app = app.clone();
    let title = title.to_string();
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
            // 通知历史留痕（#5：推迟动作；失败静默）
            {
                let app2 = app.clone();
                let title2 = title.clone();
                tauri::async_runtime::spawn(async move {
                    if let Some(state) = app2.try_state::<AppState>() {
                        let _ = orbit_core::api::notification_log_api::log_notification(
                            &state.pool,
                            "snooze",
                            Some(task_id),
                            &title2,
                            Some(reminder_id),
                            &format!(r#"{{"snooze_until":{next_at}}}"#),
                        )
                        .await;
                    }
                });
            }
            // 前端两件事：按 reminder_id 关闭对应 in-app toast（duration
            // Infinity 常驻，不主动关会一直挂着且引用已删行）+ 失效
            // todo-task-detail 缓存（详情抽屉提醒区块即时刷新）
            let _ = app.emit(
                "todo_reminder:snoozed",
                ReminderSnoozedEvent {
                    reminder_id,
                    task_id,
                    remind_at: next_at,
                    title,
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
