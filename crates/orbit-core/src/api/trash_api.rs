//! trash_api — 回收站（用户需求：删除的任务进回收站，保留时间可配，可恢复）
//!
//! 数据层基础：删除 = 软删墓碑行（`generic_repo::soft_delete_by_id` 写
//! `is_deleted=1, deleted_at=now`），本模块把这些行暴露为回收站：
//! - 列表（`deleted_at` 降序，最近删的排最前）
//! - 恢复（翻转 is_deleted + updated_at 提升 + version+1）：
//!   云同步 pull 端已有「复活裁决」（merge.rs：远端 updated_at ≥ 本地
//!   deleted_at 才复活），恢复后正常 push 存活行即可跨设备传播，同步层零改动；
//!   恢复时若原项目已软删则置 project_id=NULL（落入未分组，避免悬空引用）。
//! - 彻底删除 / 清空（物理 DELETE；用户明确意图，无同步守卫——写回墓碑没意义，
//!   其他端本地若仍保留该墓碑，最终状态一致为「已删」）。
//! - TTL 自动清理：按保留天数清「已同步出去的」过期墓碑（守卫见 [purge_todo_tasks_before]）。
//!
//! ## 保留时间设置
//! 存 `cfg_kv`（key `trash_retention_days`；档位 7/30/90/永久=0，默认 30，对标
//! Todoist/微软 To Do）。cfg_kv 是本地 KV 表（migration 0003），不在
//! SYNCABLE_TABLES 同步白名单——保留时间是本机偏好，各端各自设置（与
//! holiday_fixed_hour 同边界）。
//!
//! ## TTL 清理与墓碑同步协议的冲突守卫（ADR 见 docs/adr/0005）
//! 墓碑行是云同步「删除」语义的唯一载体。若把尚未 push 到云端的墓碑物理清掉，
//! 云端仍留有该 uuid 的旧存活数据，其他设备（及本端重配同步）pull 时会 INSERT
//! 复活该任务。守卫口径：启用云同步（激活配置存在）时，TTL 只清
//! `deleted_at < last_pushed_at`（sync_configs.last_synced_at，成功 push/sync
//! 后记账）的墓碑——早于该时间点的删除已上传云端。未启用云同步时无守卫直接清
//! （没有其他设备可复活；云端也无数据）。**恢复与手动彻底删除不受守卫约束**。

use serde::Serialize;
use sqlx::SqlitePool;

use crate::db::repository::generic_repo;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::TodoTask;

// ============================================================================
// 常量与配置
// ============================================================================

/// cfg_kv 键：回收站保留天数
const KV_RETENTION_DAYS: &str = "trash_retention_days";

/// cfg_kv 键：上次 TTL 清理执行时间（ms）——每日最多清一次的记账
const KV_LAST_PURGE_MS: &str = "trash_last_purge_ms";

/// 默认保留天数（对标 Todoist / 微软 To Do 的 30 天）
pub const DEFAULT_RETENTION_DAYS: i64 = 30;

/// 合法保留档位（天）。0 = 永久保留（不自动清理）
pub const RETENTION_CHOICES: &[i64] = &[0, 7, 30, 90];

/// 天 → 毫秒
const DAY_MS: i64 = 86_400_000;

/// 回收站元数据（UI 消费：保留档位 + 上次自动清理时间）
#[derive(Debug, Clone, Serialize)]
pub struct TrashMeta {
    /// 保留天数（0 = 永久；缺省 30）
    pub retention_days: i64,
    /// 上次 TTL 自动清理时间（ms；0 = 从未执行）
    pub last_purge_ms: i64,
}

/// TTL 执行结果（两端 tick 守护与 UI 提示共用）
#[derive(Debug, Clone, Serialize, Default)]
pub struct PurgeStats {
    /// 物理删除的墓碑行数
    pub purged: u64,
    /// 因同步守卫跳过的行数（deleted_at ≥ last_pushed_at）
    pub guarded: u64,
    /// 本次是否执行了清理（retention=0 / 当日已清 / 无过期 → false）
    pub ran: bool,
}

// ============================================================================
// cfg_kv 读写（holiday_api 同款口径，提炼为本模块公共工具）
// ============================================================================

