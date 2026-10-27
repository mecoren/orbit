//! 测试数据命令（薄壳转发）
//!
//! **仅测试环境可用**：前端入口只在 Vite `import.meta.env.DEV` 下渲染，
//! 命令本身再判一次 `cfg!(debug_assertions)`——release 包里该常量折叠为 false，
//! 即便有人从 devtools 直调也只能拿到「不可用」错误。
//!
//! 业务逻辑全在 `orbit_core::api::dev_seed_api`（单事务批量写入 + 按 uuid 前缀
//! 幂等清理），本文件不写任何业务规则。

use orbit_core::api::dev_seed_api::{self, DevSeedClearResult, DevSeedPlan, DevSeedResult};
use tauri::State;

use crate::AppState;

/// 环境门禁：release 构建一律拒绝
fn ensure_dev_build() -> Result<(), String> {
    if cfg!(debug_assertions) {
        Ok(())
    } else {
        Err("测试数据只在开发构建（debug）可用".to_string())
    }
}

/// 一键生成示例数据（先清上一批，不碰手工数据）
#[tauri::command]
pub async fn dev_seed_demo_data(
    state: State<'_, AppState>,
    plan: DevSeedPlan,
) -> Result<DevSeedResult, String> {
    ensure_dev_build()?;
    dev_seed_api::seed_demo_data(&state.pool, &plan)
        .await
        .map_err(|e| e.to_string())
}

/// 清除示例数据（按 uuid 前缀物理删除）
#[tauri::command]
pub async fn dev_seed_clear(state: State<'_, AppState>) -> Result<DevSeedClearResult, String> {
    ensure_dev_build()?;
    dev_seed_api::clear_demo_data(&state.pool)
        .await
        .map_err(|e| e.to_string())
}
