//! aumid_registry — Windows Toast 通知身份注册（AUMID DisplayName + IconUri）
//!
//! 根因（2026-09-11 用户报告「通知显示 orbit-desktop + 老图标」）：
//! notify-rust 直发与计划 Toast 都以 AUMID `cn.wait.orbit` 发通知，但该
//! AUMID 从未在 `HKCU\Software\Classes\AppUserModelId` 注册身份——通知
//! 平台查不到 DisplayName/IconUri 时，横幅回退显示**发起进程名**（dev 态
//! exe 名 orbit-desktop）+ 进程图标缓存，与品牌完全脱节。
//!
//! 修复：setup 阶段幂等写两个注册表值：
//! - DisplayName = "Orbit"（用户口径：应用名就叫 orbit，不带 desktop）
//! - IconUri = 数据目录 cache/app-icon-notification.png
//!
//! 图标源：`app.default_window_icon()`——tauri codegen 从 icon.ico 首帧
//! （45a9f50 后 = 256px v5.1 高清帧）解码的位图，编译期烧进 exe，dev/
//! 安装态同源，保证通知图标永远与任务栏/托盘当前版本一致；文件每次启动
//! 全量重写，不存在旧图标缓存。
//!
//! 幂等性：键已存在则打开（`create` 选项语义），值覆盖写——每次启动
//! 对齐，单值变更零成本。失败静默 eprintln——注册失败只影响通知横幅
//! 显示身份，不应阻断启动链（与 tray/mica 同口径）。

use tauri::AppHandle;

/// AUMID = tauri.conf.json identifier；与 notify-rust 直发通道
/// （notification_scheduler）和计划 Toast（scheduled_toast）同口径
pub const APP_ID: &str = "cn.wait.orbit";

/// 通知横幅显示名（用户口径：应用名就叫 orbit，不带 desktop 后缀）
pub const DISPLAY_NAME: &str = "Orbit";

/// 注册表键路径（Windows 通知平台按 AUMID 查此键下的身份值；
/// 尾段与 APP_ID 同口径，由单测锁定——Rust 无常量字符串拼接原语）
const AUMID_KEY: &str = r"Software\Classes\AppUserModelId\cn.wait.orbit";

/// 幂等注册 AUMID 身份：DisplayName + IconUri（图标从 exe 内嵌
/// default_window_icon 导出 PNG 到数据目录 cache/ 下）。
/// 任何失败静默留痕——通知仍会发出（身份回退进程名），不阻断启动。
pub fn register_aumid_identity(app: &AppHandle) {
    let Some(icon) = app.default_window_icon().map(|i| i.to_owned()) else {
        eprintln!("[aumid] default_window_icon 缺失，跳过通知身份注册");
        return;
    };

    let Ok(icon_uri) = export_icon_png(&icon.rgba(), icon.width(), icon.height(), app) else {
        eprintln!("[aumid] 通知图标 PNG 导出失败，跳过 IconUri 注册");
        return;
    };
    if let Err(e) = write_identity(&icon_uri) {
        eprintln!("[aumid] AUMID 身份注册失败（通知将回退显示进程名）: {e}");
    }
}

/// RGBA 位图 → PNG 编码写入数据目录 cache/，返回 `file:///` URI。
/// 通知平台 IconUri 支持 file:/// 绝对路径（ToastNotificationManagerCompat
/// 系工具链同款语义）。
fn export_icon_png(
    rgba: &[u8],
    width: u32,
    height: u32,
    app: &AppHandle,
) -> Result<String, String> {
    use tauri::Manager as _;

    let dir = app
        .path()
        .app_cache_dir()
        .map_err(|e| format!("app_cache_dir 解析失败: {e}"))?;
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("cache 目录创建失败: {e}"))?;

    let png_path = dir.join("app-icon-notification.png");
    let file =
        std::fs::File::create(&png_path).map_err(|e| format!("PNG 文件创建失败: {e}"))?;
    let writer = std::io::BufWriter::new(file);

    use image::ImageEncoder as _;
    let encoder = image::codecs::png::PngEncoder::new(writer);
    encoder
        .write_image(rgba, width, height, image::ColorType::Rgba8.into())
        .map_err(|e| format!("PNG 编码失败: {e}"))?;
    Ok(format!(
        "file:///{}",
        png_path.to_string_lossy().replace('\\', "/")
    ))
}

/// HKCU\Software\Classes\AppUserModelId\cn.wait.orbit 写 DisplayName/IconUri。
/// `options().create()` 幂等（键已存在直接打开），值覆盖写保证每次启动对齐。
fn write_identity(icon_uri: &str) -> windows_registry::Result<()> {
    let key = windows_registry::CURRENT_USER
        .options()
        .read()
        .write()
        .create()
        .open(AUMID_KEY)?;
    key.set_string("DisplayName", DISPLAY_NAME)?;
    key.set_string("IconUri", icon_uri)?;
    Ok(())
}

// —— 单元测试（纯注册表操作，不经 Tauri AppHandle）——
#[cfg(test)]
mod tests {
    use super::*;

    /// 探针键（测试专用 AUMID，非真实通道；测试后清理）
    const TEST_KEY: &str = r"Software\Classes\AppUserModelId\cn.wait.orbit.__test_probe__";

    fn write_test_identity(icon_uri: &str) -> windows_registry::Result<()> {
        let key = windows_registry::CURRENT_USER
            .options()
            .read()
            .write()
            .create()
            .open(TEST_KEY)?;
        key.set_string("DisplayName", DISPLAY_NAME)?;
        key.set_string("IconUri", icon_uri)?;
        Ok(())
    }

    #[test]
    fn aumid_key_tail_matches_app_id() {
        // 键路径尾段必须等于 APP_ID（同口径锁定；改名时此处假红提醒同步改）
        assert!(AUMID_KEY.ends_with(APP_ID));
        assert_eq!(APP_ID, "cn.wait.orbit");
    }

    #[test]
    fn writes_display_name_and_icon_uri() {
        write_test_identity("file:///C:/tmp/icon.png").expect("写入探针 AUMID 键");

        let key = windows_registry::CURRENT_USER.open(TEST_KEY).expect("读取探针 AUMID 键");
        assert_eq!(key.get_string("DisplayName").unwrap(), "Orbit");
        assert_eq!(key.get_string("IconUri").unwrap(), "file:///C:/tmp/icon.png");

        // 幂等覆盖：二次写入新 IconUri 生效
        write_test_identity("file:///C:/tmp/icon2.png").unwrap();
        let key = windows_registry::CURRENT_USER.open(TEST_KEY).unwrap();
        assert_eq!(key.get_string("IconUri").unwrap(), "file:///C:/tmp/icon2.png");

        // 清理探针键
        windows_registry::CURRENT_USER
            .remove_tree(TEST_KEY)
            .expect("清理探针 AUMID 键");
    }
}
