//! api — FRB 扫描入口（rust_input 指向本模块）
//!
//! 模块划分与桌面命令域一一对应：
//! - [state]：全局状态单例（无 Tauri Manager 的替代方案）
//! - [auth]：主密码认证 + DB 生命周期
//! - [dto]：todo 域过桥类型的本地镜像（外部 crate 类型会被 FRB 降级 opaque，
//!   见 dto.rs 模块注释）
//! - [todo]：todo 八表 CRUD + 详情聚合（签名一律使用 [dto] 镜像类型）
//! - [asset]：任务附件（内容寻址上传/列表/读取/卸下 + 本地 GC）
//! - [sync]：同步配置 / 云同步执行 / 同步加密
//! - [plaintext_export]：明文数据导出（JSON / CSV，对齐桌面命令面）
//! - [holiday]：节假日数据（联网更新 + 60s tick 自动调度守护）
//! - [trash]：回收站（任务软删恢复 + 保留时间 + 60s tick TTL 清理守护）
//! - [stats]：统计仪表盘（总览/热力图/连续天数/分布聚合，backlog #25）
//! - [search]：全局搜索（任务/项目/评论三路聚合，backlog #26）
//! - [events]：下行事件流 + 提醒轮询守护

pub mod asset;
pub mod auth;
pub mod csv_import;
pub mod dto;
pub mod events;
pub mod holiday;
pub mod plaintext_export;
pub mod saved_filter;
pub mod search;
pub mod state;
pub mod stats;
pub mod sync;
pub mod todo;
pub mod trash;

pub use state::orbit_state_initialized;
