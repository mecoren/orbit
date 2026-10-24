//! project_review_api — 项目回顾节奏（F1，对标 OmniFocus Review，docs/13 §五 F1）
//!
//! 口径与约束：
//! - **日界**：到期/逾期按本地时区日序号（days since epoch，复用
//!   [stats_api::local_day_index] 的 `num_days_from_ce` 单调换算），不在 SQL 里
//!   按 UTC 天分组；`now_ms` 由壳层传入（桌面 `Date.now()` / 移动
//!   `DateTime.now().millisecondsSinceEpoch`），写入时间戳走
//!   [crate::db::clock::next_ms]（HLC 单调，LWW 同步裁决键）。
//! - **同步面**：三列挂在 todo_projects（已在 SYNCABLE_TABLES），随整行同步，
//!   白名单/模块计数零变更；NULL = 未设置的列驱动合并语义见 0008 迁移头注释。
//! - **只读归集不 emit 事件**（[list_projects_due_for_review] 纯查询）；
//!   写路径（标记已回顾/设置周期/暂缓）经 generic_repo::update_todo_project，
//!   由其统一 emit db-change（前端缓存失效链依赖它）。

use serde::Serialize;
use sqlx::SqlitePool;

use crate::api::digest_api::local_day_start;
use crate::api::stats_api::local_day_index;
use crate::db::clock;
use crate::db::repository::generic_repo;
use crate::error::{CoreError, CoreResult};
use crate::models::business::{TodoProject, TodoProjectUpdateInput};

/// 回顾状态行（回顾中心列表与「待回顾」徽标共用形状）
#[derive(Debug, Clone, Serialize)]
pub struct ProjectReviewStatus {
    pub project: TodoProject,
    /// 到期日序号（days since epoch，本地时区日界）
    pub due_day_index: i64,
    /// 已逾期天数（0 = 今天到期；排序键，越大越久没回顾）
    pub overdue_days: i64,
    /// 项目内未完成且未软删的任务数（回顾中心行内提示「还有 N 件待处理」）
    pub open_task_count: i64,
}

/// 计算项目的回顾到期日序号；`None` = 回顾关闭。
///
/// 纯函数（整数日域，不触库不触「现在」）：
/// - 周期关闭（`review_interval_days` 缺失或 ≤0）→ `None`；
/// - 从未回顾（`review_last_at` 为 NULL）→ `today_index`（立即到期）——
///   开启了周期却从未走过回顾的项目最需要被看见；
/// - 否则到期 = 上次回顾日 + 周期天数；
/// - 暂缓只往后推：到期取 `max(周期到期, 暂缓日)`，暂缓日早于周期到期时不生效。
pub fn review_due_day_index(project: &TodoProject, today_index: i64) -> Option<i64> {
    let interval = project.review_interval_days?;
    if interval <= 0 {
        return None;
    }
    let base = match project.review_last_at {
        Some(last_ms) => local_day_index(last_ms) + interval,
        None => today_index,
    };
    let due = match project.review_snooze_until {
        Some(until_ms) => base.max(local_day_index(until_ms)),
        None => base,
    };
    Some(due)
}

/// 待回顾项目清单：未软删、未归档、周期开启且已到期（到期日 ≤ 今天），
/// 按逾期天数降序（最久没回顾的排最前），同逾期按标题稳定排序。
pub async fn list_projects_due_for_review(
    pool: &SqlitePool,
    now_ms: i64,
) -> CoreResult<Vec<ProjectReviewStatus>> {
    let today_index = local_day_index(now_ms);
    // fetch_all 无 LIMIT：todo_projects 天然有界（用户级项目数，几十~几百行）
    let projects = sqlx::query_as::<_, TodoProject>(
        "SELECT * FROM todo_projects \
         WHERE is_deleted = 0 AND is_archived = 0 AND COALESCE(review_interval_days, 0) > 0 \
         ORDER BY sort_order ASC, id ASC",
    )
    .fetch_all(pool)
    .await?;
    if projects.is_empty() {
        return Ok(Vec::new());
    }
    // 未完成计数单遍聚合（GROUP BY 结果天然有界于项目数），避免逐项目 COUNT
    let counts: Vec<(Option<i64>, i64)> = sqlx::query_as(
        "SELECT project_id, COUNT(*) FROM todo_tasks \
         WHERE project_id IS NOT NULL AND is_deleted = 0 AND done = 0 \
         GROUP BY project_id",
    )
    .fetch_all(pool)
    .await?;
    let count_map: std::collections::HashMap<i64, i64> = counts
        .into_iter()
        .filter_map(|(k, v)| k.map(|k| (k, v)))
        .collect();

    let mut due: Vec<ProjectReviewStatus> = projects
        .into_iter()
        .filter_map(|project| {
            let due_day_index = review_due_day_index(&project, today_index)?;
            if due_day_index > today_index {
                return None;
            }
            let overdue_days = (today_index - due_day_index).max(0);
            let open_task_count = count_map.get(&project.id).copied().unwrap_or(0);
            Some(ProjectReviewStatus {
                project,
                due_day_index,
                overdue_days,
                open_task_count,
            })
        })
        .collect();
    due.sort_by(|a, b| {
        b.overdue_days
            .cmp(&a.overdue_days)
            .then_with(|| a.project.title.cmp(&b.project.title))
    });
    Ok(due)
}

