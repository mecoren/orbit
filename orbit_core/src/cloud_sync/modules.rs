//! modules — 云端同步模块定义
//!
//! Orbit MVP 仅注册单一同步单元 `todos`（03 文档 §六）：
//! 模块是同步的最小指纹/上传/下载单元，附件走独立的内容寻址路径（media/<sha256>）。
//!
//! 与 `db::sync_registry` 的关系：
//! - SYNCABLE_TABLES / FULL_BACKUP_TABLES / IMPORTABLE_TABLES 是表级白名单（唯一权威来源）
//! - SYNC_MODULES 是增量同步的模块视图；todos 模块覆盖全部 8 张可同步表

/// 同步模块定义
///
/// `tables` 的第一张表是主表（用于 item 级合并的 uuid 比对），
/// 后续表是关联表。
#[derive(Debug, Clone, Copy)]
pub struct SyncModuleDef {
    /// 模块名（英文，作为云端目录名）
    pub name: &'static str,
    /// 显示名（中文，用于 UI 进度提示）
    pub display_name: &'static str,
    /// 关联的数据库表（第一张为主表）
    pub tables: &'static [&'static str],
    /// 是否包含附件（true → 扫描 attachments 字段收集 sha256）
    pub has_attachments: bool,
}

impl SyncModuleDef {
    /// 主表名（tables[0]）
    pub fn primary_table(&self) -> &'static str {
        self.tables
            .first()
            .copied()
            .expect("SyncModuleDef.tables must not be empty")
    }
}

/// 同步模块静态注册表（Orbit MVP：单模块）
///
/// 顺序影响 Push/Pull 遍历顺序与进度条显示；未来新增模块在此追加。
pub const SYNC_MODULES: &[SyncModuleDef] = &[
    SyncModuleDef {
        name: "todos",
        display_name: "待办数据",
        tables: &[
            "todo_projects",
            "todo_tasks",
            "todo_subtasks",
            "todo_labels",
            "todo_task_labels",
            "todo_comments",
            "todo_task_relations",
            "todo_reminders",
        ],
        // R10.7 沿革：todo 模块不接入附件（01 文档 §3.3：attachments/ 仅预留）
        has_attachments: false,
    },
];

/// 按名称查找模块定义
pub fn find_module(name: &str) -> Option<&'static SyncModuleDef> {
    SYNC_MODULES.iter().find(|m| m.name == name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::sync_registry::SYNCABLE_TABLES;
    use std::collections::HashSet;

    #[test]
    fn module_count_is_one() {
        assert_eq!(SYNC_MODULES.len(), 1, "MVP 必须恰好 1 个模块（todos）");
    }

    #[test]
    fn module_names_are_unique() {
        let mut seen = HashSet::new();
        for m in SYNC_MODULES {
            assert!(seen.insert(m.name), "重复的模块名: {}", m.name);
        }
    }

    #[test]
    fn module_tables_not_empty() {
        for m in SYNC_MODULES {
            assert!(!m.tables.is_empty(), "模块 {} 的 tables 不能为空", m.name);
        }
    }

    #[test]
    fn primary_table_returns_first() {
        let m = find_module("todos").unwrap();
        assert_eq!(m.primary_table(), "todo_projects");
    }

    #[test]
    fn find_module_returns_none_for_unknown() {
        assert!(find_module("nonexistent").is_none());
    }

    #[test]
    fn find_module_returns_def_for_known() {
        let m = find_module("todos").unwrap();
        assert_eq!(m.display_name, "待办数据");
        assert_eq!(m.primary_table(), "todo_projects");
    }

    /// 核心不变量：SYNC_MODULES 覆盖的表集合必须与白名单注册表完全一致
    #[test]
    fn modules_match_syncable_tables_exactly() {
        let mut module_tables: HashSet<&str> =
            SYNC_MODULES.iter().flat_map(|m| m.tables.iter().copied()).collect();

        let registry: HashSet<&str> = SYNCABLE_TABLES.iter().copied().collect();

        let missing: Vec<&str> = registry.difference(&module_tables).copied().collect();
        assert!(missing.is_empty(), "白名单中的表未被任何模块覆盖: {missing:?}");

        let extra: Vec<&str> = module_tables.drain().filter(|t| !registry.contains(t)).collect();
        assert!(extra.is_empty(), "模块声明了白名单之外的表: {extra:?}");
    }
}
