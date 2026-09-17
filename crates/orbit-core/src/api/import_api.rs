//! import_api — 数据导入业务编排
//!
//! 提供 `bulk_import_records` 通用批量导入能力，替代 Dart 侧
//! `DataImportService._importRecords` 的逐条循环编排。
//!
//! 设计要点：
//! - 单函数完成"冲突检测 + 策略路由 + 批量写入"，减少 FRB/Tauri 跨边界往返
//! - records_json 字段名必须为 snake_case 且与数据库列名对齐
//! - 元数据字段（uuid/id/timestamps/version/is_deleted）
//!   由 Rust 自动填充或用于冲突检测，不作为业务字段写入
//! - 关联数据（participants 等）不是业务表列，由 Dart 侧 adapter 在调用前后单独处理
//! - 每条记录失败不阻塞整体流程（与 Dart 侧 try/catch 行为一致）

use serde_json::{Value, json};
use sqlx::{Row, SqlitePool};
use std::collections::HashMap;

use crate::db::repository::generic_repo;
use crate::db::repository::import_type_validator::{
    load_table_columns, normalize_fields_with_columns,
};
use crate::db::sync_registry::IMPORTABLE_TABLES;
use crate::error::{CoreError, CoreResult};

/// 元数据字段集合（由 Rust 自动填充，不作为业务字段写入）
///
/// 这些字段在 create_record_by_json_void / update_record_by_json_void 中
/// 由 Rust 自动处理（uuid 自动生成、timestamps 自动填充、version 自动递增），
/// 从导入记录中过滤掉避免覆盖。
const METADATA_FIELDS: &[&str] = &[
    "id",
    "uuid",
    "is_deleted",
    "deleted_at",
    "created_at",
    "updated_at",
    "version",
];

/// 批量导入记录（通用 upsert + 冲突路由）
///
/// 在单次调用内遍历所有记录，按 UUID 冲突检测 + 策略路由执行写入，
/// 返回 `{success, skip, fail, errors}` JSON 字符串。
///
/// # 参数
/// - `pool`: 数据库连接池
/// - `table_name`: 业务表名（必须在白名单中）
/// - `records_json`: JSON 数组字符串，每个元素为业务字段对象（snake_case 列名）
/// - `strategy`: 冲突策略，"skip" / "overwrite" / "forceInsert"
///
/// # 策略语义（与 Dart 侧 ConflictStrategy 一致）
/// - `skip`: UUID 已存在则跳过该条
/// - `overwrite`: UUID 已存在则更新现有记录
/// - `forceInsert`: UUID 已存在则作为新记录插入（忽略原 uuid，由 Rust 生成新 uuid）
///
/// # 返回
/// ```json
/// {"success": 10, "skip": 2, "fail": 1, "errors": ["第 3 条记录导入失败: ..."]}
/// ```
///
/// # 错误处理
/// - 表名不在白名单 → 立即返回错误
/// - 策略非法 → 立即返回错误
/// - records_json 解析失败 → 立即返回错误
/// - 单条记录写入失败 → 计入 fail + errors，继续处理后续记录
pub async fn bulk_import_records(
    pool: &SqlitePool,
    table_name: &str,
    records_json: String,
    strategy: &str,
) -> CoreResult<String> {
    // 解析 JSON 字符串后委托给 bulk_import_records_from_values
    // 保留此函数以维持与移动端 FRB bridge 的签名兼容
    let records: Vec<Value> = serde_json::from_str(&records_json)?;
    bulk_import_records_from_values(pool, table_name, records, strategy).await
}

