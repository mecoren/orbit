//! db — 数据库访问层（sqlx + SQLCipher）
//!
//! - pool.rs：连接池 + SQLCipher PRAGMA key 初始化 + 迁移
//! - lifecycle.rs：数据库生命周期与文件持久化（master_auth.json 读写）
//! - migrate.rs：加密→明文数据库迁移（清除主密码场景）
//! - repository/：各表仓储，写操作后 emit 事件
//! - migrations/：SQL 迁移脚本（sqlx::migrate! 宏嵌入；0001 为冻结基线，
//!   新增结构一律追加 NNNN_xxx.sql，老库只跑新增文件不删库；未发布的
//!   多文件可合并，已发布永不改/删）
//! - sync_registry.rs：同步/备份/导入白名单唯一权威来源（03 文档 §六）

pub mod lifecycle;
pub mod migrate;
pub mod pool;
pub mod repository;
pub mod sync_registry;