/// 标记项目已回顾：`review_last_at = now`（HLC），并清空暂缓——
/// 下次到期 = 今天 + 周期，旧暂缓日期残留会把到期错误推后。
pub async fn mark_project_reviewed(pool: &SqlitePool, project_id: i64) -> CoreResult<TodoProject> {
    let input = TodoProjectUpdateInput {
        review_last_at: Some(Some(clock::next_ms())),
        review_snooze_until: Some(None),
        ..Default::default()
    };
    generic_repo::update_todo_project(pool, project_id, &input).await
}

/// 设置项目回顾周期：`days` 缺失或 ≤0 = 关闭。
///
/// - **开启时若从未回顾过**，顺带把 `review_last_at` 落为 now——首次到期 =
///   设定日 + 周期，而非「立即到期」（OmniFocus 同款口径：周期从设定那刻起算，
///   避免用户刚开开关就被到期徽标轰炸）；
/// - **开启时清残留暂缓**：重开周期应按周期起算，不被旧暂缓日期拦住；
/// - **关闭时保留 `review_last_at`** 作历史（重开后按「上次回顾 + 周期」起算，
///   若已过期则如实到期）；残留暂缓一并清空。
pub async fn set_project_review_interval(
    pool: &SqlitePool,
    project_id: i64,
    days: Option<i64>,
) -> CoreResult<TodoProject> {
    let project: TodoProject = generic_repo::get_by_id(pool, "todo_projects", project_id).await?;
    let mut input = TodoProjectUpdateInput::default();
    match days.filter(|d| *d > 0) {
        Some(d) => {
            input.review_interval_days = Some(Some(d));
            if project.review_last_at.is_none() {
                input.review_last_at = Some(Some(clock::next_ms()));
            }
        }
        None => {
            input.review_interval_days = Some(None);
        }
    }
    if project.review_snooze_until.is_some() {
        input.review_snooze_until = Some(None);
    }
    generic_repo::update_todo_project(pool, project_id, &input).await
}