/// 批量导入记录（接受已解析的 Vec<Value>，避免 JSON 字符串序列化/反序列化往返）
///
/// 与 `bulk_import_records` 行为一致，但直接接受结构化数据，适用于：
/// - 桌面端 `data_import_with_mapping` 命令（Rust 侧完成解析+字段映射后直接调用）
/// - 桌面端 `import_records_json_internal`（已解析的 Vec<Map> 转换后调用）
///
/// 性能优势：避免 50 条小批次 × (serialize → IPC → parse) 往返，
/// 单次调用完成所有记录的冲突检测 + 单事务写入。
pub async fn bulk_import_records_from_values(
    pool: &SqlitePool,
    table_name: &str,
    records: Vec<Value>,
    strategy: &str,
) -> CoreResult<String> {
    // 1. 校验表名白名单（防 SQL 注入）
    if !IMPORTABLE_TABLES.contains(&table_name) {
        return Err(CoreError::Other(format!(
            "table '{}' is not allowed for import",
            table_name
        )));
    }

    // 2. 校验策略合法性
    let strategy_normalized = strategy.to_lowercase();
    if !matches!(
        strategy_normalized.as_str(),
        "skip" | "overwrite" | "forceinsert"
    ) {
        return Err(CoreError::Other(format!(
            "invalid import strategy: '{}', expected skip/overwrite/forceInsert",
            strategy
        )));
    }

    // 3. 预加载列类型定义（1 次 PRAGMA 查询，替代逐条查库）
    let columns = load_table_columns(pool, table_name).await?;

    // 4. 内存中规范化所有记录（无 DB 查询），分离成功/失败
    //    结构：(uuid, normalized_business_fields)
    let mut normalized: Vec<(String, serde_json::Map<String, Value>)> =
        Vec::with_capacity(records.len());
    let mut fail: u64 = 0;
    let mut errors: Vec<String> = Vec::new();

    for (idx, record) in records.iter().enumerate() {
        let record_no = idx + 1;
        let obj = match record.as_object() {
            Some(o) => o,
            None => {
                fail += 1;
                errors.push(format!(
                    "第 {} 条记录导入失败: record must be a JSON object",
                    record_no
                ));
                continue;
            }
        };
        let uuid = obj
            .get("uuid")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let business = filter_business_fields(obj);
        match normalize_fields_with_columns(&business, &columns, true) {
            Ok(n) => normalized.push((uuid, n)),
            Err(e) => {
                fail += 1;
                errors.push(format!("第 {} 条记录导入失败: {}", record_no, e));
            }
        }
    }

    // 5. 批量查询 UUID 冲突（分块 IN 查询，SQLite 参数限制 999）
    //    构建 HashMap<uuid, existing_id>，避免逐条 SELECT
    let mut existing_uuids: HashMap<String, i64> = HashMap::new();
    let unique_uuids: Vec<&str> = {
        let mut seen = std::collections::HashSet::new();
        normalized
            .iter()
            .filter(|(u, _)| !u.is_empty())
            .map(|(u, _)| u.as_str())
            .filter(|u| seen.insert(*u))
            .collect()
    };

    for chunk in unique_uuids.chunks(900) {
        if chunk.is_empty() {
            continue;
        }
        let placeholders = vec!["?"; chunk.len()].join(",");
        let sql = format!(
            "SELECT id, uuid FROM {} WHERE is_deleted = 0 AND uuid IN ({})",
            table_name, placeholders
        );
        let mut q = sqlx::query(&sql);
        for uuid in chunk {
            q = q.bind(uuid);
        }
        let rows = q.fetch_all(pool).await?;
        for row in rows {
            let id: i64 = row.try_get("id")?;
            let uuid: String = row.try_get("uuid")?;
            existing_uuids.insert(uuid, id);
        }
    }

    // 6. 开启事务（1 次 commit 替代逐条隐式事务，性能提升 10-100x）
    //    SQLite 默认 ON CONFLICT ABORT：单条 INSERT 失败仅回滚该语句，事务继续
    let mut tx = pool.begin().await?;
    let now = crate::db::clock::next_ms();

    let mut success: u64 = 0;
    let mut skip: u64 = 0;

    for (uuid, fields) in &normalized {
        let existing_id = if !uuid.is_empty() {
            existing_uuids.get(uuid).copied()
        } else {
            None
        };

        match (existing_id, strategy_normalized.as_str()) {
            // 无冲突：INSERT
            (None, _) => match build_and_execute_insert(&mut tx, table_name, fields, now).await {
                Ok(()) => success += 1,
                Err(e) => {
                    fail += 1;
                    errors.push(format!("记录(uuid={})插入失败: {}", uuid, e));
                }
            },
            // 冲突 + skip：跳过
            (Some(_), "skip") => {
                skip += 1;
            }
            // 冲突 + overwrite：UPDATE 现有记录
            (Some(id), "overwrite") => {
                match build_and_execute_update(&mut tx, table_name, id, fields, now).await {
                    Ok(()) => success += 1,
                    Err(e) => {
                        fail += 1;
                        errors.push(format!("记录(uuid={}, id={})更新失败: {}", uuid, id, e));
                    }
                }
            }
            // 冲突 + forceInsert：作为新记录插入（uuid 由 Rust 生成新值）
            (Some(_), "forceinsert") => {
                match build_and_execute_insert(&mut tx, table_name, fields, now).await {
                    Ok(()) => success += 1,
                    Err(e) => {
                        fail += 1;
                        errors.push(format!("记录(uuid={})插入失败: {}", uuid, e));
                    }
                }
            }
            // 理论上不可达（策略已在入口校验）
            (Some(_), s) => {
                return Err(CoreError::Other(format!(
                    "unreachable: unknown strategy '{}' after validation",
                    s
                )));
            }
        }
    }

    // 7. 提交事务
    tx.commit().await?;

    Ok(json!({
        "success": success,
        "skip": skip,
        "fail": fail,
        "errors": errors,
    })
    .to_string())
}

