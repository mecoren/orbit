//! cfg_option_repo — 选项表仓储
//!
//! 为 cfg_option_categories / cfg_option_items 提供 CRUD。
//! 配置类表无 lamport / device_id，软删除逻辑简化。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::models::cfg_option::{CfgOptionCategory, CfgOptionItem, OptionItemDto};

// =============================================================================
// 分组（Category）CRUD
// =============================================================================

/// 列出全部分组（排除软删除）
///
/// include_inactive=false 时仅返回 is_active=1 的分组
pub async fn list_categories(
    pool: &SqlitePool,
    include_inactive: bool,
) -> CoreResult<Vec<CfgOptionCategory>> {
    let sql = if include_inactive {
        "SELECT * FROM cfg_option_categories WHERE is_deleted = 0 ORDER BY sort_order, id"
    } else {
        "SELECT * FROM cfg_option_categories WHERE is_deleted = 0 AND is_active = 1 ORDER BY sort_order, id"
    };
    let rows = sqlx::query_as::<_, CfgOptionCategory>(sql)
        .fetch_all(pool)
        .await?;
    Ok(rows)
}

/// 按 category_key 查询分组
pub async fn get_category_by_key(
    pool: &SqlitePool,
    key: &str,
) -> CoreResult<Option<CfgOptionCategory>> {
    let row = sqlx::query_as::<_, CfgOptionCategory>(
        "SELECT * FROM cfg_option_categories WHERE category_key = ? AND is_deleted = 0 LIMIT 1",
    )
    .bind(key)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 新建分组，返回新 id
///
/// fields_json 包含: category_key, label, description, is_active, sort_order
pub async fn create_category(
    pool: &SqlitePool,
    fields: &serde_json::Value,
) -> CoreResult<i64> {
    let now = chrono::Utc::now().timestamp_millis();
    let map = fields.as_object()
        .ok_or_else(|| CoreError::Other("fields_json 必须是 JSON 对象".to_string()))?;

    let category_key = map.get("category_key")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let label = map.get("label")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let description = map.get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let is_active = map.get("is_active")
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    let sort_order = map.get("sort_order")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);

    if category_key.is_empty() {
        return Err(CoreError::Other("category_key 不能为空".to_string()));
    }

    let result = sqlx::query(
        "INSERT INTO cfg_option_categories (category_key, label, description, is_active, sort_order, is_deleted, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?)",
    )
    .bind(category_key)
    .bind(label)
    .bind(description)
    .bind(is_active)
    .bind(sort_order)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(result.last_insert_rowid())
}

/// 更新分组
pub async fn update_category(
    pool: &SqlitePool,
    id: i64,
    fields: &serde_json::Value,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let map = fields.as_object()
        .ok_or_else(|| CoreError::Other("fields_json 必须是 JSON 对象".to_string()))?;

    let category_key = map.get("category_key")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let label = map.get("label")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let description = map.get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let is_active = map.get("is_active")
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    let sort_order = map.get("sort_order")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);

    sqlx::query(
        "UPDATE cfg_option_categories SET category_key = ?, label = ?, description = ?, is_active = ?, sort_order = ?, updated_at = ? WHERE id = ? AND is_deleted = 0",
    )
    .bind(category_key)
    .bind(label)
    .bind(description)
    .bind(is_active)
    .bind(sort_order)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(())
}

