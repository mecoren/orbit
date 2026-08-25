//! data_dir — 数据目录解析与迁移工具（共享模块）
//!
//! 应用内所有模块对"数据目录"的解析统一收敛到此模块：
//! - `resolve_app_data_dir` 为唯一权威入口，读取 `data_dir_override.json` 覆盖文件，
//!   支持用户自定义数据存储位置；其余模块一律通过本函数获取数据目录。
//! - 目录命名（README 命名约定）：
//!   生产环境 `cn.wait.orbit`，开发环境 `cn.wait.orbit.dev`（debug 构建自动隔离，
//!   避免开发数据污染正式库）。两条解析路径（Builder 早期 / AppHandle 运行期）
//!   均基于 `dirs::data_dir()/<identifier>` 复现 Tauri app_data_dir 语义，保证一致。

use std::path::{Path, PathBuf};

use tauri::AppHandle;
#[cfg(not(desktop))]
use tauri::Manager;

/// 应用数据目录标识（生产环境；必须与 tauri.conf.json identifier 一致）
#[cfg_attr(not(desktop), allow(dead_code))] // 移动端目录命名由 Tauri 决定
pub const APP_IDENTIFIER: &str = "cn.wait.orbit";
/// 开发环境目录后缀：debug 构建使用 `cn.wait.orbit.dev`
#[cfg(desktop)]
const DEV_IDENTIFIER: &str = "cn.wait.orbit.dev";
/// 数据目录覆盖文件名（放在默认 app_data_dir 下）
pub const OVERRIDE_FILE_NAME: &str = "data_dir_override.json";

/// 生效目录标识：debug 构建 → .dev，release → 正式
#[cfg(desktop)]
fn effective_identifier() -> &'static str {
    if cfg!(debug_assertions) {
        DEV_IDENTIFIER
    } else {
        APP_IDENTIFIER
    }
}

/// 数据目录覆盖配置
#[derive(serde::Serialize, serde::Deserialize)]
struct DataDirOverride {
    data_dir: String,
}

/// 获取默认 app_data_dir（不考虑覆盖文件），若目录不存在则创建
///
/// 桌面端：直接基于 dirs::data_dir()/effective_identifier() 解析（而非 Tauri 的
/// app_data_dir()），使运行期与 Builder 早期两条路径永远一致。
#[cfg(desktop)]
pub fn default_app_data_dir(_app: &AppHandle) -> Result<PathBuf, String> {
    let dir = default_app_data_dir_early()?;
    if !dir.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| format!("创建 app_data_dir 失败: {}", e))?;
    }
    Ok(dir)
}

/// 移动端版本：无 Builder 早期需求，直接走 Tauri path API 解析
/// （Android/iOS 上 dirs 无桌面语义，数据目录由 OS/Tauri 决定）
#[cfg(not(desktop))]
pub fn default_app_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("解析 app_data_dir 失败: {}", e))?;
    if !dir.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| format!("创建 app_data_dir 失败: {}", e))?;
    }
    Ok(dir)
}

/// 获取实际数据目录：优先读取覆盖文件，存在且有效时返回自定义路径，否则返回默认路径
pub fn resolve_app_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let default_dir = default_app_data_dir(app)?;

    // 检查覆盖文件
    let override_path = default_dir.join(OVERRIDE_FILE_NAME);
    if override_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&override_path) {
            if let Ok(config) = serde_json::from_str::<DataDirOverride>(&content) {
                let custom_dir = PathBuf::from(&config.data_dir);
                // 验证目录存在且是目录
                if custom_dir.exists() && custom_dir.is_dir() {
                    return Ok(custom_dir);
                }
                // 自定义目录无效，回退到默认
                eprintln!("自定义数据目录无效，回退到默认: {}", config.data_dir);
            }
        }
    }

    Ok(default_dir)
}

/// 窗口状态文件路径：`<生效数据目录>/.window-state.json`
#[allow(dead_code)] // 数据目录迁移功能（设置页）落地后启用
pub fn window_state_path(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(resolve_app_data_dir(app)?.join(".window-state.json"))
}

/// 无 AppHandle 版默认数据目录（精确复现 tauri 的 `app_data_dir()`）
///
/// tauri 实现（desktop.rs）：`dirs::data_dir()/<bundle_identifier>`。
#[cfg(desktop)]
fn default_app_data_dir_early() -> Result<PathBuf, String> {
    let base = dirs::data_dir().ok_or_else(|| "解析用户数据目录失败".to_string())?;
    Ok(base.join(effective_identifier()))
}

/// 无 AppHandle 版生效数据目录解析（读 `data_dir_override.json` 覆盖文件）
///
/// 与 `resolve_app_data_dir` 逻辑一致，但无需 AppHandle，
/// 供 Builder 阶段（窗口创建前）定位 window-state 文件使用。
#[cfg(desktop)]
fn resolve_app_data_dir_early() -> Result<PathBuf, String> {
    let default_dir = default_app_data_dir_early()?;

    let override_path = default_dir.join(OVERRIDE_FILE_NAME);
    if override_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&override_path) {
            if let Ok(config) = serde_json::from_str::<DataDirOverride>(&content) {
                let custom_dir = PathBuf::from(&config.data_dir);
                if custom_dir.exists() && custom_dir.is_dir() {
                    return Ok(custom_dir);
                }
                eprintln!("自定义数据目录无效，回退到默认: {}", config.data_dir);
            }
        }
    }

    Ok(default_dir)
}

/// window-state 插件的文件名参数（生效数据目录下的 `.window-state.json`）
///
/// 必须返回可随插件 `with_filename` 传入的字符串；解析失败时回退为相对文件名
/// （插件将回落到默认 `app_config_dir` 行为）。
#[cfg(desktop)]
pub fn window_state_file_early() -> String {
    match resolve_app_data_dir_early() {
        Ok(dir) => dir.join(".window-state.json").to_string_lossy().to_string(),
        Err(e) => {
            eprintln!("[window-state] 解析数据目录失败，回退默认文件名: {}", e);
            ".window-state.json".to_string()
        }
    }
}

/// 递归拷贝目录（含隐藏文件与子目录），自动创建目标父目录
///
/// 逐文件 `std::fs::copy` 拷贝，任一失败即返回错误（错误信息含相对路径便于定位）。
/// 符号链接等特殊文件类型跳过（数据目录内不应存在）。
#[allow(dead_code)] // 数据目录迁移功能（设置页）落地后启用
pub fn copy_dir_all(src: &Path, dst: &Path) -> Result<(), String> {
    if !src.is_dir() {
        return Err(format!("源路径不是目录: {}", src.display()));
    }
    std::fs::create_dir_all(dst)
        .map_err(|e| format!("创建目标目录失败 {}: {}", dst.display(), e))?;

    for entry in std::fs::read_dir(src)
        .map_err(|e| format!("读取源目录失败 {}: {}", src.display(), e))?
    {
        let entry = entry.map_err(|e| format!("读取目录条目失败: {}", e))?;
        let file_type = entry
            .file_type()
            .map_err(|e| format!("读取文件类型失败: {}", e))?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());

        if file_type.is_dir() {
            copy_dir_all(&src_path, &dst_path)?;
        } else if file_type.is_file() {
            std::fs::copy(&src_path, &dst_path).map_err(|e| {
                format!(
                    "复制文件失败 {} -> {}: {}",
                    src_path.display(),
                    dst_path.display(),
                    e
                )
            })?;
        }
        // 符号链接等特殊类型跳过
    }

    Ok(())
}
