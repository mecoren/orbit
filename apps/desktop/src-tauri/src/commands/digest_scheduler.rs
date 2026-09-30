//! digest_scheduler — 每日摘要提醒守护（对标 TickTick Daily Reminder）
//!
//! 60s tick 轮询（与 trash_scheduler / holiday_scheduler 同模式）：
//! - DB 未就绪（try_state 无 AppState）→ 静默跳过；
//! - `digest_api::take_due_digest` 内部判定（开关 + 当天目标时刻已过 + 当天未处置；
//!   迟到超 12h 补弹窗口则静默跳过，见 core 模块头）；
//! - 命中 → notify-rust 系统通知（标题「今日待办摘要」+ 摘要文案）+ 写
//!   `notification_log`（kind `digest`，供通知历史中心回溯）；
//! - 通知正文点击 → 唤起主窗（摘要非任务级通知，无详情路由）；
//! - 失败静默（下一轮 tick 重试）；成功不打扰 UI（后台行为）。
//!
//! 文案由 `digest_api::summary_body` 生成——与移动端排程时算出的文案同一份
//! 实现（单一真相源，避免双端措辞漂移）。
//!
//! 首轮不跳过：与提醒轮询的「启动首轮跳过历史遗留」不同——摘要的「遗留」
//! 判定已由 core 的补弹窗口承担，这里照常判定即可。

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::{AppHandle, Manager};

use orbit_core::api::{digest_api, notification_log_api};

use crate::AppState;

/// tick 周期：60s（判定轻量；每天最多实际发送一次）
const TICK_SECS: u64 = 60;

static SCHEDULER_STARTED: AtomicBool = AtomicBool::new(false);

/// 启动每日摘要守护（幂等；lib.rs setup 阶段调用）
pub fn digest_scheduler_start(app: AppHandle) {
    if SCHEDULER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        loop {
            tick(&app).await;
            tokio::time::sleep(std::time::Duration::from_secs(TICK_SECS)).await;
        }
    });
}

async fn tick(app: &AppHandle) {
    let Some(state) = app.try_state::<AppState>() else {
        return; // DB 未就绪（未初始化/迁移中），静默跳过
    };
    let now = chrono::Utc::now().timestamp_millis();

    let summary = match digest_api::take_due_digest(&state.pool, now).await {
        Ok(Some(s)) => s,
        // 未到点 / 当天已处置 / 开关关闭 → 静默
        Ok(None) => return,
        Err(e) => {
            eprintln!("[digest-scheduler] 摘要判定失败（下轮重试）: {e}");
            return;
        }
    };

    let body = digest_api::summary_body(&summary);
    notify_digest(app, &body);

    // 通知历史留痕（kind digest；失败静默——日志链路不阻塞通知主流程）
    let payload = format!(
        r#"{{"due_today":{},"overdue":{},"done_today":{}}}"#,
        summary.due_today, summary.overdue, summary.done_today
    );
    if let Err(e) =
        notification_log_api::log_notification(&state.pool, "digest", None, "每日摘要", None, &payload)
            .await
    {
        eprintln!("[digest-scheduler] 通知留痕失败（不影响发送）: {e}");
    }
}

/// 系统通知直发（notify-rust；与 notification_scheduler 同口径 app_id）。
///
/// 无 action 按钮、默认超时（摘要是一次性提示，不该常驻等操作）。
/// 正文点击（Default）→ 唤起主窗；其余（关闭/超时）不处理。
fn notify_digest(app: &AppHandle, body: &str) {
    let mut n = notify_rust::Notification::new();
    #[cfg(target_os = "windows")]
    {
        use crate::commands::aumid_registry::APP_ID;
        n.app_id(APP_ID);
    }
    #[cfg(not(target_os = "windows"))]
    {
        n.appname("循迹");
    }

    let handle = n.summary("今日待办摘要").body(body).show();
    let Ok(handle) = handle else { return };

    // 一个阻塞等待线程（通知生命周期结束即释放）。wait_for_response 消费
    // handle 且回调不能 async，故经 channel 转出响应后在主体处理
    let app = app.clone();
    std::thread::spawn(move || {
        let (tx, rx) = std::sync::mpsc::channel::<notify_rust::NotificationResponse>();
        if handle
            .wait_for_response(move |r: &notify_rust::NotificationResponse| {
                let _ = tx.send(r.clone());
            })
            .is_err()
        {
            return;
        }
        if let Ok(notify_rust::NotificationResponse::Default) = rx.recv() {
            crate::commands::window_recycler::show_or_create_main_window(&app);
        }
    });
}
