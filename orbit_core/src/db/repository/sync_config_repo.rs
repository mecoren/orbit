//! sync_config_repo — 同步配置仓储
//!
//! 取代 Drift 的 SyncConfigDao。
//! save_config 实现激活互斥逻辑：同一时刻只允许一条激活配置。

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};
use crate::models::sync_config::{SyncConfigRecord, SyncConfigSaveInput};

pub struct SyncConfigRepo {
    pool: SqlitePool,
}

impl SyncConfigRepo {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// 查询激活配置（is_active=1 且未软删除）
    pub async fn get_active_config(&self) -> CoreResult<Option<SyncConfigRecord>> {
        let row = sqlx::query_as::<_, SyncConfigRecord>(
            "SELECT * FROM sync_configs WHERE is_active = 1 AND deleted_at IS NULL LIMIT 1",
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// 查询全部配置（排除软删除），按 updated_at DESC 排序
    pub async fn get_configs(&self) -> CoreResult<Vec<SyncConfigRecord>> {
        let rows = sqlx::query_as::<_, SyncConfigRecord>(
            "SELECT * FROM sync_configs WHERE deleted_at IS NULL ORDER BY updated_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// 保存配置（新建或更新）
    ///
    /// 激活互斥逻辑：若 is_active=1，先将其他配置置为非激活，再 INSERT/UPDATE。
    /// id 为 None 时新建，有值时更新现有记录。
    pub async fn save_config(&self, input: &SyncConfigSaveInput) -> CoreResult<SyncConfigRecord> {
        let now = chrono::Utc::now().timestamp_millis();

        // 激活互斥：若新配置为激活状态，先取消其他配置的激活
        if input.is_active == 1 {
            sqlx::query(
                "UPDATE sync_configs SET is_active = 0, updated_at = ? WHERE is_active = 1 AND deleted_at IS NULL",
            )
            .bind(now)
            .execute(&self.pool)
            .await?;
        }

        let record = if input.id.is_none() {
            // 新建
            sqlx::query_as::<_, SyncConfigRecord>(
                "INSERT INTO sync_configs (
                    protocol, endpoint, bucket, region, path, device_id, credential,
                    encryption_key_id, merge_strategy, sync_mode, max_update_age_hours,
                    is_encrypted, is_active, is_auto_sync, sync_interval, sync_on_change,
                    concurrent_reqs, timeout, skip_tls_verify,
                    created_at, updated_at, version, targets, local_path,
                    schedule_type, schedule_time, schedule_weekday, sync_scope,
                    full_sync_interval, history_keep_count, notify_progress
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                RETURNING *",
            )
            .bind(&input.protocol)
            .bind(&input.endpoint)
            .bind(&input.bucket)
            .bind(&input.region)
            .bind(&input.path)
            .bind(&input.device_id)
            .bind(&input.credential)
            .bind(&input.encryption_key_id)
            .bind(&input.merge_strategy)
            .bind(&input.sync_mode)
            .bind(input.max_update_age_hours)
            .bind(input.is_encrypted)
            .bind(input.is_active)
            .bind(input.is_auto_sync)
            .bind(input.sync_interval)
            .bind(input.sync_on_change)
            .bind(input.concurrent_reqs)
            .bind(input.timeout)
            .bind(input.skip_tls_verify)
            .bind(now)
            .bind(now)
            .bind(&input.targets)
            .bind(input.local_path.as_deref())
            .bind(&input.schedule_type)
            .bind(input.schedule_time.as_deref())
            .bind(input.schedule_weekday)
            .bind(&input.sync_scope)
            .bind(input.full_sync_interval)
            .bind(input.history_keep_count)
            .bind(input.notify_progress)
            .fetch_one(&self.pool)
            .await?
        } else {
            // 更新现有记录
            let id = input.id.unwrap();
            sqlx::query_as::<_, SyncConfigRecord>(
                "UPDATE sync_configs SET
                    protocol = ?, endpoint = ?, bucket = ?, region = ?, path = ?,
                    device_id = ?, credential = ?, encryption_key_id = ?,
                    merge_strategy = ?, sync_mode = ?, max_update_age_hours = ?,
                    is_encrypted = ?, is_active = ?, is_auto_sync = ?,
                    sync_interval = ?, sync_on_change = ?, concurrent_reqs = ?,
                    timeout = ?, skip_tls_verify = ?, targets = ?, local_path = ?,
                    schedule_type = ?, schedule_time = ?, schedule_weekday = ?,
                    sync_scope = ?, full_sync_interval = ?, history_keep_count = ?,
                    notify_progress = ?, updated_at = ?, version = version + 1
                WHERE id = ?
                RETURNING *",
            )
            .bind(&input.protocol)
            .bind(&input.endpoint)
            .bind(&input.bucket)
            .bind(&input.region)
            .bind(&input.path)
            .bind(&input.device_id)
            .bind(&input.credential)
            .bind(&input.encryption_key_id)
            .bind(&input.merge_strategy)
            .bind(&input.sync_mode)
            .bind(input.max_update_age_hours)
            .bind(input.is_encrypted)
            .bind(input.is_active)
            .bind(input.is_auto_sync)
            .bind(input.sync_interval)
            .bind(input.sync_on_change)
            .bind(input.concurrent_reqs)
            .bind(input.timeout)
            .bind(input.skip_tls_verify)
            .bind(&input.targets)
            .bind(input.local_path.as_deref())
            .bind(&input.schedule_type)
            .bind(input.schedule_time.as_deref())
            .bind(input.schedule_weekday)
            .bind(&input.sync_scope)
            .bind(input.full_sync_interval)
            .bind(input.history_keep_count)
            .bind(input.notify_progress)
            .bind(now)
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(|| CoreError::NotFound(format!("sync_config id={}", id)))?
        };

        Ok(record)
    }

    /// 更新最后同步时间
    pub async fn update_last_synced_at(&self, id: i64, timestamp_ms: i64) -> CoreResult<()> {
        sqlx::query("UPDATE sync_configs SET last_synced_at = ?, updated_at = ? WHERE id = ?")
            .bind(timestamp_ms)
            .bind(timestamp_ms)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// 更新同步模式
    pub async fn update_sync_mode(&self, id: i64, mode: &str) -> CoreResult<()> {
        let now = chrono::Utc::now().timestamp_millis();
        sqlx::query("UPDATE sync_configs SET sync_mode = ?, updated_at = ? WHERE id = ?")
            .bind(mode)
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// 更新同步模式字段（sync_on_change + sync_interval）
    ///
    /// 供"同步模式设置 UI"调用：用户选择"修改后立即同步"和"定时间隔"后，
    /// 通过此方法更新 DB 中的 sync_on_change / sync_interval 字段。
    /// - sync_on_change: 0=关闭, 非0=开启
    /// - sync_interval: 0=关闭定时同步, 10/30/60=分钟间隔
    pub async fn update_sync_mode_fields(
        &self,
        id: i64,
        sync_on_change: i64,
        sync_interval: i64,
    ) -> CoreResult<()> {
        let now = chrono::Utc::now().timestamp_millis();
        sqlx::query(
            "UPDATE sync_configs SET sync_on_change = ?, sync_interval = ?, updated_at = ?, version = version + 1 WHERE id = ?",
        )
        .bind(sync_on_change)
        .bind(sync_interval)
        .bind(now)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// 重置最后同步时间为 NULL
    ///
    /// 协议变更时调用，确保下次同步全量拉取新云端数据。
    /// 替代 Dart 侧 `dbExecuteRaw('UPDATE sync_configs SET last_synced_at = NULL ...')`。
    pub async fn reset_last_synced_at(&self, id: i64) -> CoreResult<()> {
        let now = chrono::Utc::now().timestamp_millis();
        sqlx::query("UPDATE sync_configs SET last_synced_at = NULL, updated_at = ? WHERE id = ?")
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// 更新激活状态
    pub async fn update_active_status(&self, id: i64, is_active: bool) -> CoreResult<()> {
        let now = chrono::Utc::now().timestamp_millis();
        // 激活互斥：若激活此配置，先取消其他配置的激活
        if is_active {
            sqlx::query(
                "UPDATE sync_configs SET is_active = 0, updated_at = ? WHERE id != ? AND is_active = 1",
            )
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        }
        sqlx::query("UPDATE sync_configs SET is_active = ?, updated_at = ? WHERE id = ?")
            .bind(if is_active { 1 } else { 0 })
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// 软删除配置
    pub async fn soft_delete_config(&self, id: i64) -> CoreResult<bool> {
        let now = chrono::Utc::now().timestamp_millis();
        let result = sqlx::query(
            "UPDATE sync_configs SET deleted_at = ?, updated_at = ?, is_active = 0 WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }
}
