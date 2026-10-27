//! dev_seed — 移动端桥接层测试数据域（仅开发构建可用）
//!
//! 与桌面壳命令一一对应（业务全部在 orbit_core::api::dev_seed_api）：
//! - dev_seed_demo_data → 桌面 `dev_seed_demo_data(plan)`：单事务批量写入示例库；
//! - dev_seed_clear → 桌面 `dev_seed_clear`：按 uuid 前缀物理清除示例行。
//!
//! **环境门禁**：前端入口只在 `kDebugMode` 下列出，本层再判 `cfg!(debug_assertions)`
//! ——release 构建里该常量折叠为 false，即使被别处调用也只拿到「不可用」错误。
//!
//! DTO 镜像模式：本地 DTO 显式镜像 core 的 Serialize 结构（与 [super::stats] 同
//! 规则），不直接暴露 core 类型，保持两端壳独立演进。

use orbit_core::api::dev_seed_api;

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// 环境门禁：release 构建一律拒绝
fn ensure_dev_build() -> Result<(), String> {
    if cfg!(debug_assertions) {
        Ok(())
    } else {
        Err("测试数据只在开发构建（debug）可用".to_string())
    }
}

// ============================================================================
// DTO 镜像（core dev_seed_api 结构 → FRB 可见）
// ============================================================================

/// 生成规模（镜像 core DevSeedPlan；只暴露任务条数）
#[derive(Debug, Clone, serde::Serialize)]
pub struct DevSeedPlan {
    /// 任务条数（含约 2% 回收站墓碑行）
    pub tasks: i64,
}

/// 各表写入/清除条数（镜像 core DevSeedCounts）
#[derive(Debug, Clone, serde::Serialize)]
pub struct DevSeedCounts {
    pub projects: i64,
    pub labels: i64,
    pub tasks: i64,
    pub subtasks: i64,
    pub reminders: i64,
    pub comments: i64,
    pub task_labels: i64,
    pub task_relations: i64,
}

/// 生成结果（`cleared` = 生成前清掉的上一批）
#[derive(Debug, Clone, serde::Serialize)]
pub struct DevSeedResult {
    pub created: DevSeedCounts,
    pub cleared: DevSeedCounts,
    pub elapsed_ms: i64,
}

/// 清理结果
#[derive(Debug, Clone, serde::Serialize)]
pub struct DevSeedClearResult {
    pub removed: DevSeedCounts,
    pub elapsed_ms: i64,
}

impl From<dev_seed_api::DevSeedCounts> for DevSeedCounts {
    fn from(c: dev_seed_api::DevSeedCounts) -> Self {
        Self {
            projects: c.projects,
            labels: c.labels,
            tasks: c.tasks,
            subtasks: c.subtasks,
            reminders: c.reminders,
            comments: c.comments,
            task_labels: c.task_labels,
            task_relations: c.task_relations,
        }
    }
}

impl From<dev_seed_api::DevSeedResult> for DevSeedResult {
    fn from(r: dev_seed_api::DevSeedResult) -> Self {
        Self {
            created: r.created.into(),
            cleared: r.cleared.into(),
            elapsed_ms: r.elapsed_ms,
        }
    }
}

impl From<dev_seed_api::DevSeedClearResult> for DevSeedClearResult {
    fn from(r: dev_seed_api::DevSeedClearResult) -> Self {
        Self {
            removed: r.removed.into(),
            elapsed_ms: r.elapsed_ms,
        }
    }
}

// ============================================================================
// 命令
// ============================================================================

/// 一键生成示例数据（先清上一批，不碰手工数据）
pub async fn dev_seed_demo_data(plan: DevSeedPlan) -> Result<DevSeedResult, String> {
    ensure_dev_build()?;
    let pool = pool()?;
    dev_seed_api::seed_demo_data(&pool, &dev_seed_api::DevSeedPlan { tasks: plan.tasks })
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
}

/// 清除示例数据（按 uuid 前缀物理删除）
pub async fn dev_seed_clear() -> Result<DevSeedClearResult, String> {
    ensure_dev_build()?;
    let pool = pool()?;
    dev_seed_api::clear_demo_data(&pool)
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
}