async fn kv_get_i64(pool: &SqlitePool, key: &str) -> CoreResult<Option<i64>> {
    let row: Option<(String,)> = sqlx::query_as("SELECT value FROM cfg_kv WHERE key = ?1")
        .bind(key)
        .fetch_optional(pool)
        .await?;
    Ok(row.and_then(|(v,)| v.parse().ok()))
}

async fn kv_set_i64(pool: &SqlitePool, key: &str, value: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        "INSERT INTO cfg_kv (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
    )
    .bind(key)
    .bind(value.to_string())
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

// ============================================================================
// 保留档位读写
// ============================================================================

/// 读取保留天数（非法/缺省值回落 DEFAULT_RETENTION_DAYS）
pub async fn get_trash_retention_days(pool: &SqlitePool) -> CoreResult<i64> {
    let raw = kv_get_i64(pool, KV_RETENTION_DAYS).await?;
    Ok(match raw {
        Some(days) if RETENTION_CHOICES.contains(&days) => days,
        _ => DEFAULT_RETENTION_DAYS,
    })
}

/// 设置保留天数（仅接受合法档位：7/30/90/0=永久）
pub async fn set_trash_retention_days(pool: &SqlitePool, days: i64) -> CoreResult<()> {
    if !RETENTION_CHOICES.contains(&days) {
        return Err(CoreError::Other(format!(
            "非法保留天数 {days}，合法档位：{RETENTION_CHOICES:?}（0 = 永久）"
        )));
    }
    kv_set_i64(pool, KV_RETENTION_DAYS, days).await
}

/// 回收站元数据（设置页展示 + 调度判定共用）
pub async fn trash_meta(pool: &SqlitePool) -> CoreResult<TrashMeta> {
    Ok(TrashMeta {
        retention_days: get_trash_retention_days(pool).await?,
        last_purge_ms: kv_get_i64(pool, KV_LAST_PURGE_MS).await?.unwrap_or(0),
    })
}

// ============================================================================
// 列表 / 恢复 / 彻底删除
// ============================================================================

/// 列出回收站任务（is_deleted=1 且 deleted_at 非空，最近删除的排最前）
///
/// 前端在行上展示「原项目名」（本表有 project_id，名字由端侧自行 JOIN 展示层
/// 项目列表；墓碑项目在正常列表不可见，恢复时会被置 NULL 落入未分组）。
pub async fn list_trashed_tasks(pool: &SqlitePool) -> CoreResult<Vec<TodoTask>> {
    let items = sqlx::query_as::<_, TodoTask>(
        "SELECT * FROM todo_tasks \
         WHERE is_deleted = 1 AND deleted_at IS NOT NULL \
         ORDER BY deleted_at DESC, id DESC",
    )
    .fetch_all(pool)
    .await?;
    Ok(items)
}

/// 恢复任务：翻转墓碑行回存活态
///
/// - 前置校验：行存在且 is_deleted=1（已在回收站），否则报错（正常列表里的任务
///   不该走到这里）；
/// - 原项目已软删 → project_id 置 NULL（落入「未分组」）；原项目存活 → 保留；
/// - `updated_at` 提升为当前时间 + `version+1` + emit Update 事件（DbOp::Update
///   让两端列表缓存失效）。云同步侧：push 存活行后，对端 pull 的复活裁决
///   （远端 updated_at ≥ 本地 deleted_at）自动传播恢复。
pub async fn restore_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<TodoTask> {
    let t: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    if t.is_deleted != 1 {
        return Err(CoreError::Other(format!(
            "任务 id={id} 不在回收站（is_deleted=0），无需恢复"
        )));
    }

    // 原项目已软删 → 恢复时落入未分组（避免指向不可见项目的悬空引用）
    let project_alive: Option<(i64,)> = match t.project_id {
        Some(pid) => {
            sqlx::query_as::<_, (i64,)>(
                "SELECT id FROM todo_projects WHERE id = ? AND is_deleted = 0",
            )
            .bind(pid)
            .fetch_optional(pool)
            .await?
        }
        None => None,
    };
    let project_id = if t.project_id.is_some() && project_alive.is_none() {
        None
    } else {
        t.project_id
    };

    let now = crate::db::clock::next_ms();
    let restored: TodoTask = sqlx::query_as(
        "UPDATE todo_tasks \
         SET is_deleted = 0, deleted_at = NULL, project_id = ?, \
             updated_at = ?, version = version + 1 \
         WHERE id = ? AND is_deleted = 1 \
         RETURNING *",
    )
    .bind(project_id)
    .bind(now)
    .bind(id)
    .fetch_one(pool)
    .await?;

    let payload = serde_json::to_value(&restored).ok();
    EVENT_BUS.emit(DbEvent {
        table: "todo_tasks".into(),
        op: DbOp::Update,
        record_id: restored.id,
        record_uuid: restored.uuid.clone(),
        payload,
        device_id: generic_repo::current_device_id(),
        timestamp: now,
    });
    // 活动日志（F6）：回收站恢复是显式动作，独立埋点
    let _ = crate::api::activity_log_api::log_activity(
        pool,
        restored.id,
        &restored.title,
        "restore",
        "{}",
    )
    .await;
    Ok(restored)
}

