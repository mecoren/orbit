//! search — 移动端桥接层全局搜索域（backlog #26）
//!
//! 与桌面壳命令一一对应（业务在 orbit_core::api::business_api::search_all）：
//! - global_search → 桌面 global_search：任务/项目/评论三路 LIKE 聚合。
//!
//! DTO 镜像模式：任务/项目行复用 [super::dto] 的镜像类型；CommentSearchHit
//! 为本模块本地 DTO（同 [super::stats] 规则——core Serialize 结构不直接
//! 过桥）。只读聚合，不 emit 事件。

use orbit_core::api::business_api;
use serde::Serialize;

pub use super::dto::{TodoProject, TodoTask};

/// 评论命中行（镜像 core CommentSearchHit）
#[derive(Debug, Clone, Serialize)]
pub struct CommentSearchHit {
    pub comment_id: i64,
    pub task_id: i64,
    pub task_title: String,
    pub content: String,
    pub created_at: i64,
}

/// 三路聚合结果（镜像 core GlobalSearchResult）
#[derive(Debug, Clone, Serialize, Default)]
pub struct GlobalSearchResult {
    pub tasks: Vec<TodoTask>,
    pub projects: Vec<TodoProject>,
    pub comments: Vec<CommentSearchHit>,
}

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// 全局搜索（任务/项目/评论三路 LIKE；空关键词返回空结果；limit ≤0 → 20）
pub async fn global_search(keyword: String, limit: Option<i32>) -> Result<GlobalSearchResult, String> {
    let pool = pool()?;
    let r = business_api::search_all(&pool, &keyword, limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())?;
    Ok(GlobalSearchResult {
        tasks: r.tasks.into_iter().map(Into::into).collect(),
        projects: r.projects.into_iter().map(Into::into).collect(),
        comments: r
            .comments
            .into_iter()
            .map(|c| CommentSearchHit {
                comment_id: c.comment_id,
                task_id: c.task_id,
                task_title: c.task_title,
                content: c.content,
                created_at: c.created_at,
            })
            .collect(),
    })
}