/// 在事务中构建并执行 INSERT 语句
///
/// 与 generic_repo::create_record_by_json_void 逻辑一致，
/// 但使用事务执行器而非连接池，且 now 由调用方预计算。
async fn build_and_execute_insert(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    fields: &serde_json::Map<String, Value>,
    now: i64,
) -> CoreResult<()> {
    let new_uuid = uuid::Uuid::new_v4().to_string();

    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("INSERT INTO ");
    q.push(table);
    q.push(" (uuid, is_deleted, created_at, updated_at, version");
    for key in fields.keys() {
        generic_repo::validate_column_name(key)?;
        q.push(", ");
        q.push(key);
    }
    q.push(") VALUES (");
    q.push_bind(new_uuid);
    q.push(", ");
    q.push_bind(0i32);
    q.push(", ");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(now);
    q.push(", ");
    q.push_bind(1i32);
    for val in fields.values() {
        q.push(", ");
        generic_repo::push_json_value(&mut q, val);
    }
    q.push(")");

    q.build().execute(&mut **tx).await?;
    Ok(())
}

/// 在事务中构建并执行 UPDATE 语句
///
/// 与 generic_repo::update_record_by_json_void 逻辑一致，
/// 但使用事务执行器而非连接池，且 now 由调用方预计算。
async fn build_and_execute_update(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    table: &str,
    id: i64,
    fields: &serde_json::Map<String, Value>,
    now: i64,
) -> CoreResult<()> {
    let mut q: sqlx::QueryBuilder<'_, sqlx::Sqlite> = sqlx::QueryBuilder::new("UPDATE ");
    q.push(table);
    q.push(" SET updated_at = ");
    q.push_bind(now);
    q.push(", version = version + 1");

    for (key, val) in fields.iter() {
        generic_repo::validate_column_name(key)?;
        q.push(", ");
        q.push(key);
        q.push(" = ");
        generic_repo::push_json_value(&mut q, val);
    }

    q.push(" WHERE id = ");
    q.push_bind(id);

    q.build().execute(&mut **tx).await?;
    Ok(())
}