/// 彻底删除单个任务（物理 DELETE，含子任务/标签关联/评论/关系/提醒一并物理清）
///
/// 手动彻底删除是用户明确意图，不受同步守卫约束。事件 emit DbOp::Delete 触发
/// 两端缓存失效；子表随行清理避免残留孤儿行（软删期间它们仅按 task_id 查询）。
pub async fn purge_todo_task(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let t: TodoTask = generic_repo::get_by_id(pool, "todo_tasks", id).await?;
    if t.is_deleted != 1 {
        return Err(CoreError::Other(format!(
            "任务 id={id} 不在回收站，仅可对回收站任务执行彻底删除"
        )));
    }

    let mut tx = pool.begin().await?;
    for sql in [
        "DELETE FROM todo_subtasks WHERE task_id = ?",
        "DELETE FROM todo_task_labels WHERE task_id = ?",
        "DELETE FROM todo_comments WHERE task_id = ?",
        "DELETE FROM todo_task_relations WHERE task_id = ? OR other_task_id = ?",
        "DELETE FROM todo_reminders WHERE task_id = ?",
        "DELETE FROM todo_tasks WHERE id = ?",
    ] {
        sqlx::query(sql).bind(id).bind(id).execute(&mut *tx).await?;
    }
    tx.commit().await?;

    EVENT_BUS.emit(DbEvent::delete(
        "todo_tasks",
        t.id,
        &t.uuid,
        &generic_repo::current_device_id(),
    ));
    Ok(())
}

/// 清空回收站（全部墓碑任务物理删除；含各自的子表行）
///
/// 返回删除的任务数。无墓碑时直接返回 0（不 emit 事件）。
pub async fn purge_all_trashed_tasks(pool: &SqlitePool) -> CoreResult<u64> {
    let trashed: Vec<TodoTask> = list_trashed_tasks(pool).await?;
    if trashed.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    // relations 的两列都指向任务，任一命中即清
    sqlx::query(
        "DELETE FROM todo_task_relations \
         WHERE task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1) \
            OR other_task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
    )
    .execute(&mut *tx)
    .await?;
    for sql in [
        "DELETE FROM todo_subtasks WHERE task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
        "DELETE FROM todo_task_labels WHERE task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
        "DELETE FROM todo_comments WHERE task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
        "DELETE FROM todo_reminders WHERE task_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1)",
        "DELETE FROM todo_tasks WHERE is_deleted = 1",
    ] {
        sqlx::query(sql).execute(&mut *tx).await?;
    }
    tx.commit().await?;

    let device_id = generic_repo::current_device_id();
    for t in &trashed {
        EVENT_BUS.emit(DbEvent::delete("todo_tasks", t.id, &t.uuid, &device_id));
    }
    Ok(trashed.len() as u64)
}

// ============================================================================
// TTL 过期自动清理（两端 tick 守护调用）
// ============================================================================

