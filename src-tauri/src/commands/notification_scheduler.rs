//! notification_scheduler — 待办提醒轮询守护（Orbit 裁剪版，06 任务 2.9）
//!
//! 桌面端 tauri-plugin-notification 的 show() 不支持定时触发，采用常驻轮询：
//! - 立即扫一次 + 每 20s 一轮（01 文档 DoD：20s 轮询窗口内触发率 100%）
//! - ⚖ 专用 SQL（弃用 ListFilter::default()，修复 page_size=20 漏扫隐患）：
//!   `WHERE is_deleted=0 AND remind_at <= now AND now - remind_at <= 24h`
//! - 去重集合进程内存活期，超期 24h 以上陈旧提醒不补弹
//! - 触发双通道：系统通知（尽力）+ emit "todo_reminder:due"（前端 toast 兜底）
//! - DB 未就绪：try_state 失败时静默跳过，初始化完成后自动开始工作
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

        // ① 系统通知（尽力而为，失败不阻塞事件通道）
        notify_system(app, id, &title, remind_at);

        // ② 无论成功与否 emit 事件 → 前端 sonner toast 兜底
        let _ = app.emit(
            "todo_reminder:due",
            ReminderDueEvent { id, task_id, title, remind_at },
        );

        // ③ 记入去重集合
        NOTIFIED_REMINDERS.lock().unwrap().insert(id);
    }
}

fn notify_system(app: &AppHandle, reminder_id: i64, title: &str, remind_at: i64) {
    use tauri_plugin_notification::NotificationExt;

    let body = format!("待办提醒 · {}", fmt_time(remind_at));
    let notification = app
        .notification()
        .builder()
        .title(title)
        .body(body)
        // 通知 id 与提醒 id 对应（i32 正数域）
        .id((reminder_id % 2_147_483_647) as i32);
    let _ = notification.show();
}

fn fmt_time(ms: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_millis_opt(ms)
        .single()
        .map(|dt| dt.format("%H:%M").to_string())
        .unwrap_or_default()
}
