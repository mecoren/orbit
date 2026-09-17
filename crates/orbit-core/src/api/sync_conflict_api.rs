//! sync_conflict_api — 冲突败方副本的留档、查看与恢复
//!
//! ## 背景（03 文档 §八 遗留项兑现）
//! LWW 裁决只会留下一个「冲突数」，败方的字段被静默覆盖丢弃：用户既看不到
//! 被覆盖的内容，也无法把它找回来。本模块把败方**整行字段快照**留档到本地表
//! `sync_conflicts`，并提供「查看 / 恢复 / 忽略 / 清空」四个动作。
//!
//! ## 留档判据（由 merge 侧决定，本模块只负责落库）
//! 只留档**真并发冲突**：本地记录与远端记录的时间戳都晚于「上次同步成功时的
//! 逻辑时钟」（`SyncState.last_synced_clock_ms`）。他端正常顺延更新（本地自上次
//! 同步后没动过）不算冲突，避免把每次跨端同步都灌成一条冲突记录。
//! 从未成功同步过（基线 0）时不留档——两端各自独立的数据集合不是冲突。
//!
//! ## 恢复语义
//! 恢复 = 拿败方内容**发起一次新的本地写入**（复用逻辑时钟取新时间戳 +
//! `version + 1`），因此恢复后的版本会赢得下一轮同步，不会被立即覆盖回去。
//! 恢复只还原**内容字段**，不还原生命周期（`is_deleted` / `deleted_at` /
//! `created_at` 保持原行现状），也绝不改动 `uuid`。
//!
//! ## 本表不进同步 / 备份白名单
//! 各端各自记录各自的裁决现场，跨端混看无意义（口径同 `notification_log`）。

use sqlx::SqlitePool;

use crate::db::repository::generic_repo::{push_json_value, validate_column_name};
use crate::db::repository::import_type_validator::{load_table_columns_in_tx, normalize_value};
use crate::db::sync_registry::SYNCABLE_TABLES;
use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};

/// `sync_conflicts` 行（含 `loser_payload` / `winner_payload` JSON 字符串）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, sqlx::FromRow)]
pub struct SyncConflict {
    pub id: i64,
    pub table_name: String,
    pub record_uuid: String,
    pub record_title: String,
    pub decision: String,
    pub loser_side: String,
    pub winner_side: String,
    pub loser_payload: String,
    pub winner_payload: String,
    pub loser_updated_at: i64,
    pub winner_updated_at: i64,
    pub resolution: String,
    pub created_at: i64,
    pub resolved_at: i64,
}

/// 留档容量上限（超出后丢弃最旧记录，防本地表无界增长）
///
/// 冲突本身是低频事件，500 条足够覆盖「回溯最近一段时间被覆盖成什么样」；
/// 需要长期留存的场景应由用户主动「忽略/清空」而不是无限堆积。
pub const MAX_CONFLICT_ROWS: i64 = 500;

/// merge 侧构造的冲突快照（`pub` 供 cloud_sync::merge 使用）
#[derive(Debug, Clone)]
pub struct ConflictSnapshot {
    pub table_name: String,
    pub record_uuid: String,
    pub record_title: String,
    /// `lww` 时间戳裁决 / `tie_version` 同毫秒按 version 裁决
    pub decision: String,
    pub loser_side: String,
    pub winner_side: String,
    pub loser_payload: String,
    pub winner_payload: String,
    pub loser_updated_at: i64,
    pub winner_updated_at: i64,
}

/// 恢复时跳过的字段
///
/// - `id`/`uuid`：主键与同步标识不可回放；
/// - `is_deleted`/`deleted_at`：恢复的是内容而非生命周期（回收站状态保持现状）；
/// - `created_at`：创建时间不可被覆盖；
/// - `updated_at`/`version`：由本次恢复写入重新取逻辑时钟与自增。
const RESTORE_SKIP_COLUMNS: &[&str] = &[
    "id",
    "uuid",
    "is_deleted",
    "deleted_at",
    "created_at",
    "updated_at",
    "version",
    "_table",
];

/// 从整行 JSON 里取一个可读标题（不同表标题列不同：title / name / content）
pub fn record_title_of(obj: &serde_json::Map<String, serde_json::Value>) -> String {
    for key in ["title", "name", "content"] {
        let v = obj
            .get(key)
            .and_then(|v| v.as_str())
            .filter(|v| !v.trim().is_empty());
        if let Some(v) = v {
            return v.chars().take(80).collect();
        }
    }
    String::new()
}

/// 构造整行快照 JSON 字符串（排除 `id` 与 `_table` 路由字段）
pub fn payload_json_of(obj: &serde_json::Map<String, serde_json::Value>) -> String {
    let mut map = obj.clone();
    map.remove("id");
    map.remove("_table");
    serde_json::to_string(&serde_json::Value::Object(map)).unwrap_or_else(|_| "{}".to_string())
}

