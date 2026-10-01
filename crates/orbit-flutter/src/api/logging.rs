//! logging — 移动端日志初始化桥（F81，2026-10-01 第六轮）
//!
//! 此前 orbit-core / 本 crate 的全部 `log::*` 在移动端**静默丢弃**（无任何
//! logger 安装点），F35/F37 等「失败改 `log::warn!`」的成果在移动端全部归零，
//! 排障只能退而用 `eprintln!`（F71 曾因此刻意保留 sync.rs 的一处 `eprintln!`）。
//!
//! `#[frb(init)]` 钩子在 Dart 侧 `RustLib.init()` 装载动态库时由生成的
//! `executeRustInitializers` 自动调用，先于任何业务桥接调用——在此安装平台
//! logger（见 crate 根 `logging` 模块：Android → logcat，级别对齐桌面端 Info）。
//!
//! 注意：`#[frb(init)]` 钩子必须位于 rust_input（`crate::api`）内才会被
//! codegen 接线，放 lib.rs 会被静默忽略。

/// FRB 库加载钩子（幂等；由生成代码在启动期自动调用，业务代码勿重复调用）
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    crate::logging::install();
}
