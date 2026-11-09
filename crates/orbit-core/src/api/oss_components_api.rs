//! oss_components — 开源组件引用清单只读 API（双端唯一数据源）
//!
//! 口径：
//! - 数据内联在 `models::oss_components::data`（编译期静态，**零 DB / 零网络 / 不 emit 事件**），
//!   桌面 Tauri command 与移动 FRB 桥同名 `oss_components` 转发，壳层只负责展示；
//! - 只读聚合不进同步白名单，也不改 `sync_registry.rs`；
//! - 清单只覆盖仓库直接依赖（npm / Rust / Flutter），不含间接依赖与 dev_dependencies。
use crate::models::oss_components::{self, OssComponent};

/// 全部开源组件（只读静态数据；默认顺序 = 前端 → Rust → Flutter）
pub fn oss_components() -> Vec<OssComponent> {
    oss_components::all()
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use crate::models::oss_components::OssComponentSource;

    #[test]
    fn names_are_unique() {
        let all = super::oss_components();
        assert!(!all.is_empty(), "开源组件清单不能为空");

        let mut seen = HashSet::new();
        for component in &all {
            assert!(
                seen.insert(component.name.clone()),
                "组件名重复：{}",
                component.name
            );
        }
    }

    #[test]
    fn all_sources_have_entries() {
        let all = super::oss_components();
        for source in [
            OssComponentSource::Frontend,
            OssComponentSource::Rust,
            OssComponentSource::Flutter,
        ] {
            assert!(
                all.iter().any(|component| component.source == source),
                "缺少来源为 {source:?} 的组件条目"
            );
        }
    }

    #[test]
    fn entries_have_valid_shape() {
        for component in super::oss_components() {
            assert!(
                !component.name.trim().is_empty(),
                "组件名不能为空（source={:?}）",
                component.source
            );
            assert!(
                !component.version.trim().is_empty(),
                "{} 缺少版本",
                component.name
            );
            assert!(
                !component.description.trim().is_empty(),
                "{} 缺少说明",
                component.name
            );
            assert!(
                !component.license.trim().is_empty(),
                "{} 缺少许可证",
                component.name
            );
            for (label, link) in [
                ("仓库", component.repository.as_deref()),
                ("主页", component.homepage.as_deref()),
            ] {
                if let Some(link) = link {
                    assert!(
                        !link.trim().is_empty(),
                        "{} 的{label}链接为空",
                        component.name
                    );
                    assert!(
                        link.starts_with("https://"),
                        "{} 的{label}链接必须是 https：{}",
                        component.name,
                        link
                    );
                }
            }
        }
    }

    #[test]
    fn default_order_groups_sources() {
        let all = super::oss_components();
        let last_frontend = all
            .iter()
            .rposition(|component| component.source == OssComponentSource::Frontend)
            .expect("缺少前端组件");
        let first_rust = all
            .iter()
            .position(|component| component.source == OssComponentSource::Rust)
            .expect("缺少 Rust 组件");
        let first_flutter = all
            .iter()
            .position(|component| component.source == OssComponentSource::Flutter)
            .expect("缺少 Flutter 组件");

        assert!(
            last_frontend < first_rust,
            "默认顺序必须先排前端组件，再排 Rust 组件"
        );
        assert!(
            first_rust < first_flutter,
            "默认顺序必须先排 Rust 组件，再排 Flutter 组件"
        );
    }
}
