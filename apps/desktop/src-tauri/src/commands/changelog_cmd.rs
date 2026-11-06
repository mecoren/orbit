//! changelog_cmd — 应用内更新日志命令面
//!
//! 数据源在 `orbit_core::models::changelog::data`（双端唯一），本文件只是薄转发：
//! 不读 DB、不 emit 事件、不进同步白名单。移动端同名 FRB 函数见
//! `crates/orbit-flutter/src/api/changelog.rs`。
use orbit_core::api::changelog_api;
use orbit_core::models::changelog::ChangelogVersion;

/// 全部已发布版本的更新日志（新版本在前）
#[tauri::command]
pub fn changelog_versions() -> Vec<ChangelogVersion> {
    changelog_api::changelog_versions()
}
