//! logging — 移动端 `log::*` 的落地点（F81，2026-10-01 第六轮）
//!
//! 此前 orbit-core / 本 crate 的全部 `log::*` 在移动端**静默丢弃**（无任何
//! logger 安装点），F35/F37 等「失败改 `log::warn!`」的成果在移动端全部归零，
//! 排障只能退而用 `eprintln!`（F71 曾因此刻意保留 sync.rs 的一处 `eprintln!`）。
//!
//! 本模块由 `init_app`（`#[frb(init)]`，FRB 库加载时执行、先于任何业务调用）
//! 调用 [`install`] 安装平台 logger：Android → `android_logger`（logcat），
//! 级别与桌面端 tauri_plugin_log 同为 Info。安装以进程级 `Once` 保护，
//! 重复调用安全（对齐内存门禁的 once-guard 纪律）。

use std::sync::Once;

static INSTALL: Once = Once::new();

/// 安装平台 logger（幂等；非 Android 平台保持静默不 panic）
pub fn install() {
    INSTALL.call_once(|| {
        #[cfg(target_os = "android")]
        {
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Info)
                    .with_tag("orbit"),
            );
            log::info!("[logging] android_logger 已安装（tag=orbit, level=info）");
        }
        #[cfg(not(target_os = "android"))]
        {
            // 当前移动壳仅 Android（仓库无 iOS 目录）；桌面端不走本 crate。
            // 未来接 iOS 壳时在此分支挂 os_logger。
        }
    });
}
