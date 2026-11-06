//! changelog — 应用内更新日志的结构化模型（双端唯一数据源）
//!
//! 分工口径（docs/08 §3.2）：
//! - 本模块（`data.rs` 内联常量）是**应用内**「关于 → 更新日志」的唯一源，
//!   桌面 Tauri 命令与移动 FRB 桥同名转发，壳层只做中文标签/图标映射；
//! - 仓库根 `CHANGELOG.md` 仍是仓库/GitHub 面的详细记录，发版时两份同一次提交
//!   一起补（只写一处会让应用内关于页永久缺失该版本，qraft 0.2.7 教训）；
//! - 头部版本必须等于 `apps/desktop/package.json#version`：本模块单测
//!   `head_version_matches_package_version` 与 `release-consistency.test.ts` 双重校验。
//!
//! 提炼口径：`git log v<上一 tag>..HEAD --oneline` 按功能合并同类提交，
//! 忽略 docs/chore/style 等过程性噪声；只写已发布版本，不写 `Unreleased`。
use serde::Serialize;

pub mod data;

/// 变更分类（前端映射中文标签与徽标色，串值稳定勿改名）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ChangelogCategory {
    Feature,
    Fix,
    Refactor,
    Chore,
}

impl ChangelogCategory {
    /// 稳定串值（与 serde `snake_case` 输出一致，FRB 桥镜像用）
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Feature => "feature",
            Self::Fix => "fix",
            Self::Refactor => "refactor",
            Self::Chore => "chore",
        }
    }
}

/// 单条变更
#[derive(Debug, Clone, Serialize)]
pub struct ChangelogEntry {
    pub category: ChangelogCategory,
    pub description: String,
}

/// 单个版本的更新日志（新版本在前）
#[derive(Debug, Clone, Serialize)]
pub struct ChangelogVersion {
    pub version: String,
    /// 发布日期（YYYY-MM-DD）
    pub date: String,
    pub summary: String,
    pub changes: Vec<ChangelogEntry>,
}

/// 全部已发布版本（克隆返回，调用方无法改写静态数据）
pub fn all() -> Vec<ChangelogVersion> {
    data::ALL_VERSIONS.clone()
}
