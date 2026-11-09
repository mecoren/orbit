//! oss_components — 移动端桥接层「开源组件」域
//!
//! 数据源在 `orbit_core::models::oss_components::data`（双端唯一），本文件只做
//! DTO 镜像：不直接暴露 core 类型（保持两端壳独立演进），字段与桌面
//! `commands/oss_components_cmd.rs` 的 serde 输出一一对应（source 为
//! `frontend` / `rust` / `flutter`，Dart 侧映射中文标签）。
use orbit_core::api::oss_components_api;
use serde::Serialize;

/// 单个开源组件（镜像 `orbit_core::models::oss_components::OssComponent`）
#[derive(Debug, Clone, Serialize)]
pub struct OssComponentDto {
    pub name: String,
    pub version: String,
    /// 来源串值：frontend / rust / flutter
    pub source: String,
    pub description: String,
    pub license: String,
    pub repository: Option<String>,
    pub homepage: Option<String>,
}

/// 全部开源组件（只读静态数据；默认顺序 = 前端 → Rust → Flutter）
pub fn oss_components() -> Vec<OssComponentDto> {
    oss_components_api::oss_components()
        .into_iter()
        .map(|component| OssComponentDto {
            name: component.name,
            version: component.version,
            source: component.source.as_str().to_string(),
            description: component.description,
            license: component.license,
            repository: component.repository,
            homepage: component.homepage,
        })
        .collect()
}
