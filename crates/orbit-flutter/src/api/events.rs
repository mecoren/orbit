//! events — 下行事件流 + 提醒轮询守护
//!
//! 对齐桌面壳：
//! - db_cmd.rs 的 EVENT_BUS → emit("db-change") 转发任务 → 此处改为 StreamSink
//! - notification_scheduler.rs 的 20s 提醒轮询 → StreamSink 推送
//!   （系统通知由 Flutter 端 flutter_local_notifications 呈现，Rust 不再负责）
//!
//! 性能纪律（docs/05 §五）：去重集合进程内存活期，超期 24h 陈旧提醒不补弹。

use std::collections::HashSet;
use std::time::Duration;

use once_cell::sync::Lazy;
use orbit_core::eventbus::EVENT_BUS;
use orbit_core::eventbus::events::{DbEvent, DbOp};
use serde::Serialize;

// StreamSink 由 codegen 生成的模块提供（FRB 2.x 约定）
use crate::frb_generated::StreamSink;

// ── DTO（避免 core 类型直接过桥：DbEvent.payload 为 serde_json::Value）──

/// 数据库变更事件载荷（对齐桌面 TS DbChangeEvent 接口）
#[derive(Clone, Serialize)]
pub struct DbEventDto {
    pub table: String,
    /// 变体名（"Insert"/"Update"/"Delete"/"Sync"，与桌面 serde 序列化一致）
    pub op: String,
    pub record_id: i64,
    pub record_uuid: String,
    pub device_id: String,
    pub timestamp: i64,
}

impl From<&DbEvent> for DbEventDto {
    fn from(e: &DbEvent) -> Self {
        Self {
            table: e.table.clone(),
            op: match e.op {
                DbOp::Insert => "Insert",
                DbOp::Update => "Update",
                DbOp::Delete => "Delete",
                DbOp::Sync => "Sync",
            }
            .to_string(),
            record_id: e.record_id,
            record_uuid: e.record_uuid.clone(),
            device_id: e.device_id.clone(),
            timestamp: e.timestamp,
        }
    }
}

/// 提醒到期事件载荷（对齐桌面 notification_scheduler ReminderDueEvent）
#[derive(Clone, Serialize)]
pub struct ReminderDueDto {
    pub id: i64,
    pub task_id: i64,
    pub title: String,
    pub remind_at: i64,
}

const POLL_INTERVAL_SECS: u64 = 20;
/// 单轮最多处理的提醒数（防陈旧堆积一次性轰炸）
const BATCH_LIMIT: i64 = 100;
const DAY_MS: i64 = 86_400_000;

/// 在 FRB 自带的 tokio 运行时上spawn 后台任务
///
/// 不能用 flutter_rust_bridge::spawn（= tokio::spawn）：本文件两个导出函数是
/// 同步函数，执行时没有 tokio 上下文，直接 spawn 会 panic
/// （"there is no reactor running"）。FRB handler 暴露的 async_runtime 与
/// async 桥接函数共用同一运行时——sqlx 连接池也创建在该运行时上，
/// 统一到这里可避免跨运行时使用连接池的问题。
pub(crate) fn spawn_on_bridge_runtime<F>(future: F)
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    use flutter_rust_bridge::BaseAsyncRuntime;
    crate::frb_generated::FLUTTER_RUST_BRIDGE_HANDLER
        .async_runtime()
        .spawn(future);
}

/// 转发任务只允许启动一次（db_init_* 幂等保护之外的第二道闸）
static FORWARDER_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static POLLER_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 已通知去重集合（reminder.id；重启后允许重新扫描历史 24h 内项）
static NOTIFIED_REMINDERS: Lazy<std::sync::Mutex<HashSet<i64>>> =
    Lazy::new(|| std::sync::Mutex::new(HashSet::new()));

// ── FRB 导出 ──

/// 订阅数据库变更流（db-change）
///
/// Dart 侧消费：收到即全量失效业务缓存（对齐桌面粗粒度失效策略）。
pub fn subscribe_db_changes(sink: StreamSink<DbEventDto>) {
    if FORWARDER_STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        // 二次订阅场景：直接把后续事件也推给新 sink 不可行（单播设计），
        // 移动端启动流程保证仅调用一次；重复调用静默忽略。
        return;
    }
    spawn_on_bridge_runtime(async move {
        let mut rx = EVENT_BUS.subscribe();
        while let Ok(event) = rx.recv().await {
            let _ = sink.add(DbEventDto::from(&event));
        }
    });
}

/// 启动待办提醒轮询守护（幂等；Dart 在 DB 就绪后调用一次）
///
/// 扫描口径与桌面一致：
/// `WHERE is_deleted=0 AND remind_at <= now AND now - remind_at <= 24h`
pub fn start_reminder_poller(sink: StreamSink<ReminderDueDto>) {
    if POLLER_STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    spawn_on_bridge_runtime(async move {
        loop {
            poll_once(&sink).await;
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
        }
    });
}

async fn poll_once(sink: &StreamSink<ReminderDueDto>) {
    let Some(pool) = super::state::with_state_pool() else {
        return; // DB 未就绪，静默跳过
    };

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

        let _ = sink.add(ReminderDueDto {
            id,
            task_id,
            title,
            remind_at,
        });
        NOTIFIED_REMINDERS.lock().unwrap().insert(id);
    }
}
