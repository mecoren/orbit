//! changelog — 应用内更新日志只读 API（双端唯一数据源）
//!
//! 口径：
//! - 数据内联在 `models::changelog::data`（编译期静态，**零 DB / 零网络 / 不 emit 事件**），
//!   桌面 Tauri command 与移动 FRB 桥同名 `changelog_versions` 转发，壳层只渲染；
//! - 只读聚合不进同步白名单，也不改 `sync_registry.rs`；
//! - 仓库根 `CHANGELOG.md` 与这里的分工见 `models::changelog` 模块注释（发版两份同提交）。
use crate::models::changelog::{self, ChangelogVersion};

/// 全部已发布版本的更新日志（新版本在前；只读静态数据）
pub fn changelog_versions() -> Vec<ChangelogVersion> {
    changelog::all()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 手工校验 YYYY-MM-DD（不为一处格式引入 regex 依赖）
    fn is_iso_date(s: &str) -> bool {
        let b = s.as_bytes();
        b.len() == 10
            && b[4] == b'-'
            && b[7] == b'-'
            && b[..4].iter().all(u8::is_ascii_digit)
            && b[5..7].iter().all(u8::is_ascii_digit)
            && b[8..].iter().all(u8::is_ascii_digit)
    }

    #[test]
    fn head_version_matches_package_version() {
        let all = changelog_versions();
        assert!(!all.is_empty(), "更新日志至少要有首个版本条目");
        assert_eq!(
            all[0].version,
            env!("CARGO_PKG_VERSION"),
            "更新日志头部版本必须等于 workspace 版本（pnpm bump 后同步补条目）"
        );
    }

    #[test]
    fn entries_have_valid_shape() {
        for entry in changelog_versions() {
            assert!(
                entry.version.split('.').count() == 3
                    && entry.version.split('.').all(|p| p.parse::<u32>().is_ok()),
                "版本号必须是 x.y.z：{}",
                entry.version
            );
            assert!(
                is_iso_date(&entry.date),
                "日期必须是 YYYY-MM-DD：{}",
                entry.date
            );
            assert!(
                !entry.summary.trim().is_empty(),
                "{} 缺少 summary",
                entry.version
            );
            assert!(!entry.changes.is_empty(), "{} 缺少 changes", entry.version);
            for change in &entry.changes {
                assert!(
                    !change.description.trim().is_empty(),
                    "{} 存在空变更描述",
                    entry.version
                );
            }
        }
    }
}
