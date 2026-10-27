//! update — 移动端桥接层「检查更新」域（#107）
//!
//! 只在用户点「检查更新」时拉一次 GitHub Releases 清单：不轮询、不后台下载、
//! 不静默安装（与桌面 Tauri updater 的职责边界不同，移动端发版走 GitHub Release
//! 的 APK，安装动作归系统）。
//!
//! ## DTO 镜像
//! [UpdateInfo] 本地镜像 `orbit_core::api::update_api::LatestReleaseInfo`，
//! 不直接暴露 core 类型（保持两端壳独立演进）。
use orbit_core::api::update_api;
use serde::Serialize;

/// 最新版本清单（移动端展示用最小集）
#[derive(Debug, Clone, Serialize)]
pub struct UpdateInfo {
    /// 清单版本号（不带 `v` 前缀）
    pub version: String,
    /// 发布日期（ISO 8601）
    pub pub_date: Option<String>,
    /// 更新说明（Markdown 原文）
    pub notes: Option<String>,
    /// 发布页地址（检查失败/需要手动下载时的兜底）
    pub download_url: String,
}

/// 拉取最新版本清单（失败原样透传，调用方降级为「打开发布页」）
pub async fn check_latest_release() -> Result<UpdateInfo, String> {
    let info = update_api::check_latest_release().await?;
    Ok(UpdateInfo {
        version: info.version,
        pub_date: info.pub_date,
        notes: info.notes,
        download_url: info.download_url,
    })
}
