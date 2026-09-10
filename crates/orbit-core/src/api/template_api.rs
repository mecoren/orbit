//! template_api — 任务模板（竞品矩阵高价值缺口；对标 Vikunja Templates /
//! MS To Do 步骤列表可复用）
//!
//! 周报、报销单、差旅检查清单等多字段任务免从零搭建：模板存
//! {title?, notes?, priority?, due_offset_days?, subtasks?} 的自包含
//! JSON，套用 = 前端按存在键预填任务表单。模板不引用项目/标签实体
//! （跨设备实体 id 不稳定），内容自包含保证同步语义稳定。
//!
//! 同步白名单：todo_templates 进 SYNCABLE_TABLES（第 11 张业务表）；
//! 写路径完成 emit db-change（前端缓存失效链依赖）。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::eventbus::{
    EVENT_BUS,
    events::{DbEvent, DbOp},
};
use crate::models::business::{TodoTemplate, TodoTemplateCreateInput, TodoTemplateUpdateInput};

/// payload JSON 的合法键（校验用；防存进任意 JSON）
const ALLOWED_PAYLOAD_KEYS: &[&str] =
    &["title", "notes", "priority", "due_offset_days", "subtasks"];

/// 校验 payload JSON：必须是对象且键都在白名单内（防任意 JSON 进库）
fn validate_payload(payload: &str) -> CoreResult<()> {
    let parsed: serde_json::Value = serde_json::from_str(payload)
        .map_err(|e| CoreError::Other(format!("模板内容不是合法 JSON: {}", e)))?;
    let Some(obj) = parsed.as_object() else {
        return Err(CoreError::Other("模板内容必须是 JSON 对象".into()));
    };
    for key in obj.keys() {
        if !ALLOWED_PAYLOAD_KEYS.contains(&key.as_str()) {
            return Err(CoreError::Other(format!(
                "模板内容含未知键 `{}`（允许: {:?}）",
                key, ALLOWED_PAYLOAD_KEYS
            )));
        }
    }
    // subtasks 若存在必须是字符串数组（套用侧逐条建子任务）
    if let Some(v) = obj.get("subtasks")
        && !v
            .as_array()
            .is_some_and(|a| a.iter().all(|s| s.is_string()))
    {
        return Err(CoreError::Other("subtasks 必须是字符串数组".into()));
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

/// 列出全部模板（sort_order 升序）
pub async fn list_templates(pool: &SqlitePool) -> CoreResult<Vec<TodoTemplate>> {
    let rows: Vec<TodoTemplate> =
        sqlx::query_as("SELECT * FROM todo_templates WHERE is_deleted = 0 ORDER BY sort_order, id")
            .fetch_all(pool)
            .await?;
    Ok(rows)
}

/// 创建模板
pub async fn create_template(
    pool: &SqlitePool,
    input: &TodoTemplateCreateInput,
) -> CoreResult<TodoTemplate> {
    if input.name.trim().is_empty() {
        return Err(CoreError::Other("模板名称不能为空".into()));
    }
    validate_payload(&input.payload)?;
    let now = chrono::Utc::now().timestamp_millis();
    let uuid = uuid::Uuid::new_v4().to_string();
    let sort = input.sort_order.unwrap_or(now);
    let row: TodoTemplate = sqlx::query_as(
        "INSERT INTO todo_templates (uuid, name, payload, sort_order, is_deleted, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, 0, ?, ?, 1) RETURNING *",
    )
    .bind(&uuid)
    .bind(input.name.trim())
    .bind(&input.payload)
    .bind(sort)
    .bind(now)
    .bind(now)
    .fetch_one(pool)
    .await?;
    emit("todo_templates", row.id, &row.uuid, DbOp::Insert, now);
    Ok(row)
}

/// 更新模板
pub async fn update_template(
    pool: &SqlitePool,
    id: i64,
    input: &TodoTemplateUpdateInput,
) -> CoreResult<TodoTemplate> {
    if let Some(name) = &input.name
        && name.trim().is_empty()
    {
        return Err(CoreError::Other("模板名称不能为空".into()));
    }
    if let Some(p) = &input.payload {
        validate_payload(p)?;
    }
    let now = chrono::Utc::now().timestamp_millis();
    let mut sets: Vec<String> = vec!["updated_at = ?".into(), "version = version + 1".into()];
    if input.name.is_some() {
        sets.push("name = ?".into());
    }
    if input.payload.is_some() {
        sets.push("payload = ?".into());
    }
    if input.sort_order.is_some() {
        sets.push("sort_order = ?".into());
    }
    let sql = format!(
        "UPDATE todo_templates SET {} WHERE id = ? AND is_deleted = 0 RETURNING *",
        sets.join(", ")
    );
    let mut q = sqlx::query_as::<_, TodoTemplate>(&sql).bind(now);
    if let Some(v) = &input.name {
        q = q.bind(v.trim());
    }
    if let Some(v) = &input.payload {
        q = q.bind(v);
    }
    if let Some(v) = input.sort_order {
        q = q.bind(v);
    }
    let row = q
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| CoreError::NotFound(format!("template id={}", id)))?;
    emit("todo_templates", row.id, &row.uuid, DbOp::Update, now);
    Ok(row)
}

/// 删除模板（软删，随同步白名单走墓碑）
pub async fn delete_template(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let row: Option<(i64, String)> =
        sqlx::query_as("SELECT id, uuid FROM todo_templates WHERE id = ? AND is_deleted = 0")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    let Some((rid, uuid)) = row else {
        return Ok(()); // 幂等
    };
    sqlx::query(
        "UPDATE todo_templates
         SET is_deleted = 1, deleted_at = ?, updated_at = ?, version = version + 1
         WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(rid)
    .execute(pool)
    .await?;
    emit("todo_templates", rid, &uuid, DbOp::Update, now);
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
        let created = create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "差旅检查清单".into(),
                payload:
                    r#"{"title":"出差流程","priority":2,"subtasks":["订机票","订酒店","报销"]}"#
                        .into(),
                sort_order: Some(1),
            },
        )
        .await
        .unwrap();
        assert_eq!(created.name, "差旅检查清单");

        let list = list_templates(&pool).await.unwrap();
        assert_eq!(list.len(), 1);

        let updated = update_template(
            &pool,
            created.id,
            &TodoTemplateUpdateInput {
                name: Some("出差清单".into()),
                payload: None,
                sort_order: Some(2),
            },
        )
        .await
        .unwrap();
        assert_eq!(updated.name, "出差清单");
        // payload 未更新保持原值
        assert!(updated.payload.contains("subtasks"));

        delete_template(&pool, created.id).await.unwrap();
        assert!(list_templates(&pool).await.unwrap().is_empty());
        // 幂等：再删不报错
        delete_template(&pool, created.id).await.unwrap();
    }

    #[tokio::test]
    async fn invalid_payload_key_rejected() {
        let pool = setup_db().await;
        let err = create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "坏模板".into(),
                payload: r#"{"evil_key":1}"#.into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err(), "未知 payload 键必须拒绝");
    }

    #[tokio::test]
    async fn subtasks_must_be_string_array() {
        let pool = setup_db().await;
        let err = create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "坏 subtasks".into(),
                payload: r#"{"subtasks":[1,2]}"#.into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err(), "subtasks 必须是字符串数组");
        // 合法字符串数组通过
        create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "好 subtasks".into(),
                payload: r#"{"subtasks":["a","b"]}"#.into(),
                sort_order: None,
            },
        )
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn invalid_json_rejected() {
        let pool = setup_db().await;
        let err = create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "坏JSON".into(),
                payload: "not-json".into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn empty_name_rejected() {
        let pool = setup_db().await;
        let err = create_template(
            &pool,
            &TodoTemplateCreateInput {
                name: "  ".into(),
                payload: "{}".into(),
                sort_order: None,
            },
        )
        .await;
        assert!(err.is_err());
    }
}