/// 软删除分组（级联软删除其下所有选项项）
pub async fn soft_delete_category(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();

    // 先级联软删除选项项
    sqlx::query(
        "UPDATE cfg_option_items SET is_deleted = 1, deleted_at = ?, updated_at = ? WHERE category_id = ? AND is_deleted = 0",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    // 再软删除分组本身
    sqlx::query(
        "UPDATE cfg_option_categories SET is_deleted = 1, deleted_at = ?, updated_at = ? WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(())
}

// =============================================================================
// 选项项（Item）CRUD
// =============================================================================

/// 按 category_key 列出启用选项（前端下拉框加载用）
///
/// 仅返回 is_active=1 且未软删除的选项，按 sort_order 排序
pub async fn list_items_by_key(
    pool: &SqlitePool,
    category_key: &str,
) -> CoreResult<Vec<OptionItemDto>> {
    let rows = sqlx::query_as::<_, OptionItemDto>(
        "SELECT i.value, i.label, i.is_default, i.color
         FROM cfg_option_items i
         INNER JOIN cfg_option_categories c ON i.category_id = c.id
         WHERE c.category_key = ? AND c.is_deleted = 0 AND c.is_active = 1
           AND i.is_deleted = 0 AND i.is_active = 1
         ORDER BY i.sort_order, i.id",
    )
    .bind(category_key)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 按 category_id 列出选项（管理用，可包含禁用项）
pub async fn list_items_by_category(
    pool: &SqlitePool,
    category_id: i64,
    include_inactive: bool,
) -> CoreResult<Vec<CfgOptionItem>> {
    let sql = if include_inactive {
        "SELECT * FROM cfg_option_items WHERE category_id = ? AND is_deleted = 0 ORDER BY sort_order, id"
    } else {
        "SELECT * FROM cfg_option_items WHERE category_id = ? AND is_deleted = 0 AND is_active = 1 ORDER BY sort_order, id"
    };
    let rows = sqlx::query_as::<_, CfgOptionItem>(sql)
        .bind(category_id)
        .fetch_all(pool)
        .await?;
    Ok(rows)
}

/// 新建选项项，返回新 id
///
/// fields_json 包含: category_id, value, label, sort_order, is_default, is_active, color
pub async fn create_item(
    pool: &SqlitePool,
    fields: &serde_json::Value,
) -> CoreResult<i64> {
    let now = chrono::Utc::now().timestamp_millis();
    let map = fields.as_object()
        .ok_or_else(|| CoreError::Other("fields_json 必须是 JSON 对象".to_string()))?;

    let category_id = map.get("category_id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| CoreError::Other("category_id 不能为空".to_string()))?;
    let value = map.get("value")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let label = map.get("label")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let sort_order = map.get("sort_order")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let is_default = map.get("is_default")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let is_active = map.get("is_active")
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    let color = map.get("color")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if value.is_empty() {
        return Err(CoreError::Other("value 不能为空".to_string()));
    }

    // 若 is_default=1，先清除同分组其他默认项
    if is_default != 0 {
        sqlx::query(
            "UPDATE cfg_option_items SET is_default = 0, updated_at = ? WHERE category_id = ? AND is_default = 1 AND is_deleted = 0",
        )
        .bind(now)
        .bind(category_id)
        .execute(pool)
        .await?;
    }

    let result = sqlx::query(
        "INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
    )
    .bind(category_id)
    .bind(value)
    .bind(label)
    .bind(sort_order)
    .bind(is_default)
    .bind(is_active)
    .bind(color)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(result.last_insert_rowid())
}

/// 更新选项项
pub async fn update_item(
    pool: &SqlitePool,
    id: i64,
    fields: &serde_json::Value,
) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();
    let map = fields.as_object()
        .ok_or_else(|| CoreError::Other("fields_json 必须是 JSON 对象".to_string()))?;

    let value = map.get("value")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let label = map.get("label")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let sort_order = map.get("sort_order")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let is_default = map.get("is_default")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let is_active = map.get("is_active")
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    let color = map.get("color")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if value.is_empty() {
        return Err(CoreError::Other("value 不能为空".to_string()));
    }

    // 若 is_default=1，先清除同分组其他默认项（排除自身）
    if is_default != 0 {
        sqlx::query(
            "UPDATE cfg_option_items SET is_default = 0, updated_at = ? WHERE category_id = (SELECT category_id FROM cfg_option_items WHERE id = ?) AND is_default = 1 AND id != ? AND is_deleted = 0",
        )
        .bind(now)
        .bind(id)
        .bind(id)
        .execute(pool)
        .await?;
    }

    sqlx::query(
        "UPDATE cfg_option_items SET value = ?, label = ?, sort_order = ?, is_default = ?, is_active = ?, color = ?, updated_at = ? WHERE id = ? AND is_deleted = 0",
    )
    .bind(value)
    .bind(label)
    .bind(sort_order)
    .bind(is_default)
    .bind(is_active)
    .bind(color)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(())
}

/// 软删除选项项
pub async fn soft_delete_item(pool: &SqlitePool, id: i64) -> CoreResult<()> {
    let now = chrono::Utc::now().timestamp_millis();

    sqlx::query(
        "UPDATE cfg_option_items SET is_deleted = 1, deleted_at = ?, updated_at = ? WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(())
}