/// 暂缓项目回顾：到期推到「今天 + `days` 天」（暂缓日本地零点毫秒落库）。
///
/// 只推迟不重置周期——标记已回顾后暂缓自动失效（mark 会清空本列）。
pub async fn snooze_project_review(
    pool: &SqlitePool,
    project_id: i64,
    days: i64,
    now_ms: i64,
) -> CoreResult<TodoProject> {
    if days <= 0 {
        return Err(CoreError::Other("暂缓天数必须为正整数".into()));
    }
    let until_ms = local_day_start(now_ms) + days * 86_400_000;
    let input = TodoProjectUpdateInput {
        review_snooze_until: Some(Some(until_ms)),
        ..Default::default()
    };
    generic_repo::update_todo_project(pool, project_id, &input).await
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod review_due_day_index_tests {
    use super::*;

    fn proj(interval: Option<i64>, last_ms: Option<i64>, snooze_ms: Option<i64>) -> TodoProject {
        TodoProject {
            id: 1,
            uuid: "u".into(),
            title: "t".into(),
            description: None,
            hex_color: "#3B82F6".into(),
            sort_order: 0.0,
            parent_uuid: None,
            review_interval_days: interval,
            review_last_at: last_ms,
            review_snooze_until: snooze_ms,
            is_archived: 0,
            is_deleted: 0,
            created_at: 0,
            updated_at: 0,
            deleted_at: None,
            version: 1,
        }
    }

    /// 本地某天正午的毫秒时间戳（基点固定：正午 ±1h 的 DST 漂移不会跨出当天，
    /// 整数天步进的日序号在任意时区/任意测试日期下都确定）
    fn noon_ms(days_from_base: i64) -> i64 {
        let base_noon = local_day_start(1_800_000_000_000) + 12 * 3_600_000;
        base_noon + days_from_base * 86_400_000
    }

    #[test]
    fn closed_when_missing_or_non_positive() {
        let today = local_day_index(noon_ms(0));
        assert_eq!(review_due_day_index(&proj(None, None, None), today), None);
        assert_eq!(
            review_due_day_index(&proj(Some(0), None, None), today),
            None
        );
        assert_eq!(
            review_due_day_index(&proj(Some(-7), None, None), today),
            None
        );
    }

    #[test]
    fn never_reviewed_is_due_today() {
        let today = local_day_index(noon_ms(0));
        assert_eq!(
            review_due_day_index(&proj(Some(7), None, None), today),
            Some(today)
        );
    }

    #[test]
    fn due_is_last_review_day_plus_interval() {
        let today = local_day_index(noon_ms(0));
        // 上次回顾在 3 天前正午、周期 7：到期 = (today-3) + 7 = today + 4
        let last = noon_ms(-3);
        assert_eq!(
            review_due_day_index(&proj(Some(7), Some(last), None), today),
            Some(today + 4)
        );
    }

    #[test]
    fn snooze_pushes_due_later_not_earlier() {
        let today = local_day_index(noon_ms(0));
        let last = noon_ms(-10); // 周期 7：周期到期 = today - 3
        // 暂缓到 5 天后：到期 = max(today-3, today+5) = today + 5
        let snooze = noon_ms(5);
        assert_eq!(
            review_due_day_index(&proj(Some(7), Some(last), Some(snooze)), today),
            Some(today + 5)
        );
        // 暂缓日早于周期到期时不生效：max(today-3, today-9) = today - 3
        let stale = noon_ms(-9);
        assert_eq!(
            review_due_day_index(&proj(Some(7), Some(last), Some(stale)), today),
            Some(today - 3)
        );
    }
}

#[cfg(test)]
mod api_tests {
    use super::*;
    use crate::models::business::TodoProjectCreateInput;

    async fn setup_db() -> SqlitePool {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .unwrap();
        pool
    }

    async fn mk_project(pool: &SqlitePool, title: &str) -> TodoProject {
        business_api_create(pool, title).await
    }

    async fn business_api_create(pool: &SqlitePool, title: &str) -> TodoProject {
        crate::api::business_api::create_todo_project(
            pool,
            &TodoProjectCreateInput {
                title: title.into(),
                description: None,
                hex_color: None,
                sort_order: None,
                parent_uuid: None,
            },
        )
        .await
        .unwrap()
    }

    async fn mk_task(pool: &SqlitePool, project_id: i64, title: &str, done: i32) {
        sqlx::query("INSERT INTO todo_tasks (uuid, title, project_id, done, is_deleted, created_at, updated_at, version) VALUES (?, ?, ?, ?, 0, 1, 1, 1)")
            .bind(format!("t-{title}"))
            .bind(title)
            .bind(project_id)
            .bind(done)
            .execute(pool)
            .await
            .unwrap();
    }

    fn now_ms() -> i64 {
        chrono::Utc::now().timestamp_millis()
    }

    /// 把项目的上次回顾时间直接改到 N 天前正午（绕过 API，模拟时间流逝）
    async fn backdate_last_review(pool: &SqlitePool, project_id: i64, days_ago: i64) {
        let noon = local_day_start(now_ms()) + 12 * 3_600_000;
        sqlx::query("UPDATE todo_projects SET review_last_at = ? WHERE id = ?")
            .bind(noon - days_ago * 86_400_000)
            .bind(project_id)
            .execute(pool)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn enable_then_not_due_until_interval_passes() {
        let pool = setup_db().await;
        let p = mk_project(&pool, "A").await;
        let now = now_ms();

        // 关闭态不在清单
        assert!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .is_empty()
        );

        // 开启周期 7 天：从未回顾 → last_at 自动落 now，首次到期 = 7 天后
        let updated = set_project_review_interval(&pool, p.id, Some(7))
            .await
            .unwrap();
        assert!(updated.review_interval_days == Some(7));
        assert!(updated.review_last_at.is_some());
        assert!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .is_empty()
        );

        // 时间过了 8 天（上次回顾回拨到 8 天前）：到期日 = 上次 + 7 < 今天 → 逾期 1 天
        backdate_last_review(&pool, p.id, 8).await;
        let due = list_projects_due_for_review(&pool, now).await.unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].project.id, p.id);
        assert_eq!(due[0].overdue_days, 1);

        // 标记已回顾：徽标消失，暂缓清空
        let reviewed = mark_project_reviewed(&pool, p.id).await.unwrap();
        assert!(reviewed.review_snooze_until.is_none());
        assert!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn snooze_hides_until_snooze_day() {
        let pool = setup_db().await;
        let p = mk_project(&pool, "A").await;
        let now = now_ms();
        set_project_review_interval(&pool, p.id, Some(7))
            .await
            .unwrap();
        backdate_last_review(&pool, p.id, 30).await;
        assert_eq!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .len(),
            1
        );

        // 稍后一周：今天不再到期；第 8 天（now + 8 天视角）重新到期
        snooze_project_review(&pool, p.id, 7, now).await.unwrap();
        assert!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .is_empty()
        );
        // 从今天正午起加 8 整天：now 的钟点跨 DST 边界时 ±1h 不会把日序号推出目标日
        let later = local_day_start(now) + 12 * 3_600_000 + 8 * 86_400_000;
        let due = list_projects_due_for_review(&pool, later).await.unwrap();
        assert_eq!(due.len(), 1, "暂缓日过后按暂缓日到期");
        assert_eq!(
            due[0].overdue_days, 1,
            "now+8d 视角下暂缓日(now+7d)已过 1 天"
        );

        // 非法天数拒绝
        assert!(snooze_project_review(&pool, p.id, 0, now).await.is_err());
    }

    #[tokio::test]
    async fn disable_clears_interval_keeps_history() {
        let pool = setup_db().await;
        let p = mk_project(&pool, "A").await;
        let now = now_ms();
        set_project_review_interval(&pool, p.id, Some(7))
            .await
            .unwrap();
        backdate_last_review(&pool, p.id, 30).await;
        snooze_project_review(&pool, p.id, 7, now).await.unwrap();

        // 关闭：周期与暂缓清空，last_at 保留作历史
        let off = set_project_review_interval(&pool, p.id, None)
            .await
            .unwrap();
        assert_eq!(off.review_interval_days, None);
        assert_eq!(off.review_snooze_until, None);
        assert!(off.review_last_at.is_some());
        assert!(
            list_projects_due_for_review(&pool, now)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn list_sorts_by_overdue_desc_and_counts_open_tasks() {
        let pool = setup_db().await;
        let a = mk_project(&pool, "A").await;
        let b = mk_project(&pool, "B").await;
        let c = mk_project(&pool, "C").await;
        let now = now_ms();
        for (p, days) in [(a.id, 30i64), (b.id, 10), (c.id, 20)] {
            set_project_review_interval(&pool, p, Some(7))
                .await
                .unwrap();
            backdate_last_review(&pool, p, days).await;
        }
        // C 归档后不出现在清单
        sqlx::query("UPDATE todo_projects SET is_archived = 1 WHERE id = ?")
            .bind(c.id)
            .execute(&pool)
            .await
            .unwrap();
        // A：2 未完成 + 1 已完成 + 1 软删 → 计数只算未完成未删
        mk_task(&pool, a.id, "a1", 0).await;
        mk_task(&pool, a.id, "a2", 0).await;
        mk_task(&pool, a.id, "a3", 1).await;
        sqlx::query("UPDATE todo_tasks SET is_deleted = 1 WHERE title = 'a2'")
            .execute(&pool)
            .await
            .unwrap();

        let due = list_projects_due_for_review(&pool, now).await.unwrap();
        let ids: Vec<i64> = due.iter().map(|s| s.project.id).collect();
        // A 上次 30 天前（逾期 23）> B 上次 10 天前（逾期 3）；归档 C 不在
        assert_eq!(ids, vec![a.id, b.id]);
        assert_eq!(due[0].overdue_days, 23);
        assert_eq!(due[0].open_task_count, 1, "只计未完成未软删：a1");
    }

    #[tokio::test]
    async fn null_last_at_with_interval_set_is_due_immediately() {
        // 同步对端写入「周期已开但从未回顾」的行（绕过本端 set 入口）：
        // 立即到期且逾期 0 天（今天到期）
        let pool = setup_db().await;
        let p = mk_project(&pool, "A").await;
        sqlx::query("UPDATE todo_projects SET review_interval_days = 14 WHERE id = ?")
            .bind(p.id)
            .execute(&pool)
            .await
            .unwrap();
        let due = list_projects_due_for_review(&pool, now_ms()).await.unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].overdue_days, 0);
    }
}
