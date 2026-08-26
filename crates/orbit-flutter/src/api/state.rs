//! state — 全局状态单例
//!
//! 桌面端由 Tauri `app.manage(AppState)` 注入状态；移动端没有 Manager，
//! 改用 crate 级全局单例（parking_lot），由 db_init_* 初始化。
//!
//! 注：本模块类型对 FRB 不可见（pub(crate)），仅 [orbit_state_initialized]
//! 导出为桥接函数——OrbitState 含 SqlitePool/PathBuf 等不可镜像类型。

use std::path::PathBuf;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use sqlx::SqlitePool;

/// 应用全局状态：数据库连接池 + 数据目录
///
/// 对齐桌面壳 AppState（apps/desktop/src-tauri/src/lib.rs）。
pub(crate) struct OrbitState {
    pub(crate) pool: SqlitePool,
    /// 应用数据目录（Android: 通过 path_provider 取 filesDir 传入）
    pub(crate) base_dir: PathBuf,
}

impl OrbitState {
    #[allow(dead_code)]
    pub(crate) fn new(pool: SqlitePool, base_dir: PathBuf) -> Self {
        Self { pool, base_dir }
    }
}

static ORBIT_STATE: Lazy<Mutex<Option<OrbitState>>> = Lazy::new(|| Mutex::new(None));

/// 以只读方式访问状态（未初始化时返回错误）
pub(crate) fn with_state<T>(f: impl FnOnce(&OrbitState) -> Result<T, String>) -> Result<T, String> {
    let guard = ORBIT_STATE.lock();
    let state = guard
        .as_ref()
        .ok_or_else(|| "[not_initialized] 数据库未初始化".to_string())?;
    f(state)
}

/// 以可变方式访问状态
#[allow(dead_code)]
pub(crate) fn with_state_mut<T>(
    f: impl FnOnce(&mut OrbitState) -> Result<T, String>,
) -> Result<T, String> {
    let mut guard = ORBIT_STATE.lock();
    let state = guard
        .as_mut()
        .ok_or_else(|| "[not_initialized] 数据库未初始化".to_string())?;
    f(state)
}

/// 初始化全局状态（由 db_init_* 内部调用）
pub(crate) fn set_state(pool: SqlitePool, base_dir: PathBuf) {
    *ORBIT_STATE.lock() = Some(OrbitState { pool, base_dir });
}

/// 移除状态（迁移场景，pool 已 close 后调用）
pub(crate) fn clear_state() {
    *ORBIT_STATE.lock() = None;
}

/// 取连接池克隆（未初始化时返回 None；守护任务轮询用，避免错误噪音）
pub(crate) fn with_state_pool() -> Option<SqlitePool> {
    ORBIT_STATE.lock().as_ref().map(|s| s.pool.clone())
}

// ── FRB 导出：状态查询 ──

/// 查询桥接状态是否已初始化（诊断用）
pub fn orbit_state_initialized() -> bool {
    ORBIT_STATE.lock().is_some()
}
