//! notification_log — 移动端桥接层通知历史域（#5 高价值缺口）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在
//! orbit_core::api::notification_log_api）：
//! - [notification_log_list] → 桌面 `notification_log_list`；
//! - [notification_log_clear] → 桌面 `notification_log_clear`。
//!
//! ## 口径
//! - 写入（`log_notification`）不经命令面：移动端由
//!   `services/notification_service.dart` 呈现通知时经
//!   [super::events] 的提醒轮询守护落库（桌面同口径）；
//! - 查询/清空**不 emit db-change**（本地呈现轨迹，各端各自记录，
//!   不进 `sync_registry` 白名单；UI 靠主动 refetch 刷新）；
//! - TTL 清理（30 天）由 [super::trash] 的守护 tick 顺带执行，不单独导出。
//!
//! ## DTO 镜像模式
//! [NotificationLogRow] 为本地镜像（同 [super::dto] 规则），避免 core 类型
//! 过桥被 FRB 降级为 opaque。

use orbit_core::api::notification_log_api;
use serde::Serialize;

/// 通知历史行（镜像 orbit_core::api::notification_log_api::NotificationLogRow）
#[derive(Debug, Clone, Serialize)]
pub struct NotificationLogRow {
    pub id: i64,
    /// reminder_due / snooze / complete / boot_skip
    pub kind: String,
    pub task_id: Option<i64>,
    /// 任务标题快照（任务后续被删仍可读）
    pub task_title: String,
    pub reminder_id: Option<i64>,
    /// 附加 JSON：{remind_at, snooze_until, source}
    pub payload: String,
    /// 毫秒时间戳
    pub created_at: i64,
}

impl From<notification_log_api::NotificationLogRow> for NotificationLogRow {
    fn from(r: notification_log_api::NotificationLogRow) -> Self {
        Self {
            id: r.id,
            kind: r.kind,
            task_id: r.task_id,
            task_title: r.task_title,
            reminder_id: r.reminder_id,
            payload: r.payload,
            created_at: r.created_at,
        }
    }
}

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

// ── FRB 导出 ──

/// 查询通知历史（created_at 倒序；kind 可选过滤；limit 默认 50 上限 200）
pub async fn notification_log_list(
    kind: Option<String>,
    limit: Option<i64>,
) -> Result<Vec<NotificationLogRow>, String> {
    let pool = pool()?;
    notification_log_api::list_notification_log(&pool, kind, limit)
        .await
        .map_err(|e| format!("[notification-log] {e}"))
        .map(|rows| rows.into_iter().map(NotificationLogRow::from).collect())
}

/// 清空通知历史，返回删除行数
pub async fn notification_log_clear() -> Result<u64, String> {
    let pool = pool()?;
    notification_log_api::clear_notification_log(&pool)
        .await
        .map_err(|e| format!("[notification-log] {e}"))
}