/// 从记录对象中过滤出纯业务字段
///
/// 移除所有元数据字段（id/uuid/timestamps/version/is_deleted 等），
/// 这些字段由 Rust 在 create/update 时自动填充或用于冲突检测。
fn filter_business_fields(obj: &serde_json::Map<String, Value>) -> serde_json::Map<String, Value> {
    let mut business = serde_json::Map::new();
    for (key, val) in obj.iter() {
        if !METADATA_FIELDS.contains(&key.as_str()) {
            business.insert(key.clone(), val.clone());
        }
    }
    business
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_business_fields_removes_metadata() {
        let mut obj = serde_json::Map::new();
        obj.insert("id".into(), json!(1));
        obj.insert("uuid".into(), json!("abc-123"));
        obj.insert("title".into(), json!("test movie"));
        obj.insert("created_at".into(), json!(1700000000));
        obj.insert("version".into(), json!(5));
        obj.insert("is_deleted".into(), json!(0));
        obj.insert("rating".into(), json!(8.5));

        let business = filter_business_fields(&obj);
        // 仅保留业务字段
        assert!(business.contains_key("title"));
        assert!(business.contains_key("rating"));
        // 元数据字段被过滤
        assert!(!business.contains_key("id"));
        assert!(!business.contains_key("uuid"));
        assert!(!business.contains_key("created_at"));
        assert!(!business.contains_key("version"));
        assert!(!business.contains_key("is_deleted"));
    }

    #[test]
    fn importable_tables_covers_todo_module() {
        // Orbit 不变量：导入白名单与备份白名单一致，且覆盖 todo 全部 8 张业务表
        for t in crate::db::sync_registry::FULL_BACKUP_TABLES {
            assert!(IMPORTABLE_TABLES.contains(t), "导入白名单缺备份表: {t}");
        }
        for t in [
            "todo_projects",
            "todo_tasks",
            "todo_subtasks",
            "todo_labels",
            "todo_task_labels",
            "todo_comments",
            "todo_task_relations",
            "todo_reminders",
        ] {
            assert!(IMPORTABLE_TABLES.contains(&t));
        }
        // 系统表不在白名单
        assert!(!IMPORTABLE_TABLES.contains(&"sync_configs"));
    }

    /// 初始化带完整迁移的内存数据库（供集成测试使用）
    async fn setup_migrated_db() -> sqlx::SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    #[tokio::test]
    async fn bulk_import_converts_string_integer_to_int() {
        let pool = setup_migrated_db().await;
        let records = json!([{
            "uuid": "task-001",
            "title": "Test Task",
            "priority": "3"
        }])
        .to_string();

        let res = bulk_import_records(&pool, "todo_tasks", records, "overwrite")
            .await
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&res).unwrap();
        assert_eq!(parsed["success"].as_u64().unwrap(), 1);
        assert_eq!(parsed["fail"].as_u64().unwrap(), 0);

        // 关键断言：后续按 INTEGER 读取不应再报类型错误
        let list_json = crate::api::business_api::list_records_as_json(&pool, "todo_tasks")
            .await
            .unwrap();
        let list: Vec<serde_json::Value> = serde_json::from_str(&list_json).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["priority"].as_i64().unwrap(), 3);
    }

    #[tokio::test]
    async fn bulk_import_rejects_invalid_integer() {
        let pool = setup_migrated_db().await;
        let records = json!([{
            "uuid": "task-002",
            "title": "Bad Task",
            "priority": "abc"
        }])
        .to_string();

        let res = bulk_import_records(&pool, "todo_tasks", records, "overwrite")
            .await
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&res).unwrap();
        assert_eq!(parsed["success"].as_u64().unwrap(), 0);
        assert_eq!(parsed["fail"].as_u64().unwrap(), 1);
        let errors = parsed["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 1);
        assert!(errors[0].as_str().unwrap().contains("priority"));
    }
}
