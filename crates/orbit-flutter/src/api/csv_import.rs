//! csv_import — 移动端桥接层 CSV 导入（迁移路径）
//!
//! 与桌面壳命令一一对应（薄包装，业务全部在 orbit_core）：
//! - [csv_import_cmd](../../../../../apps/desktop/src-tauri/src/commands/csv_import_cmd.rs)
//!   的 csv_import_preview / csv_import_execute → 委托 orbit_core::api::csv_import_api。
//!
//! DTO 镜像模式：入参为纯 String（无结构体过桥），出参结构在
//! [super::dto] 定义（FRB 扫描范围内 → 字段级 Dart 镜像）；
//! 文件读取由 Dart 侧 file_picker 完成后传文本内容。

use orbit_core::api::csv_import_api;

use super::dto::CsvImportPreviewView;

fn pool() -> Result<sqlx::SqlitePool, String> {
    super::state::with_state(|s| Ok(s.pool.clone()))
}

/// 预览导入（不写库）：解析 + 映射 + 统计（对应桌面 csv_import_preview）
pub async fn csv_import_preview(
    content: String,
    preset: String,
    preview_limit: Option<usize>,
) -> Result<CsvImportPreviewView, String> {
    // 纯解析路径，无需 pool；保持与桌面命令签名对齐（统一走 state 门禁）
    let _ = pool()?;
    csv_import_api::preview_csv_import(&content, &preset, preview_limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())
        .map(CsvImportPreviewView::from)
}

/// 执行导入（写库）：项目自动创建、逐行独立成败（对应桌面 csv_import_execute）
pub async fn csv_import_execute(
    content: String,
    preset: String,
) -> Result<CsvImportStatsView, String> {
    let pool = pool()?;
    csv_import_api::execute_csv_import(&pool, &content, &preset)
        .await
        .map_err(|e| e.to_string())
        .map(CsvImportStatsView::from)
}

pub use super::dto::CsvImportStatsView;
