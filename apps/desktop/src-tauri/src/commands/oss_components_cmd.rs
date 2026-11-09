//! oss_components_cmd — 开源组件引用清单命令面
//!
//! 数据源在 `orbit_core::models::oss_components::data`（双端唯一），本文件只是薄转发：
//! 不读 DB、不 emit 事件、不进同步白名单。移动端同名 FRB 函数见
//! `crates/orbit-flutter/src/api/oss_components.rs`。
use orbit_core::api::oss_components_api;
use orbit_core::models::oss_components::OssComponent;

/// 全部开源组件（只读静态数据；默认顺序 = 前端 → Rust → Flutter）
#[tauri::command]
pub fn oss_components() -> Vec<OssComponent> {
    oss_components_api::oss_components()
}
