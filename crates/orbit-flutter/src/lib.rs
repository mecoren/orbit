//! orbit_flutter — Orbit 移动端 Rust 桥接层
//!
//! 分层模型（对齐 omnipass）：
//!
//! ```text
//! cmd_* 纯函数（orbit_core）
//!    ├→ #[tauri::command] 包装（apps/desktop/src-tauri）→ 桌面端
//!    └→ FRB pub fn 包装（本 crate src/api/*）→ Flutter 移动端
//! ```
//!
//! 每个 api 函数都是薄包装：取全局状态 → 一行委托 orbit_core。
//! CPU 密集操作（KDF 等）由 FRB 自动在 isolate 中执行。

mod api;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

pub use api::orbit_state_initialized;