/// 是否应执行 TTL 清理（每日记账判定的唯一口径，纯函数便于两端复用）
///
/// - `last_purge_ms <= 0`（从未执行）→ 应清理（首次运行 / 番茄钟场景）；
/// - 上次执行在 24h 前 → 应清理；
/// - 其余（24h 内已执行）→ 不清理（每次 tick 重扫全表无意义）。
pub fn should_purge_now(now_ms: i64, last_purge_ms: i64) -> bool {
    last_purge_ms <= 0 || now_ms - last_purge_ms >= DAY_MS
}

/// TTL 清理一次（60s tick 调用；每日最多实际执行一次，见 [should_purge_now]）
///
/// 流程：retention=0（永久）→ 跳过；24h 内已清 → 跳过；
/// 否则清 `deleted_at < now - retention×DAY_MS` 的墓碑任务（连带子表行），
/// 受同步守卫约束（仅清已 push 到云端的删除，见模块头注释），最后记账。
pub async fn maybe_purge_expired(pool: &SqlitePool) -> CoreResult<PurgeStats> {
    let retention = get_trash_retention_days(pool).await?;
    if retention == 0 {
        return Ok(PurgeStats::default());
    }
    let now = chrono::Utc::now().timestamp_millis();
    let last = kv_get_i64(pool, KV_LAST_PURGE_MS).await?.unwrap_or(0);
    if !should_purge_now(now, last) {
        return Ok(PurgeStats::default());
    }

    let cutoff = now - retention * DAY_MS;
    let (purged, guarded) = purge_todo_tasks_before(pool, cutoff).await?;
    kv_set_i64(pool, KV_LAST_PURGE_MS, now).await?;
    Ok(PurgeStats {
        purged,
        guarded,
        ran: true,
    })
}

/// 物理删除 `deleted_at < cutoff` 的墓碑任务（连带子表行），返回 (清理数, 守卫跳过数)
///
/// **同步守卫**：启用云同步（激活配置存在）时仅清 `deleted_at < last_pushed_at`
/// 的行——早于该时间点的删除已上传云端墓碑集；更晚的删除可能尚未 push，
/// 物理清掉会让云端旧存活数据在 pull 时复活该任务。未启用云同步则无守卫
/// （无其他设备可复活）。恢复/手动彻底删除不经此函数，不受守卫约束。
pub async fn purge_todo_tasks_before(pool: &SqlitePool, cutoff_ms: i64) -> CoreResult<(u64, u64)> {
    let now = chrono::Utc::now().timestamp_millis();
    let active: Option<(i64,)> = sqlx::query_as::<_, (i64,)>(
        "SELECT id FROM sync_configs WHERE is_active = 1 AND deleted_at IS NULL LIMIT 1",
    )
    .fetch_optional(pool)
    .await?;
    // 启用云同步才取守卫时间（成功 push/sync 后记账；含 0 兜底见下）
    let last_pushed_at = match active {
        Some((config_id,)) => sqlx::query_as::<_, (Option<i64>,)>(
            "SELECT last_synced_at FROM sync_configs WHERE id = ?",
        )
        .bind(config_id)
        .fetch_optional(pool)
        .await?
        .and_then(|(v,)| v)
        .unwrap_or(0),
        None => 0,
    };

    // 候选：已过期墓碑。守卫并入 SQL：放行条件 deleted_at < last_pushed_at
    // （删除早于上次成功推送 → 云端已确认，物理清安全）；last_pushed_at=0
    // （从未推送）钳到 1 → 任何 deleted_at >= 1 恒被守卫跳过；未启用同步
    // → floor 取 i64::MAX 放行条件恒真。只取 id/uuid 投影，不再整行物化
    // （候选行含 description 大字符串列，批量期开销无谓）
    let guard_floor = match active.is_some() {
        true => last_pushed_at.max(1),
        false => i64::MAX,
    };
    let candidates: Vec<(i64, String)> = sqlx::query_as::<_, (i64, String)>(
        "SELECT id, uuid FROM todo_tasks WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ? AND deleted_at < ?",
    )
    .bind(cutoff_ms)
    .bind(guard_floor)
    .fetch_all(pool)
    .await?;
    if candidates.is_empty() {
        let guarded = if active.is_some() {
            count_guarded(pool, cutoff_ms, last_pushed_at).await?
        } else {
            0
        };
        return Ok((0, guarded));
    }

    // 集合式删除：同一圈定条件一条子查询，6 类行各一条 DELETE（此前逐行
    // 6 条 × N 行 = 百行 600 条语句；同文件 purge_all_trashed_tasks 同款）
    let purge_scope =
        "is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ? AND deleted_at < ?";
    let mut tx = pool.begin().await?;
    for sql in [
        format!(
            "DELETE FROM todo_subtasks WHERE task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope})"
        ),
        format!(
            "DELETE FROM todo_task_labels WHERE task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope})"
        ),
        format!(
            "DELETE FROM todo_comments WHERE task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope})"
        ),
        format!(
            "DELETE FROM todo_task_relations WHERE task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope}) OR other_task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope})"
        ),
        format!(
            "DELETE FROM todo_reminders WHERE task_id IN (SELECT id FROM todo_tasks WHERE {purge_scope})"
        ),
        // 本体最后删（子表子查询依赖它圈定范围）
        format!("DELETE FROM todo_tasks WHERE {purge_scope}"),
    ] {
        // 每条语句两个圈定参数；relations 语句双子查询需 4 个
        let params = if sql.matches('?').count() == 4 { 4 } else { 2 };
        let mut q = sqlx::query(&sql);
        for _ in 0..params / 2 {
            q = q.bind(cutoff_ms).bind(guard_floor);
        }
        q.execute(&mut *tx).await?;
    }
    tx.commit().await?;

    let device_id = generic_repo::current_device_id();
    for (id, uuid) in &candidates {
        EVENT_BUS.emit(DbEvent::delete("todo_tasks", *id, uuid, &device_id));
    }
    let guarded = if active.is_some() {
        count_guarded(pool, cutoff_ms, last_pushed_at).await?
    } else {
        0
    };
    let _ = now; // now 保留给调用方记账（maybe_purge_expired 写 KV_LAST_PURGE_MS）
    Ok((candidates.len() as u64, guarded))
}

