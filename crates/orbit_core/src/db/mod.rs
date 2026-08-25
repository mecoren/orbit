//! db — 数据库访问层（sqlx + SQLCipher）
//!
//! - pool.rs：连接池 + SQLCipher PRAGMA key 初始化 + 迁移
//! - lifecycle.rs：数据库生命周期与文件持久化（master_auth.json 读写）
//! - migrate.rs：加密→明文数据库迁移（清除主密码场景）
//! - repository/：各表仓储，写操作后 emit 事件
//! - migrations/：SQL 迁移脚本（sqlx::migrate! 宏嵌入；仅 0001 一个文件，
//!   结构变更直接改 0001（不考虑增量迁移），改动后需删除本地库文件重新初始化）
//! - sync_registry.rs：同步/备份/导入白名单唯一权威来源（03 文档 §六）

pub mod lifecycle;
pub mod migrate;
pub mod pool;
pub mod repository;
pub mod sync_registry;
