//! saved_filter_api — 保存的筛选器（07 竞品矩阵批次 #35）
//!
//! 对标 Apple Smart List / Tasks.org 可保存过滤器 / Obsidian Presets：
//! 用户把常用组合条件（状态/优先级下限/项目集/标签集/截止窗口/收藏）存为
//! 命名视图，侧栏直达。条件为 JSON 文本，查询侧按存在键过滤（缺键 = 不过滤），
//! 不做服务端表达式解析——简单、可同步、跨端语义稳定。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::{
    TodoSavedFilter, TodoSavedFilterCreateInput, TodoSavedFilterUpdateInput,
};

/// 条件 JSON 的合法键（校验用；防存进任意 JSON）
const ALLOWED_CONDITION_KEYS: &[&str] = &[
    "status",
    "priority_min",
    "project_ids",
    "label_ids",
    "due_within_days",
    "due_overdue",
    "favorite_only",
];

/// 校验条件 JSON：必须是对象且键都在白名单内（防任意 JSON 进库）
fn validate_conditions(conditions: &str) -> CoreResult<()> {
    let parsed: serde_json::Value = serde_json::from_str(conditions)
        .map_err(|e| CoreError::Other(format!("筛选条件不是合法 JSON: {}", e)))?;
    let Some(obj) = parsed.as_object() else {
        return Err(CoreError::Other("筛选条件必须是 JSON 对象".into()));
    };
    for key in obj.keys() {
        if !ALLOWED_CONDITION_KEYS.contains(&key.as_str()) {
            return Err(CoreError::Other(format!(
                "筛选条件含未知键 `{}`（允许: {:?}）",
                key, ALLOWED_CONDITION_KEYS
            )));
        }
    }
    Ok(())
}

fn emit(table: &str, id: i64, uuid: &str, op: DbOp, timestamp: i64) {
    EVENT_BUS.emit(DbEvent {
        table: table.into(),
        op,
        record_id: id,
        record_uuid: uuid.to_string(),
        payload: None,
        device_id: String::new(),
        timestamp,
    });
}

/// 列出全部保存的筛选器（sort_order 升序）
pub async fn list_saved_filters(pool: &SqlitePool) -> CoreResult<Vec<TodoSavedFilter>> {
    let rows: Vec<TodoSavedFilter> = sqlx::query_as(
        "SELECT * FROM todo_saved_filters WHERE is_deleted = 0 ORDER BY sort_order, id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 创建保存的筛选器
pub async fn create_saved_filter(
    pool: &SqlitePool,
    input: &TodoSavedFilterCreateInput,
) -> CoreResult<TodoSavedFilter> {
    if input.name.trim().is_empty() {
        return Err(CoreError::Other("筛选器名称不能为空".into()));
    }
    validate_conditions(&input.conditions)?;
    let now = crate::db::clock::next_ms();
    let uuid = uuid::Uuid::new_v4().to_string();
    let sort = input.sort_order.unwrap_or(now);
    let row: TodoSavedFilter = sqlx::query_as(
        "INSERT INTO todo_saved_filters (uuid, name, conditions, sort_order, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid)
    .bind(input.name.trim())
    .bind(&input.conditions)
    .bind(sort)
    .bind(now)
    .bind(now)
    .fetch_one(pool)
    .await?;
    emit("todo_saved_filters", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

/// 更新保存的筛选器
pub async fn update_saved_filter(
    pool: &SqlitePool,
    id: i64,
    input: &TodoSavedFilterUpdateInput,
) -> CoreResult<TodoSavedFilter> {
    if let Some(name) = &input.name
        && name.trim().is_empty()
    {
        return Err(CoreError::Other("筛选器名称不能为空".into()));
    }
    if let Some(c) = &input.conditions {
        validate_conditions(c)?;
    }
    let now = crate::db::clock::next_ms();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.name.is_some() {
        sets.push("name = ?".into());
    }
    if input.conditions.is_some() {
        sets.push("conditions = ?".into());
    }
    if input.sort_order.is_some() {
        sets.push("sort_order = ?".into());
    }
    let sql = format!(
        "UPDATE todo_saved_filters SET {} WHERE id = ? AND is_deleted = 0 RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoSavedFilter>(&sql).bind(now);
    if let Some(v) = &input.name {
        q = q.bind(v.trim());
    }
    if let Some(v) = &input.conditions {
        q = q.bind(v);
    }
    if let Some(v) = input.sort_order {
        q = q.bind(v);
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("saved_filter id={}", id)))?;
    emit("todo_saved_filters", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

/// 删除保存的筛选器（软删，随同步白名单走墓碑）
pub async fn delete_saved_filter(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let now = crate::db::clock::next_ms();
    let row: Option<(i64, String)> =
        sqlx::query_as("SELECT id, uuid FROM todo_saved_filters WHERE id = ? AND is_deleted = 0")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    let Some((rid, uuid)) = row else {
        return Ok(()); // 幂等
    };
    sqlx::query(
        "UPDATE todo_saved_filters
         SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1
         WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(rid)
    .execute(pool)
    .await?;
    emit("todo_saved_filters", rid, &uuid, DbOp::Update, now);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[tokio::test]
    async fn create_list_update_delete_roundtrip() {
        let pool = setup_db().await;
        let created = create_saved_filter(
            &pool,
            &TodoSavedFilterCreateInput {
                name: "本周 P0".into(),
                conditions: r#"{"priority_min":4,"due_within_days":7}"#.into(),
                sort_order: Some(1),
            },
        )
        .await
        .unwrap();
        assert_eq!(created.name, "本周 P0");

        let list = list_saved_filters(&pool).await.unwrap();
        assert_eq!(list.len(), 1);

        let updated = update_saved_filter(
            &pool,
            created.id,
            &TodoSavedFilterUpdateInput {
                name: Some("本周紧急".into()),
                conditions: None,
                sort_order: Some(2),
            },
        )
        .await
        .unwrap();
        assert_eq!(updated.name, "本周紧急");
        // conditions 未更新保持原值
        assert!(updated.conditions.contains("priority_min"));

        delete_saved_filter(&pool, created.id).await.unwrap();
        assert!(list_saved_filters(&pool).await.unwrap().is_empty());
        // 幂等：再删不报错
        delete_saved_filter(&pool, created.id).await.unwrap();
    }

    #[tokio::test]
    async fn invalid_condition_key_rejected() {
        let pool = setup_db().await;
        let err = create_saved_filter(
            &pool,
            &TodoSavedFilterCreateInput {
                name: "坏条件".into(),
                conditions: r#"{"evil_key":1}"#.into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err(), "未知条件键必须拒绝");
    }

    #[tokio::test]
    async fn invalid_json_rejected() {
        let pool = setup_db().await;
        let err = create_saved_filter(
            &pool,
            &TodoSavedFilterCreateInput {
                name: "坏JSON".into(),
                conditions: "not-json".into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn empty_name_rejected() {
        let pool = setup_db().await;
        let err = create_saved_filter(
            &pool,
            &TodoSavedFilterCreateInput {
                name: "  ".into(),
                conditions: "{}".into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err());
    }
}
