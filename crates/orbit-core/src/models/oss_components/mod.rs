//! oss_components — 开源组件引用清单（双端唯一数据源）
//!
//! 分工口径与 `models::changelog` 一致：
//! - 本模块（`data.rs` 内联常量）是应用内「关于 → 开源组件」的唯一源，
//!   桌面 Tauri 命令与移动 FRB 桥同名转发，壳层只做来源标签与排序展示；
//! - 清单只覆盖仓库直接依赖（npm / Rust / Flutter），不含间接依赖与
//!   `dev_dependencies`；本地 path 依赖（`rust_lib_orbit`）不列入；
//! - 数据是编译期静态常量，**零 DB / 零网络 / 不 emit 事件**，也不进同步白名单。
use serde::Serialize;

pub mod data;

/// 组件来源（串值稳定，前端/移动端直接消费；勿改名）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OssComponentSource {
    /// 桌面前端 npm 依赖
    Frontend,
    /// Rust crates.io 依赖
    Rust,
    /// 移动端 Flutter / Dart 依赖
    Flutter,
}

impl OssComponentSource {
    /// 稳定串值（与 serde `snake_case` 输出一致，FRB 桥镜像用）
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Frontend => "frontend",
            Self::Rust => "rust",
            Self::Flutter => "flutter",
        }
    }
}

/// 单个开源组件
#[derive(Debug, Clone, Serialize)]
pub struct OssComponent {
    pub name: String,
    pub version: String,
    pub source: OssComponentSource,
    pub description: String,
    pub license: String,
    /// 源码仓库（可选；仅 https）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    /// 项目主页（可选；仅 https）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
}

/// 全部组件（克隆返回，调用方无法改写静态数据；默认顺序 = 前端 → Rust → Flutter）
pub fn all() -> Vec<OssComponent> {
    data::ALL_COMPONENTS.clone()
}
