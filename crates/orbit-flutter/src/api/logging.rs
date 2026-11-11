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
///
/// **安装顺序（2026-11-11 修正）**：`logging::install()` 必须**先于**
/// `setup_default_user_utils()`。后者会先装 FRB 自带的 logger，全局 `log`
/// logger 只能有一个——先装者胜，`android_logger::init_once` 后到即静默失效，
/// 于是 `with_tag("orbit")` 与 Info 级别双双不生效：同步期间 logcat 里每条 SQL
/// 都以 `D sqlx_core::logger` 逐条落盘（tag 退化成模块路径、级别退化成 Debug），
/// 一次 214k 行的同步刷出成片日志写入。
/// `set_max_level` 再兜一道：即便未来别的初始化抢先装了 logger，级别仍钉在 Info。
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    crate::logging::install();
    log::set_max_level(log::LevelFilter::Info);
    flutter_rust_bridge::setup_default_user_utils();
}
