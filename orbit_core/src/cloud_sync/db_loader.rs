//! db_loader — 从数据库加载模块数据
//!
//! 为 Push/Pull/Merge 提供"按模块加载所有表数据"的统一入口。
//! 每条记录附加 `_table` 字段标记来源表，便于合并时路由。
//!
//! ## 可同步表白名单
//! 唯一来源：`crate::db::sync_registry::SYNCABLE_TABLES`（仅含带 uuid 列的表，
//! 无 uuid 的表无法做 item 级 LWW 合并）。
//!
//! ## 记录格式
//! 每条记录是 `serde_json::Value::Object`，包含：
//! - 原始 DB 列（uuid, name, updated_at, ...）
//! - `_table`：来源表名，合并时用于路由

use std::collections::HashMap;

use sqlx::{Column, Row, SqlitePool, TypeInfo};

use crate::cloud_sync::error::CloudSyncError;
use crate::cloud_sync::modules::SyncModuleDef;
use crate::db::sync_registry::SYNCABLE_TABLES;

/// 判断表是否可同步（在白名单内，白名单唯一来源见 db::sync_registry）
fn is_syncable(table: &str) -> bool {
    SYNCABLE_TABLES.contains(&table)
}

/// 加载模块所有可同步表的记录
///
/// 遍历 `module_def.tables`，对每个在白名单内的表执行：
/// `SELECT * FROM {table} WHERE is_deleted = 0`
///
/// 每条记录附加 `_table` 字段，所有表的记录合并为单个数组返回。
pub async fn load_module_items(
    pool: &SqlitePool,
    module_def: &SyncModuleDef,
) -> Result<Vec<serde_json::Value>, CloudSyncError> {
    let mut all_items = Vec::new();

    for table in module_def.tables {
        if !is_syncable(table) {
            // 跳过不在白名单的表（0004 迁移后 4 张关联/系统表均已纳入）
            continue;
        }

        let sql = format!("SELECT * FROM \"{}\" WHERE is_deleted = 0", table);
        let rows = sqlx::query(&sql)
            .fetch_all(pool)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("加载表 {} 失败: {}", table, e),
            })?;

        for row in &rows {
            let mut obj = sqlite_row_to_json(row);
            obj.insert(
                "_table".to_string(),
                serde_json::Value::String(table.to_string()),
            );
            all_items.push(serde_json::Value::Object(obj));
        }
    }

    Ok(all_items)
}

/// 加载模块所有软删除记录作为墓碑集（无上限，含 deleted_at 时间戳）
///
/// FR-2.4：从所有可同步表查询 `is_deleted = 1` 的记录，返回 (uuid, deleted_at) 对。
/// deleted_at 优先取业务表的 deleted_at 列（软删除时间），为 NULL/0 时回退到 updated_at。
/// 不再限制 N 条上限，所有历史删除均上传到云端 meta.waitsync。
pub async fn load_all_tombstones(
    pool: &SqlitePool,
    module_def: &SyncModuleDef,
) -> Result<Vec<(String, i64)>, CloudSyncError> {
    let mut all_deleted: Vec<(String, i64)> = Vec::new();

    for table in module_def.tables {
        if !is_syncable(table) {
            continue;
        }

        // 优先取 deleted_at（软删除时间），为 NULL 时回退到 updated_at
        let sql = format!(
            "SELECT uuid, COALESCE(NULLIF(deleted_at, 0), updated_at) AS ts \
             FROM \"{}\" WHERE is_deleted = 1",
            table
        );
        let rows = sqlx::query(&sql)
            .fetch_all(pool)
            .await
            .map_err(|e| CloudSyncError::Database {
                message: format!("加载表 {} 墓碑失败: {}", table, e),
            })?;

        for row in rows {
            let uuid: String = row.try_get("uuid").unwrap_or_default();
            let ts: i64 = row.try_get("ts").unwrap_or(0);
            if !uuid.is_empty() {
                all_deleted.push((uuid, ts));
            }
        }
    }

    Ok(all_deleted)
}

/// 本地单条记录的合并裁决状态（Fix-01）
///
/// 历史问题：旧版只加载 `is_deleted = 0` 的存活记录，
/// 导致「本地软删除 + 远端存活」同 uuid 记录被误判为 INSERT——
/// 而 uuid 列无唯一约束，插入不报错而是产生重复行（一活一墓碑僵尸行）；
/// 后续按 uuid 的 UPDATE 会同时命中两行并借远端 item 携带的
/// `is_deleted = 0` 字段把僵尸行整体复活。
#[derive(Debug, Clone, Copy)]
pub struct LocalRecordState {
    /// 记录更新时间（LWW 主键）
    pub updated_at: i64,
    /// 版本号（updated_at 平局次级裁决，缺失视为 0）
    pub version: i64,
    /// 是否处于软删除状态
    pub is_deleted: bool,
    /// 软删除时间（仅 is_deleted=true 时有意义）。
    /// 取值口径与 `load_all_tombstones` 一致：COALESCE(NULLIF(deleted_at,0), updated_at)。
    pub deleted_at: i64,
}

