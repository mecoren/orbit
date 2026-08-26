//! repository — 仓储层
//!
//! 泛型仓储覆盖 todo 8 表；cfg/sync_config 专属仓储平移保留。
//! 写操作成功后通过 eventbus::EVENT_BUS.emit 广播事件。

pub mod attachment_repo;
pub mod cfg_option_repo;
pub mod generic_repo;
pub mod import_type_validator;
pub mod sync_config_repo;
pub mod sync_history_repo;