/// 守卫计数：cutoff 内但因未确认上云而跳过物理清的墓碑行数
async fn count_guarded(pool: &SqlitePool, cutoff_ms: i64, last_pushed_at: i64) -> CoreResult<u64> {
    let (n,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ? AND deleted_at >= ?",
    )
    .bind(cutoff_ms)
    .bind(last_pushed_at.max(1))
    .fetch_one(pool)
    .await?;
    Ok(n.max(0) as u64)
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::business_api::{create_todo_task, delete_todo_task};
    use crate::models::business::TodoTaskCreateInput;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// 造一个已软删的任务（可选指定 deleted_at）
    async fn seed_trashed(pool: &SqlitePool, title: &str, deleted_at: Option<i64>) -> TodoTask {
        let t = create_todo_task(pool, &input(title)).await.unwrap();
        delete_todo_task(pool, t.id).await.unwrap();
        if let Some(ts) = deleted_at {
            sqlx::query("UPDATE todo_tasks SET deleted_at = ? WHERE id = ?")
                .bind(ts)
                .bind(t.id)
                .execute(pool)
                .await
                .unwrap();
        }
        generic_repo::get_by_id(pool, "todo_tasks", t.id)
            .await
            .unwrap()
    }

    fn input(title: &str) -> TodoTaskCreateInput {
        TodoTaskCreateInput {
            title: title.to_string(),
            description: None,
            project_id: None,
            priority: None,
            status: None,
            done: None,
            done_at: None,
            due_date: None,
            start_date: None,
            repeat_after: None,
            repeat_mode: None,
            repeat_weekdays: None,
            repeat_end_type: None,
            repeat_end_param: None,
            repeat_from_done: None,
            position: None,
            is_favorite: None,
            my_day_date: None,
        }
    }

    #[tokio::test]
    async fn soft_deleted_task_appears_in_trash_and_restores() {
        let pool = setup_db().await;
        create_todo_task(&pool, &input("存活的")).await.unwrap();
        seed_trashed(&pool, "已删除的", None).await;

        let trash = list_trashed_tasks(&pool).await.unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].title, "已删除的");
        assert_eq!(trash[0].is_deleted, 1);
        assert!(trash[0].deleted_at.is_some());

        let restored = restore_todo_task(&pool, trash[0].id).await.unwrap();
        assert_eq!(restored.is_deleted, 0);
        assert!(restored.deleted_at.is_none());
        // 回收站空、正常列表 2 条
        assert!(list_trashed_tasks(&pool).await.unwrap().is_empty());
        let live: Vec<TodoTask> =
            sqlx::query_as("SELECT * FROM todo_tasks WHERE is_deleted = 0 ORDER BY id")
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(live.len(), 2);
    }

    #[tokio::test]
    async fn restore_rejects_live_task() {
        let pool = setup_db().await;
        let t = create_todo_task(&pool, &input("活的")).await.unwrap();
        assert!(restore_todo_task(&pool, t.id).await.is_err());
    }

    #[tokio::test]
    async fn restore_falls_back_to_ungrouped_when_project_deleted() {
        let pool = setup_db().await;
        let t = create_todo_task(&pool, &input("带项目")).await.unwrap();
        delete_todo_task(&pool, t.id).await.unwrap();
        // 项目连带软删（复刻 project 软删）
        sqlx::query("UPDATE todo_projects SET is_deleted = 1, deleted_at = 1")
            .execute(&pool)
            .await
            .unwrap();

        let restored = restore_todo_task(&pool, t.id).await.unwrap();
        assert_eq!(restored.is_deleted, 0);
        assert_eq!(restored.project_id, None, "原项目已删，应落入未分组");
    }

    #[tokio::test]
    async fn purge_single_removes_row_and_children_completely() {
        let pool = setup_db().await;
        let trashed = seed_trashed(&pool, "带子行", None).await;
        sqlx::query(
            "INSERT INTO todo_subtasks (uuid, task_id, title) VALUES ('u-sub', ?, '子任务')",
        )
        .bind(trashed.id)
        .execute(&pool)
        .await
        .unwrap();

        purge_todo_task(&pool, trashed.id).await.unwrap();
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE id = ?")
            .bind(trashed.id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(n, 0, "物理删除后连墓碑行也不存在");
        let (sub,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM todo_subtasks WHERE task_id = ?")
            .bind(trashed.id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(sub, 0, "子任务行应一并清除");
        // 不在回收站的任务不可彻底删除
        let live = create_todo_task(&pool, &input("活的")).await.unwrap();
        assert!(purge_todo_task(&pool, live.id).await.is_err());
    }

    #[tokio::test]
    async fn purge_all_clears_every_trashed_task() {
        let pool = setup_db().await;
        seed_trashed(&pool, "旧1", Some(100)).await;
        seed_trashed(&pool, "旧2", Some(200)).await;
        create_todo_task(&pool, &input("存活")).await.unwrap();

        let n = purge_all_trashed_tasks(&pool).await.unwrap();
        assert_eq!(n, 2);
        assert!(list_trashed_tasks(&pool).await.unwrap().is_empty());
        let (live,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM todo_tasks WHERE is_deleted = 0")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(live, 1);
    }

    #[tokio::test]
    async fn retention_roundtrip_and_rejects_invalid() {
        let pool = setup_db().await;
        assert_eq!(get_trash_retention_days(&pool).await.unwrap(), 30);
        set_trash_retention_days(&pool, 7).await.unwrap();
        assert_eq!(get_trash_retention_days(&pool).await.unwrap(), 7);
        set_trash_retention_days(&pool, 0).await.unwrap(); // 永久
        assert_eq!(get_trash_retention_days(&pool).await.unwrap(), 0);
        assert!(set_trash_retention_days(&pool, 15).await.is_err());
        assert!(set_trash_retention_days(&pool, -1).await.is_err());
        // 非法存量值回落默认
        sqlx::query("UPDATE cfg_kv SET value = '42' WHERE key = 'trash_retention_days'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(get_trash_retention_days(&pool).await.unwrap(), 30);
    }

    #[tokio::test]
    async fn should_purge_now_daily_gate() {
        // 用真实毫秒时间戳量级（now 若小于 DAY_MS 会让 last 变负数，误触 <=0 分支）
        let now = 1_800_000_000_000i64;
        assert!(should_purge_now(now, 0)); // 从未执行
        assert!(!should_purge_now(now, now - 1000)); // 1s 前执行过
        assert!(should_purge_now(now, now - DAY_MS)); // 恰好 24h 前
        assert!(!should_purge_now(now, now - DAY_MS + 1)); // 还差 1ms 满 24h
    }

    #[tokio::test]
    async fn ttl_purges_expired_tasks_and_records_daily() {
        let pool = setup_db().await;
        set_trash_retention_days(&pool, 7).await.unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        seed_trashed(&pool, "8天前删", Some(now - 8 * DAY_MS)).await;
        seed_trashed(&pool, "昨天删", Some(now - DAY_MS)).await;
        create_todo_task(&pool, &input("存活")).await.unwrap();

        let stats = maybe_purge_expired(&pool).await.unwrap();
        assert!(stats.ran);
        assert_eq!(stats.purged, 1, "仅 8 天前删的被清，昨天的还在保留期");
        assert_eq!(stats.guarded, 0, "未启用云同步 → 无守卫");
        let trash = list_trashed_tasks(&pool).await.unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].title, "昨天删");

        // 24h 内重复调用不再执行
        let again = maybe_purge_expired(&pool).await.unwrap();
        assert!(!again.ran);
    }

    #[tokio::test]
    async fn ttl_forever_retention_never_purges() {
        let pool = setup_db().await;
        set_trash_retention_days(&pool, 0).await.unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        seed_trashed(&pool, "一年前删", Some(now - 365 * DAY_MS)).await;

        let stats = maybe_purge_expired(&pool).await.unwrap();
        assert!(!stats.ran);
        assert_eq!(list_trashed_tasks(&pool).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn ttl_guard_holds_unpushed_tombstones_when_sync_enabled() {
        let pool = setup_db().await;
        set_trash_retention_days(&pool, 7).await.unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        seed_trashed(&pool, "过期+已推送", Some(now - 10 * DAY_MS)).await;
        seed_trashed(&pool, "过期+未推送", Some(now - 9 * DAY_MS)).await;

        // 启用云同步，最近成功 push 在 9.5 天前：
        // 「过期+已推送」(10天前删) 早于守卫线 → 可清；
        // 「过期+未推送」(9天前删) 晚于守卫线 → 保留待下次 push 后再清
        sqlx::query(
            "INSERT INTO sync_configs (protocol, endpoint, bucket, region, path, device_id, \
             credential, is_active, last_synced_at, created_at, updated_at) \
             VALUES ('s3', 'http://x', '', '', '', 'dev', '', 1, ?, 1, 1)",
        )
        .bind(now - (9 * DAY_MS + DAY_MS / 2))
        .execute(&pool)
        .await
        .unwrap();

        let stats = maybe_purge_expired(&pool).await.unwrap();
        assert!(stats.ran);
        assert_eq!(stats.purged, 1);
        assert_eq!(stats.guarded, 1);
        let trash = list_trashed_tasks(&pool).await.unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].title, "过期+未推送");
    }

    #[tokio::test]
    async fn ttl_guard_holds_all_when_sync_enabled_but_never_pushed() {
        let pool = setup_db().await;
        set_trash_retention_days(&pool, 7).await.unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        seed_trashed(&pool, "过期", Some(now - 30 * DAY_MS)).await;
        sqlx::query(
            "INSERT INTO sync_configs (protocol, endpoint, bucket, region, path, device_id, \
             credential, is_active, last_synced_at, created_at, updated_at) \
             VALUES ('s3', 'http://x', '', '', '', 'dev', '', 1, 0, 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let stats = maybe_purge_expired(&pool).await.unwrap();
        assert!(stats.ran);
        assert_eq!(stats.purged, 0, "从未成功 push → 全部守卫跳过");
        assert_eq!(stats.guarded, 1);
    }

    #[tokio::test]
    async fn trash_meta_reports_retention_and_last_purge() {
        let pool = setup_db().await;
        set_trash_retention_days(&pool, 90).await.unwrap();
        let meta = trash_meta(&pool).await.unwrap();
        assert_eq!(meta.retention_days, 90);
        assert_eq!(meta.last_purge_ms, 0);
    }
}