/// 加载本地全部记录（含软删除）的 uuid 状态映射（用于 LWW 合并与复活裁决）
///
/// 返回 HashMap<uuid, LocalRecordState>。
/// 软删除记录必须纳入映射：merge 据此区分「INSERT 新纪录」与「复活已有记录」。
pub async fn load_local_uuid_map(
    pool: &SqlitePool,
    module_def: &SyncModuleDef,
) -> Result<HashMap<String, LocalRecordState>, CloudSyncError> {
    let mut map = HashMap::new();

    for table in module_def.tables {
        if !is_syncable(table) {
            continue;
        }

        let sql = format!(
            "SELECT uuid, updated_at, version, is_deleted, \
             COALESCE(NULLIF(deleted_at, 0), updated_at) AS deleted_at \
             FROM \"{}\"",
            table
        );
        let rows: Vec<(String, i64, i64, i64, i64)> =
            sqlx::query_as(&sql).fetch_all(pool).await.map_err(|e| {
                CloudSyncError::Database {
                    message: format!("加载表 {} uuid 映射失败: {}", table, e),
                }
            })?;

        for (uuid, updated_at, version, is_deleted, deleted_at) in rows {
            if uuid.is_empty() {
                continue;
            }
            // 同一 uuid 在模块内多表出现时后者覆盖前者（与旧版行为一致）
            map.insert(
                uuid,
                LocalRecordState {
                    updated_at,
                    version,
                    is_deleted: is_deleted != 0,
                    deleted_at,
                },
            );
        }
    }

    Ok(map)
}

/// 将 sqlx SqliteRow 转为 serde_json::Map<String, Value>
///
/// 按 SQLite 动态类型分派解码，与 business_api::sqlite_row_to_json 逻辑一致。
fn sqlite_row_to_json(row: &sqlx::sqlite::SqliteRow) -> serde_json::Map<String, serde_json::Value> {
    let mut obj = serde_json::Map::new();
    for (i, col) in row.columns().iter().enumerate() {
        let name = col.name().to_string();
        let type_name = col.type_info().name();
        let val = match type_name {
            "INTEGER" | "INT" | "INTEGER8" => {
                let v: Option<i64> = row.try_get(i).unwrap_or(None);
                serde_json::Value::from(v)
            }
            "REAL" | "FLOAT" | "DOUBLE" | "REAL8" => {
                let v: Option<f64> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            "TEXT" | "VARCHAR" | "CHAR" => {
                let v: Option<String> = row.try_get(i).unwrap_or(None);
                v.map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null)
            }
            _ => {
                // 未知类型：依次尝试 i64 → f64 → String → null
                if let Ok(v) = row.try_get::<Option<i64>, _>(i) {
                    serde_json::Value::from(v)
                } else if let Ok(v) = row.try_get::<Option<f64>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else if let Ok(v) = row.try_get::<Option<String>, _>(i) {
                    v.map(serde_json::Value::from)
                        .unwrap_or(serde_json::Value::Null)
                } else {
                    serde_json::Value::Null
                }
            }
        };
        obj.insert(name, val);
    }
    obj
}

/// 获取当前时间（Unix 毫秒）
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syncable_tables_matches_registry() {
        // Orbit：白名单唯一来源为 db::sync_registry，逐表核对
        for t in crate::db::sync_registry::SYNCABLE_TABLES {
            assert!(is_syncable(t), "注册表白名单内的表应可同步: {t}");
        }
        // todo 8 张业务表 + cfg 模块表全部可同步
        assert!(is_syncable("todo_projects"));
        assert!(is_syncable("todo_tasks"));
        assert!(is_syncable("todo_subtasks"));
        assert!(is_syncable("todo_labels"));
        assert!(is_syncable("todo_task_labels"));
        assert!(is_syncable("todo_comments"));
        assert!(is_syncable("todo_task_relations"));
        assert!(is_syncable("todo_reminders"));
        assert!(is_syncable("cfg_feature_modules"));
        // 已裁剪模块的表不可同步
        assert!(!is_syncable("rec_movies"));
        assert!(!is_syncable("usr_family_members"));
        assert!(!is_syncable("career_companies"));
        assert!(!is_syncable("phone_numbers"));
        assert!(!is_syncable("women_health_logs"));
        // 历史遗留表名防误启
        assert!(!is_syncable("todo_items"));
        assert!(!is_syncable("important_dates"));
    }

    #[test]
    fn now_ms_returns_positive() {
        let t = now_ms();
        assert!(t > 0);
    }
}
