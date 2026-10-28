//! log_cmd — 日志目录读数与打开入口（docs/02 §九 记 M6+ 的那一处）
//!
//! 背景：`tauri-plugin-log` 自 2026-09-13 起就把 Rust/前端日志落到
//! `{app_log_dir}/app_log.log`，但用户侧**没有任何入口**能拿到它——报障时
//! 只能被告知「去 AppData 里找」。本模块只做两件只读的事：
//!
//! 1. 报出日志目录的绝对路径 + 目录内文件清单（名字/大小/修改时间）；
//! 2. 交给前端一个路径，由前端用 `plugin-shell` 的 `open` 打开目录或文件
//!    （与「非图片附件用系统程序打开」同一条通道，不新增插件与权限）。
//!
//! ## 路径口径
//!
//! 必须与 `lib.rs::log_dir_writable` 完全一致，否则会出现「设置页显示 A 目录、
//! 插件实际写 B 目录」的分裂：macOS 取 `~/Library/Logs/<identifier>`，其余平台
//! 取 `data_local_dir()/<identifier>/logs`。注意这里用的是**发布标识**
//! `cn.wait.orbit`（不是 debug 构建的 `.dev` 数据目录）——Tauri 只认
//! tauri.conf.json 的 identifier，日志目录从不跟随 `data_dir_override.json`。
//!
//! ## 为什么不做「读日志内容」
//!
//! 日志文件可达数十 MB，整份读进前端只会让设置页变卡；而用户真正要做的是
//! 「找到它、发给我」。故只报元数据 + 给打开动作，内容交给系统编辑器。
//!
//! ## 只读口径
//!
//! 不写任何文件、不 emit db-change、不进同步白名单（AGENTS「只读聚合不进同步
//! 白名单」）。日志本身也在 `.gitignore`/脱敏红线之外——脱敏规则见 docs/02 §九。

use std::path::PathBuf;

use serde::Serialize;

/// 日志目录内单个文件
#[derive(Debug, Clone, Serialize)]
pub struct LogFileView {
    pub name: String,
    /// 字节数（读取失败时为 0，不阻断整份清单）
    pub size_bytes: i64,
    /// 最后修改时间（Unix 毫秒；不可得为 0）
    pub modified_ms: i64,
}

/// 日志读数（目录 + 文件清单）
#[derive(Debug, Clone, Serialize)]
pub struct LogOverview {
    /// 日志目录绝对路径（字符串形式，前端直接交给 shell open）
    pub dir: String,
    /// 目录是否可读（false 时 `files` 恒空，`reason` 说明原因）
    pub readable: bool,
    /// 不可读原因（可读时为 None）
    pub reason: Option<String>,
    /// 目录内文件清单（按修改时间倒序，最多 [LOG_FILE_LIMIT] 条）
    pub files: Vec<LogFileView>,
}

/// 清单条数上限：日志轮转后的历史份数有限，再多对用户也没有意义
const LOG_FILE_LIMIT: usize = 20;

/// 与 `lib.rs::log_dir_writable` 同口径解析日志目录
///
/// 注意不能用 `app.path().app_log_dir()`：那条路径在 dev 构建下会因
/// `cfg!(debug_assertions)` 之外的差异（Tauri 版本/平台）与插件实际落盘位置
/// 分叉，而 `lib.rs` 的预探与插件的 `TargetKind::LogDir` 都以本口径为准。
fn log_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        dirs::home_dir().map(|home| {
            home.join("Library/Logs")
                .join(crate::commands::data_dir::APP_IDENTIFIER)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        dirs::data_local_dir()
            .map(|base| base.join(crate::commands::data_dir::APP_IDENTIFIER).join("logs"))
    }
}

/// 读日志目录概览（只读；目录不可读不报错，按 `readable: false` 如实回报）
#[tauri::command]
pub fn log_overview() -> LogOverview {
    let Some(dir) = log_dir() else {
        return LogOverview {
            dir: String::new(),
            readable: false,
            reason: Some("无法解析系统日志目录".to_string()),
            files: Vec::new(),
        };
    };

    let dir_str = dir.to_string_lossy().to_string();
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) => {
            return LogOverview {
                dir: dir_str,
                readable: false,
                reason: Some(format!("日志目录不可读: {e}")),
                files: Vec::new(),
            };
        }
    };

    let mut files: Vec<LogFileView> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            // 只列普通文件：日志目录理论上只有 app_log*.log，但别把子目录当文件
            let meta = entry.metadata().ok()?;
            if !meta.is_file() {
                return None;
            }
            let modified_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Some(LogFileView {
                name: entry.file_name().to_string_lossy().to_string(),
                size_bytes: meta.len() as i64,
                modified_ms,
            })
        })
        .collect();

    // 按修改时间倒序：用户最常要看的是刚出问题那一轮
    files.sort_by_key(|f| std::cmp::Reverse(f.modified_ms));
    files.truncate(LOG_FILE_LIMIT);

    LogOverview {
        dir: dir_str,
        readable: true,
        reason: None,
        files,
    }
}
