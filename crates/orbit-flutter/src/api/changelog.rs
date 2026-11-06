//! changelog — 移动端桥接层「更新日志」域
//!
//! 数据源在 `orbit_core::models::changelog::data`（双端唯一），本文件只做 DTO 镜像：
//! 不直接暴露 core 类型（保持两端壳独立演进），字段与桌面
//! `commands/changelog_cmd.rs` 的 serde 输出一一对应（category 为
//! `feature` / `fix` / `refactor` / `chore`，Dart 侧映射中文标签）。
use orbit_core::api::changelog_api;
use serde::Serialize;

/// 单条变更（镜像 `orbit_core::models::changelog::ChangelogEntry`）
#[derive(Debug, Clone, Serialize)]
pub struct ChangelogEntryDto {
    /// 分类串值：feature / fix / refactor / chore
    pub category: String,
    pub description: String,
}

/// 单个版本（镜像 `orbit_core::models::changelog::ChangelogVersion`）
#[derive(Debug, Clone, Serialize)]
pub struct ChangelogVersionDto {
    pub version: String,
    /// 发布日期（YYYY-MM-DD）
    pub date: String,
    pub summary: String,
    pub changes: Vec<ChangelogEntryDto>,
}

/// 全部已发布版本的更新日志（新版本在前；只读静态数据）
pub fn changelog_versions() -> Vec<ChangelogVersionDto> {
    changelog_api::changelog_versions()
        .into_iter()
        .map(|version| ChangelogVersionDto {
            version: version.version,
            date: version.date,
            summary: version.summary,
            changes: version
                .changes
                .into_iter()
                .map(|change| ChangelogEntryDto {
                    category: change.category.as_str().to_string(),
                    description: change.description,
                })
                .collect(),
        })
        .collect()
}
