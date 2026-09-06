//! api — FRB 扫描入口（rust_input 指向本模块）
//!
//! 模块划分与桌面命令域一一对应：
//! - [state]：全局状态单例（无 Tauri Manager 的替代方案）
//! - [auth]：主密码认证 + DB 生命周期
//! - [dto]：todo 域过桥类型的本地镜像（外部 crate 类型会被 FRB 降级 opaque，
//!   见 dto.rs 模块注释）
//! - [todo]：todo 八表 CRUD + 详情聚合（签名一律使用 [dto] 镜像类型）
//! - [sync]：同步配置 / 云同步执行 / 同步加密
//! - [plaintext_export]：明文数据导出（JSON / CSV，对齐桌面命令面）
//! - [holiday]：节假日数据（联网更新 + 60s tick 自动调度守护）
//! - [events]：下行事件流 + 提醒轮询守护

pub mod auth;
pub mod dto;
pub mod events;
pub mod holiday;
pub mod plaintext_export;
pub mod state;
pub mod sync;
pub mod todo;

pub use state::orbit_state_initialized;
