//! 应用内「检查更新」只读能力（#107，移动端补齐）
//!
//! 口径：
//! - **只在用户点「检查更新」时发一次请求**——不轮询、不后台定时、不上报设备标识，
//!   与本地优先/零遥测的边界一致；
//! - 清单复用桌面 updater 的 `latest.json`（GitHub Releases 单点合成），
//!   这里只取 `version` / `pub_date` / `notes`，并给出 Android APK 直链；
//!   **下载与安装归壳层**（移动端写应用缓存 + 系统安装器），core 不落文件、
//!   不校验包签名、不静默安装；
//! - 失败原样透传（调用方降级为「打开发布页」），不 panic、不重试。
use serde::Serialize;

/// GitHub Releases 的 updater 清单（与 `tauri.conf.json` 的 endpoint 同源）
const LATEST_JSON_URL: &str =
    "https://github.com/mecoren/orbit/releases/latest/download/latest.json";

/// 发布页（检查失败/需要手动下载时给用户的兜底入口）
pub const RELEASES_PAGE_URL: &str = "https://github.com/mecoren/orbit/releases/latest";

/// Android APK 直链模板（与 `release.yml` 的产物命名/ tag 口径逐字一致）
///
/// Release 流程把 `flutter build apk` 的产物重命名为 `Orbit_<ver>.apk` 并以
/// `v<ver>` 为 tag 上传（见 `docs/08` §3.4）。这里按同一约定拼直链，
/// 不在清单里另存字段——版本号本身已能唯一确定资产名。
const APK_URL_TEMPLATE: &str =
    "https://github.com/mecoren/orbit/releases/download/v{version}/Orbit_{version}.apk";

/// 由清单版本号拼 Android APK 直链（纯函数；容忍 `v` 前缀与首尾空白）
pub fn apk_download_url(version: &str) -> String {
    let normalized = version.trim().trim_start_matches(['v', 'V']).trim();
    APK_URL_TEMPLATE.replace("{version}", normalized)
}

#[derive(Debug, Clone, Serialize)]
pub struct LatestReleaseInfo {
    /// 清单版本号（不带 `v` 前缀，如 `0.6.0`）
    pub version: String,
    /// 发布日期（ISO 8601，清单缺失时 None）
    pub pub_date: Option<String>,
    /// 更新说明（Markdown 原文，展示层按纯文本截断）
    pub notes: Option<String>,
    /// 发布页地址（始终可用）
    pub download_url: String,
    /// Android APK 直链（应用内下载 + 系统安装；非 Android 端仅作展示/兜底）
    pub apk_url: String,
}

/// 拉取最新版本清单（只读网络调用，无 DB 写入、不 emit 事件）
///
/// 不复用 `sync_adapters/http_client.rs`：那套按同步大对象调的是
/// `read_timeout`（F10 结论：`timeout` 是总预算，会截断慢速分片下载），
/// 而这里只有几 KB 清单，要的正是「10 秒总预算内拿不到就放弃」。
/// 错误串保持英文原文（桥层/UI 已按中文文案兜底），便于用户贴日志排查。
pub async fn check_latest_release() -> Result<LatestReleaseInfo, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        // GitHub API/CDN 对无 UA 的请求可能返回 403
        .user_agent("orbit-update-check")
        .build()
        .map_err(|e| format!("init http client: {e}"))?;

    let resp = client
        .get(LATEST_JSON_URL)
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("invalid manifest: {e}"))?;

    let version = body
        .get("version")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "manifest missing version".to_string())?
        .to_string();

    Ok(LatestReleaseInfo {
        apk_url: apk_download_url(&version),
        version,
        pub_date: body
            .get("pub_date")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        notes: body
            .get("notes")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        download_url: RELEASES_PAGE_URL.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::apk_download_url;

    #[test]
    fn apk_url_matches_release_asset_naming() {
        assert_eq!(
            apk_download_url("0.1.2"),
            "https://github.com/mecoren/orbit/releases/download/v0.1.2/Orbit_0.1.2.apk"
        );
    }

    #[test]
    fn apk_url_tolerates_v_prefix_and_whitespace() {
        assert_eq!(apk_download_url("v0.1.2"), apk_download_url("0.1.2"));
        assert_eq!(apk_download_url("  V0.1.2 "), apk_download_url("0.1.2"));
    }
}