/// 在同一事务内留档一条冲突副本（与合并结果原子；失败不阻断合并，仅记日志）
pub async fn insert_conflict_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    snapshot: &ConflictSnapshot,
) -> Result<(), sqlx::Error> {
    let now = crate::db::clock::next_ms();
    sqlx::query(
        "INSERT INTO sync_conflicts (
            table_name, record_uuid, record_title, decision, loser_side, winner_side,
            loser_payload, winner_payload, loser_updated_at, winner_updated_at,
            resolution, created_at, resolved_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'unresolved', ?, 0)",
    )
    .bind(&snapshot.table_name)
    .bind(&snapshot.record_uuid)
    .bind(&snapshot.record_title)
    .bind(&snapshot.decision)
    .bind(&snapshot.loser_side)
    .bind(&snapshot.winner_side)
    .bind(&snapshot.loser_payload)
    .bind(&snapshot.winner_payload)
    .bind(snapshot.loser_updated_at)
    .bind(snapshot.winner_updated_at)
    .bind(now)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// 裁剪超限的最旧记录（同一事务内调用，保证留档上限）
pub async fn prune_in_tx(tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>) -> Result<(), sqlx::Error> {
    sqlx::query(
        "DELETE FROM sync_conflicts WHERE id NOT IN (
            SELECT id FROM sync_conflicts ORDER BY created_at DESC, id DESC LIMIT ?
        )",
    )
    .bind(MAX_CONFLICT_ROWS)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// 列出冲突记录（`resolution` 为 None 时不过滤；按时间倒序）
pub async fn list_conflicts(
    pool: &SqlitePool,
    resolution: Option<String>,
    limit: i64,
    offset: i64,
) -> CoreResult<Vec<SyncConflict>> {
    let limit = limit.clamp(1, 500);
    let offset = offset.max(0);
    let rows: Vec<SyncConflict> =
        match resolution {
            Some(r) => {
                sqlx::query_as(
                    "SELECT * FROM sync_conflicts WHERE resolution = ?
                 ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
                )
                .bind(r)
                .bind(limit)
                .bind(offset)
                .fetch_all(pool)
                .await?
            }
            None => sqlx::query_as(
                "SELECT * FROM sync_conflicts ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
            )
            .bind(limit)
            .bind(offset)
            .fetch_all(pool)
            .await?,
        };
    Ok(rows)
}

/// 统计冲突记录数（`resolution` 为 None 时统计全部）——设置页角标用
pub async fn count_conflicts(pool: &SqlitePool, resolution: Option<String>) -> CoreResult<i64> {
    let count: i64 = match resolution {
        Some(r) => {
            sqlx::query_scalar("SELECT COUNT(*) FROM sync_conflicts WHERE resolution = ?")
                .bind(r)
                .fetch_one(pool)
                .await?
        }
        None => {
            sqlx::query_scalar("SELECT COUNT(*) FROM sync_conflicts")
                .fetch_one(pool)
                .await?
        }
    };
    Ok(count)
}

