//! api — FRB 扫描入口（rust_input 指向本模块）
//!
//! 模块划分与桌面命令域一一对应：
//! - [state]：全局状态单例（无 Tauri Manager 的替代方案）
//! - [auth]：主密码认证 + DB 生命周期
//! - [todo]：todo 八表 CRUD + 详情聚合
//! - [sync]：同步配置 / 云同步执行 / 同步加密
//! - [events]：下行事件流 + 提醒轮询守护

pub mod auth;
pub mod events;
pub mod state;
pub mod sync;
pub mod todo;

pub use state::orbit_state_initialized;
