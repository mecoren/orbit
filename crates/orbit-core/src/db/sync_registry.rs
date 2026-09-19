//! 同步/备份/导入白名单注册表 —— 唯一权威来源（03 文档 §六）
//!
//! todo 单模块：11 张 todo 业务表。
//! 改动此文件时必须同步核对 `cloud_sync::modules` 的 SYNC_MODULES 定义与测试断言。
//! （本文件替代 wait-home 中散落在 business_api / db_loader / import_api 的各自为政的常量。）

/// 云同步白名单（push 时逐条附 `_table` 路由标记；与 FULL_BACKUP_TABLES 保持一致）
pub const SYNCABLE_TABLES: &[&str] = &[
    "todo_projects",
    "todo_tasks",
    "todo_subtasks",
    "todo_labels",
    "todo_task_labels",
    "todo_comments",
    "todo_task_relations",
    "todo_reminders",
    // 任务-附件关联（07 排查报告后续批次：附件功能）；附件二进制走
    // assets/{hash}.orsync 内容寻址通道（cloud_sync/attachments.rs），不进表同步
    "todo_task_attachments",
    // 保存的筛选器（#35）：用户内容随库同步（对标 Apple Smart List）
    "todo_saved_filters",
    // 任务模板：用户内容随库同步（对标 Vikunja Templates / MS To Do 步骤列表）
    "todo_templates",
];

/// 全量备份包（.orfullsync）遍历导出的业务表白名单
pub const FULL_BACKUP_TABLES: &[&str] = SYNCABLE_TABLES;

/// 备份导入白名单 —— 已补齐 wait-home 版缺口（B 类小改）：
/// projects/subtasks/labels/comments/reminders 五张表在原版中导不进，现与备份对齐
pub const IMPORTABLE_TABLES: &[&str] = SYNCABLE_TABLES;

/// 子表 → (整数外键列, 父表)：云同步载荷必须为这些列附父行 uuid
///
/// 业务表的 `id` 是本地自增主键，跨设备无意义（第五轮探查 F47）：直接搬运
/// 远端 `task_id=1` 会在本端解析成**另一行**，且因本端恰有该 id 而**不触发**
/// `FOREIGN KEY constraint failed`——静默改父。故同步载荷按 uuid 传递父子关系，
/// 落库时再解析为本端 id。
///
/// **本常量顺序即 pull 的表遍历顺序要求**：父表必须排在子表之前，
/// 否则同一轮内子行先到、父行未到，外键无法解析。
/// 与 `0001_init.sql` 的 FOREIGN KEY 声明由
/// `sync_registry_tests::fk_map_matches_ddl` 对账（DDL 加了外键而此处没跟上即红）。
pub const SYNC_FK_COLUMNS: &[(&str, &[(&str, &str)])] = &[
    ("todo_tasks", &[("project_id", "todo_projects")]),
    ("todo_subtasks", &[("task_id", "todo_tasks")]),
    (
        "todo_task_labels",
        &[("task_id", "todo_tasks"), ("label_id", "todo_labels")],
    ),
    ("todo_comments", &[("task_id", "todo_tasks")]),
    (
        "todo_task_relations",
        &[("task_id", "todo_tasks"), ("other_task_id", "todo_tasks")],
    ),
    ("todo_reminders", &[("task_id", "todo_tasks")]),
    ("todo_task_attachments", &[("task_id", "todo_tasks")]),
];

/// 查表取整数外键列声明（无外键返回空切片）
pub fn fk_columns_of(table: &str) -> &'static [(&'static str, &'static str)] {
    SYNC_FK_COLUMNS
        .iter()
        .find(|(t, _)| *t == table)
        .map(|(_, cols)| *cols)
        .unwrap_or(&[])
}

/// 父表是否排在子表之前（pull 依赖序的前提；单测直接吃 SYNCABLE_TABLES 顺序）
pub fn fk_parent_order_ok() -> bool {
    let pos = |t: &str| SYNCABLE_TABLES.iter().position(|s| *s == t);
    SYNC_FK_COLUMNS
        .iter()
        .all(|(child, cols)| match pos(child) {
            None => false,
            Some(c) => cols
                .iter()
                .all(|(_, parent)| pos(parent).is_some_and(|p| p < c)),
        })
}

#[cfg(test)]
mod sync_registry_tests {
    use super::*;
    use sqlx::Row;

    /// F47 对账：`SYNC_FK_COLUMNS` 必须与 `0001_init.sql` 落库后的真实外键一致
    ///
    /// 走 `PRAGMA foreign_key_list`（sqlite_master 里的 DDL 才是真相），
    /// 双向比对：加外键忘了登记 → 红；登记了但 DDL 没有 → 红。
    #[tokio::test]
    async fn fk_map_matches_ddl() {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("./src/db/migrations")
            .run(&pool)
            .await
            .expect("迁移");

        let mut ddl: std::collections::BTreeSet<String> = Default::default();
        for table in SYNCABLE_TABLES {
            let rows = sqlx::query(&format!("PRAGMA foreign_key_list(\"{table}\")"))
                .fetch_all(&pool)
                .await
                .unwrap();
            for r in rows {
                let col: String = r.try_get("from").unwrap();
                let parent: String = r.try_get("table").unwrap();
                // 只登记指向同步白名单内的外键（cfg_* 等配置表不参与同步）
                if SYNCABLE_TABLES.contains(&parent.as_str()) {
                    ddl.insert(format!("{table}.{col}->{parent}"));
                }
            }
        }

        let declared: std::collections::BTreeSet<String> = SYNC_FK_COLUMNS
            .iter()
            .flat_map(|(child, cols)| {
                cols.iter()
                    .map(move |(col, parent)| format!("{child}.{col}->{parent}"))
            })
            .collect();

        assert_eq!(
            declared, ddl,
            "SYNC_FK_COLUMNS 与 DDL 外键不一致（漏登记会静默改父，多登记会误判载荷格式）"
        );
        assert!(
            fk_parent_order_ok(),
            "SYNCABLE_TABLES 顺序必须是父表先于子表（pull 据此定序）"
        );
    }

    #[test]
    fn fk_columns_of_returns_empty_for_leaf_tables() {
        assert_eq!(fk_columns_of("todo_projects"), &[] as &[(&str, &str)]);
        assert_eq!(fk_columns_of("不存在的表"), &[] as &[(&str, &str)]);
        assert_eq!(fk_columns_of("todo_subtasks").len(), 1);
        assert_eq!(fk_columns_of("todo_task_relations").len(), 2);
    }
}