/// 恢复某条冲突的败方内容（发起一次新的本地写入，返回被写回的原行 id）
pub async fn restore_conflict(pool: &SqlitePool, id: i64) -> CoreResult<i64> {
    let mut tx = pool.begin().await?;

    let conflict: Option<SyncConflict> =
        sqlx::query_as("SELECT * FROM sync_conflicts WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    let conflict = conflict.ok_or_else(|| CoreError::NotFound(format!("sync_conflict id={id}")))?;

    let table = conflict.table_name.clone();
    if !SYNCABLE_TABLES.contains(&table.as_str()) {
        return Err(CoreError::Other(format!(
            "冲突副本指向非同步白名单表 `{table}`，拒绝写入"
        )));
    }

    let parsed: serde_json::Value = serde_json::from_str(&conflict.loser_payload)
        .map_err(|e| CoreError::Other(format!("败方副本载荷解析失败: {e}")))?;
    let obj = parsed
        .as_object()
        .ok_or_else(|| CoreError::Other("败方副本载荷不是 JSON 对象".to_string()))?;

    let columns = load_table_columns_in_tx(&mut tx, &table).await?;
    let now = crate::db::clock::next_ms();

    // 定位原行：含回收站行（恢复内容而非生命周期，故不带 is_deleted 谓词）
    let existing: Option<(i64, String)> = sqlx::query_as(&format!(
        "SELECT id, uuid FROM \"{table}\" WHERE uuid = ? LIMIT 1"
    ))
    .bind(&conflict.record_uuid)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((record_id, record_uuid)) = existing else {
        return Err(CoreError::NotFound(format!(
            "原记录已不存在（表 {table} / uuid={}），无法恢复",
            conflict.record_uuid
        )));
    };

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> =
        sqlx::QueryBuilder::new(format!("UPDATE \"{table}\" SET "));
    q.push("updated_at = ");
    q.push_bind(now);
    q.push(", version = version + 1");
    for (key, val) in obj {
        if RESTORE_SKIP_COLUMNS.contains(&key.as_str()) {
            continue;
        }
        validate_column_name(key)?;
        let Some(meta) = columns.get(key) else {
            continue;
        };
        let normalized = normalize_value(val, meta).map_err(CoreError::Other)?;
        q.push(", ");
        q.push(key);
        q.push(" = ");
        push_json_value(&mut q, &normalized);
    }
    q.push(" WHERE uuid = ");
    q.push_bind(conflict.record_uuid.clone());
    q.build().execute(&mut *tx).await?;

    sqlx::query("UPDATE sync_conflicts SET resolution = 'restored', resolved_at = ? WHERE id = ?")
        .bind(now)
        .bind(id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    EVENT_BUS.emit(DbEvent {
        table,
        op: DbOp::Update,
        record_id,
        record_uuid,
        payload: None,
        device_id: crate::db::repository::generic_repo::current_device_id(),
        timestamp: now,
    });

    Ok(record_id)
}

/// 忽略某条冲突（不改业务数据，仅标记已处置）
pub async fn dismiss_conflict(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let now = crate::db::clock::next_ms();
    let affected = sqlx::query(
        "UPDATE sync_conflicts SET resolution = 'dismissed', resolved_at = ?
         WHERE id = ? AND resolution = 'unresolved'",
    )
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?
    .rows_affected();
    if affected == 0 {
        return Err(CoreError::NotFound(format!(
            "sync_conflict id={id} 不存在或已处置"
        )));
    }
    Ok(())
}

/// 清空冲突记录（`resolution` 为 None 时清全部），返回删除条数
pub async fn clear_conflicts(pool: &SqlitePool, resolution: Option<String>) -> CoreResult<u64> {
    let affected = match resolution {
        Some(r) => {
            sqlx::query("DELETE FROM sync_conflicts WHERE resolution = ?")
                .bind(r)
                .execute(pool)
                .await?
        }
        None => {
            sqlx::query("DELETE FROM sync_conflicts")
                .execute(pool)
                .await?
        }
    };
    Ok(affected.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::Row;

    async fn setup() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    /// `loser_side=local` 的样本：本地被远端覆盖，副本内容是本地旧值
    fn snapshot_local_lost() -> ConflictSnapshot {
        ConflictSnapshot {
            table_name: "todo_projects".to_string(),
            record_uuid: "p-1".to_string(),
            record_title: "本地标题".to_string(),
            decision: "lww".to_string(),
            loser_side: "local".to_string(),
            winner_side: "remote".to_string(),
            loser_payload: serde_json::json!({"title": "本地标题", "hex_color": "#111111"})
                .to_string(),
            winner_payload: serde_json::json!({"title": "远端标题", "hex_color": "#222222"})
                .to_string(),
            loser_updated_at: 100,
            winner_updated_at: 200,
        }
    }

    #[tokio::test]
    async fn insert_list_count_roundtrip() {
        let pool = setup().await;
        let mut tx = pool.begin().await.unwrap();
        insert_conflict_in_tx(&mut tx, &snapshot_local_lost())
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let rows = list_conflicts(&pool, Some("unresolved".to_string()), 10, 0)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].table_name, "todo_projects");
        assert_eq!(rows[0].loser_side, "local");
        assert_eq!(
            count_conflicts(&pool, Some("unresolved".to_string()))
                .await
                .unwrap(),
            1
        );
        assert_eq!(count_conflicts(&pool, None).await.unwrap(), 1);
    }

    #[tokio::test]
    async fn prune_keeps_newest_rows() {
        let pool = setup().await;
        let mut tx = pool.begin().await.unwrap();
        for i in 0..(MAX_CONFLICT_ROWS + 10) {
            let mut s = snapshot_local_lost();
            s.record_uuid = format!("p-{i}");
            insert_conflict_in_tx(&mut tx, &s).await.unwrap();
        }
        prune_in_tx(&mut tx).await.unwrap();
        tx.commit().await.unwrap();

        let total = count_conflicts(&pool, None).await.unwrap();
        assert_eq!(total, MAX_CONFLICT_ROWS, "留档必须有上限");
    }

    #[tokio::test]
    async fn dismiss_then_clear() {
        let pool = setup().await;
        let mut tx = pool.begin().await.unwrap();
        insert_conflict_in_tx(&mut tx, &snapshot_local_lost())
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let id = list_conflicts(&pool, None, 10, 0).await.unwrap()[0].id;

        dismiss_conflict(&pool, id).await.unwrap();
        assert_eq!(
            count_conflicts(&pool, Some("dismissed".to_string()))
                .await
                .unwrap(),
            1
        );
        // 重复处置报错（幂等保护）
        assert!(dismiss_conflict(&pool, id).await.is_err());

        assert_eq!(
            clear_conflicts(&pool, Some("dismissed".to_string()))
                .await
                .unwrap(),
            1
        );
        assert_eq!(count_conflicts(&pool, None).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn restore_writes_loser_content_back() {
        let pool = setup().await;
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, hex_color, description, is_deleted, created_at, updated_at, version)
             VALUES ('p-1', '远端标题', '#222222', NULL, 0, 1, 200, 3)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let mut tx = pool.begin().await.unwrap();
        insert_conflict_in_tx(&mut tx, &snapshot_local_lost())
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let id = list_conflicts(&pool, None, 10, 0).await.unwrap()[0].id;

        let record_id = restore_conflict(&pool, id).await.unwrap();
        assert!(record_id > 0);

        let (title, color, version, updated_at): (String, String, i64, i64) = sqlx::query_as(
            "SELECT title, hex_color, version, updated_at FROM todo_projects WHERE uuid = 'p-1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(title, "本地标题", "败方内容必须被写回");
        assert_eq!(color, "#111111");
        assert_eq!(version, 4, "恢复是一次新的本地写入（version + 1）");
        assert!(updated_at > 200, "恢复必须取新的逻辑时钟时间戳");

        // 已处置，不再出现在待处理列表
        assert_eq!(
            count_conflicts(&pool, Some("unresolved".to_string()))
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            count_conflicts(&pool, Some("restored".to_string()))
                .await
                .unwrap(),
            1
        );
    }

    #[tokio::test]
    async fn restore_keeps_lifecycle_columns() {
        let pool = setup().await;
        // 原行进回收站且 updated_at 远晚于副本内容
        sqlx::query(
            "INSERT INTO todo_projects (uuid, title, is_deleted, deleted_at, created_at, updated_at, version)
             VALUES ('p-1', '墓碑标题', 1, 999, 1, 999, 7)",
        )
        .execute(&pool)
        .await
        .unwrap();
        let mut tx = pool.begin().await.unwrap();
        insert_conflict_in_tx(&mut tx, &snapshot_local_lost())
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let id = list_conflicts(&pool, None, 10, 0).await.unwrap()[0].id;

        restore_conflict(&pool, id).await.unwrap();

        let row = sqlx::query(
            "SELECT title, is_deleted, deleted_at, created_at FROM todo_projects WHERE uuid = 'p-1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(row.get::<String, _>("title"), "本地标题");
        assert_eq!(
            row.get::<i64, _>("is_deleted"),
            1,
            "恢复只还原内容，不把回收站行复活"
        );
        assert_eq!(row.get::<Option<i64>, _>("deleted_at"), Some(999));
        assert_eq!(row.get::<i64, _>("created_at"), 1, "created_at 不可被覆盖");
    }

    #[tokio::test]
    async fn restore_rejects_missing_record_and_unknown_table() {
        let pool = setup().await;
        let mut tx = pool.begin().await.unwrap();
        insert_conflict_in_tx(&mut tx, &snapshot_local_lost())
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let id = list_conflicts(&pool, None, 10, 0).await.unwrap()[0].id;

        // 原行不存在 → 报错（不静默成功）
        assert!(restore_conflict(&pool, id).await.is_err());

        // 非白名单表 → 拒绝
        sqlx::query(
            "INSERT INTO sync_conflicts (table_name, record_uuid, loser_payload, resolution)
             VALUES ('sync_configs', 'x', '{\"endpoint\":\"evil\"}', 'unresolved')",
        )
        .execute(&pool)
        .await
        .unwrap();
        let bad = list_conflicts(&pool, Some("unresolved".to_string()), 10, 0)
            .await
            .unwrap()
            .into_iter()
            .find(|c| c.table_name == "sync_configs")
            .unwrap();
        let err = restore_conflict(&pool, bad.id)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("白名单"), "错误信息应指明白名单拒绝: {err}");
    }

    #[test]
    fn title_and_payload_helpers() {
        let obj = serde_json::json!({"id": 3, "uuid": "u", "title": "  ", "name": "模板名"});
        let map = obj.as_object().unwrap().clone();
        assert_eq!(record_title_of(&map), "模板名", "空标题回落到 name");
        let payload = payload_json_of(&map);
        assert!(!payload.contains("\"id\""), "快照不含主键 id");
        assert!(payload.contains("\"uuid\""), "快照保留 uuid（恢复定位用）");
    }
}
