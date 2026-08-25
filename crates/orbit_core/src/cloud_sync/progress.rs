//! progress — 同步进度事件
//!
//! 定义 `SyncProgress` 枚举（通过 Tauri Event / FRB StreamSink 推送到 UI 层）
//! 和 `ProgressSender` trait（屏蔽双端推送差异）。
//!
//! ## 事件流示例
//! ```text
//! Starting { origin: Manual, total_modules: 14 }
//! Pushing { origin: Manual, module: "movies", current: 1, total: 14 }
//! Pushing { origin: Manual, module: "books", current: 2, total: 14 }   ← 跳过模块不发送 Pushing
//! Attachments { origin: Manual, action: "upload", current: 1, total: 5 }
//! Pulling { origin: Manual, module: "todos", current: 1, total: 3 }
//! Merging { origin: Manual, module: "todos", inserted: 2, updated: 1, deleted: 0 }
//! LocalDataApplied { origin: Manual, changed_records: 3 }
//! Done { origin: Manual, duration_ms: 1234, pushed_modules: 2, pulled_modules: 1 }
//! ```
//!
//! ## FRB 兼容性
//! `SyncProgress` 在本 crate（wait_core）内定义，FRB codegen 会将其识别为
//! 非 opaque 类型，可直接通过 `StreamSink<SyncProgress>` 推送。
//!
//! ## origin 字段（2026-07-25 需求4）
//! 每个变体携带 `origin: SyncOrigin` 字段，标识事件来源：
//! - `Background`：后台自动同步（scheduler / useSyncOnChange / 导入后自动推送）
//! - `Manual`：用户手动触发（设置页"立即同步" / 启动页同步）
//! - `Exit`：退出同步（useExitSync）
//! UI 层据此过滤，避免右下角指示器与设置页进度条/退出遮罩重复显示。

use serde::{Deserialize, Serialize};

/// 同步事件来源（用于 UI 层过滤重复显示）
///
/// 2026-07-25 需求4：每个 `SyncProgress` 事件携带 origin 字段，
/// 桌面端右下角指示器仅响应 `Background`，设置页仅响应 `Manual`，退出遮罩仅响应 `Exit`。
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SyncOrigin {
    /// 后台自动同步（scheduler / useSyncOnChange / 导入后自动推送）
    Background,
    /// 用户手动触发（设置页"立即同步" / 启动页同步）
    Manual,
    /// 退出同步（useExitSync）
    Exit,
}

impl Default for SyncOrigin {
    fn default() -> Self {
        Self::Manual
    }
}

/// 同步进度事件
///
/// 使用 `#[serde(tag = "phase")]` 内部标签，便于 TS/Dart 侧按 `phase` 字段判别。
/// 每个变体携带 `origin: SyncOrigin` 字段标识事件来源。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "phase")]
pub enum SyncProgress {
    /// 同步开始
    #[serde(rename = "starting")]
    Starting {
        /// 事件来源
        origin: SyncOrigin,
        /// 模块总数
        total_modules: u32,
    },

    /// 正在推送模块
    #[serde(rename = "pushing")]
    Pushing {
        /// 事件来源
        origin: SyncOrigin,
        /// 模块名（英文）
        module: String,
        /// 显示名（中文）
        display_name: String,
        /// 当前模块序号（1-based）
        current: u32,
        /// 模块总数
        total: u32,
    },

    /// 正在拉取模块
    #[serde(rename = "pulling")]
    Pulling {
        origin: SyncOrigin,
        module: String,
        display_name: String,
        current: u32,
        total: u32,
    },

    /// 正在合并模块数据
    #[serde(rename = "merging")]
    Merging {
        origin: SyncOrigin,
        module: String,
        display_name: String,
        /// 新增记录数
        inserted: u64,
        /// 更新记录数
        updated: u64,
        /// 删除记录数（应用墓碑）
        deleted: u64,
    },

    /// 远端数据已合并并写入本地数据库
    #[serde(rename = "local_data_applied")]
    LocalDataApplied {
        origin: SyncOrigin,
        changed_records: u64,
    },

    /// 正在同步附件
    #[serde(rename = "attachments")]
    Attachments {
        origin: SyncOrigin,
        /// 动作类型："upload" 或 "download"
        action: String,
        /// 当前序号（1-based）
        current: u32,
        /// 总数
        total: u32,
    },

    /// 同步完成
    #[serde(rename = "done")]
    Done {
        origin: SyncOrigin,
        /// 耗时（毫秒）
        duration_ms: u64,
        /// 推送的模块数
        pushed_modules: u32,
        /// 拉取的模块数
        pulled_modules: u32,
        /// 上传附件数
        uploaded_attachments: u32,
        /// 下载附件数
        downloaded_attachments: u32,
    },

    /// 同步出错
    #[serde(rename = "error")]
    Error {
        origin: SyncOrigin,
        /// 错误消息
        message: String,
        /// 出错的模块名（可选，全局错误为 None）
        module: Option<String>,
    },
}

impl SyncProgress {
    /// 估算百分比（0-100），用于进度条展示
    pub fn percent(&self) -> u32 {
        match self {
            SyncProgress::Starting { .. } => 0,
            SyncProgress::Pushing { current, total, .. }
            | SyncProgress::Pulling { current, total, .. } => {
                if *total == 0 {
                    0
                } else {
                    (current * 100) / total
                }
            }
            SyncProgress::Merging { .. }
            | SyncProgress::LocalDataApplied { .. }
            | SyncProgress::Attachments { .. } => 90,
            SyncProgress::Done { .. } => 100,
            SyncProgress::Error { .. } => 100,
        }
    }

    /// 获取模块显示名（用于 UI 文案）
    pub fn display_text(&self) -> String {
        match self {
            SyncProgress::Starting { .. } => "准备同步...".to_string(),
            SyncProgress::Pushing { display_name, .. } => {
                format!("正在上传{display_name}...")
            }
            SyncProgress::Pulling { display_name, .. } => {
                format!("正在下载{display_name}...")
            }
            SyncProgress::Merging { display_name, .. } => {
                format!("正在合并{display_name}...")
            }
            SyncProgress::LocalDataApplied { .. } => "本地数据已更新".to_string(),
            SyncProgress::Attachments { action, current, total, .. } => {
                if action == "upload" {
                    format!("正在上传附件 {current}/{total}...")
                } else {
                    format!("正在下载附件 {current}/{total}...")
                }
            }
            SyncProgress::Done { .. } => "同步完成".to_string(),
            SyncProgress::Error { message, .. } => format!("同步失败: {message}"),
        }
    }
}

/// 进度发送器 trait
///
/// 抽象 Tauri Event（桌面）和 FRB StreamSink（移动）的推送差异。
/// 实现者需保证 `send` 不阻塞（UI 线程可能监听）。
pub trait ProgressSender: Send + Sync {
    /// 发送进度事件（失败时静默忽略，不影响同步主流程）
    fn send(&self, progress: SyncProgress);
}

/// 空实现（用于测试或不需进度通知的场景）
pub struct NoopProgressSender;

impl ProgressSender for NoopProgressSender {
    fn send(&self, _progress: SyncProgress) {}
}

/// 进度发送构造器
///
/// 持有 `&dyn ProgressSender` 和固定的 `origin`，提供类型安全的便捷方法，
/// 强制每个事件都携带正确的 origin 字段，避免调用方遗漏。
///
/// 用法：
/// ```ignore
/// let builder = ProgressBuilder::new(&sender, SyncOrigin::Manual);
/// builder.starting(14);
/// builder.pushing("movies", "影视数据", 1, 14);
/// builder.done(1234, 2, 1, 5, 3);
/// ```
pub struct ProgressBuilder<'a> {
    sender: &'a dyn ProgressSender,
    origin: SyncOrigin,
}

impl<'a> ProgressBuilder<'a> {
    pub fn new(sender: &'a dyn ProgressSender, origin: SyncOrigin) -> Self {
        Self { sender, origin }
    }

    /// 同步开始
    pub fn starting(&self, total_modules: u32) {
        self.sender.send(SyncProgress::Starting {
            origin: self.origin,
            total_modules,
        });
    }

    /// 正在推送模块
    pub fn pushing(&self, module: &str, display_name: &str, current: u32, total: u32) {
        self.sender.send(SyncProgress::Pushing {
            origin: self.origin,
            module: module.to_string(),
            display_name: display_name.to_string(),
            current,
            total,
        });
    }

    /// 正在拉取模块
    pub fn pulling(&self, module: &str, display_name: &str, current: u32, total: u32) {
        self.sender.send(SyncProgress::Pulling {
            origin: self.origin,
            module: module.to_string(),
            display_name: display_name.to_string(),
            current,
            total,
        });
    }

    /// 正在合并模块数据
    pub fn merging(
        &self,
        module: &str,
        display_name: &str,
        inserted: u64,
        updated: u64,
        deleted: u64,
    ) {
        self.sender.send(SyncProgress::Merging {
            origin: self.origin,
            module: module.to_string(),
            display_name: display_name.to_string(),
            inserted,
            updated,
            deleted,
        });
    }

    /// 远端数据已合并并写入本地数据库
    pub fn local_data_applied(&self, changed_records: u64) {
        self.sender.send(SyncProgress::LocalDataApplied {
            origin: self.origin,
            changed_records,
        });
    }

    /// 正在同步附件
    pub fn attachments(&self, action: &str, current: u32, total: u32) {
        self.sender.send(SyncProgress::Attachments {
            origin: self.origin,
            action: action.to_string(),
            current,
            total,
        });
    }

    /// 同步完成
    pub fn done(
        &self,
        duration_ms: u64,
        pushed_modules: u32,
        pulled_modules: u32,
        uploaded_attachments: u32,
        downloaded_attachments: u32,
    ) {
        self.sender.send(SyncProgress::Done {
            origin: self.origin,
            duration_ms,
            pushed_modules,
            pulled_modules,
            uploaded_attachments,
            downloaded_attachments,
        });
    }

    /// 同步出错
    pub fn error(&self, message: &str, module: Option<&str>) {
        self.sender.send(SyncProgress::Error {
            origin: self.origin,
            message: message.to_string(),
            module: module.map(|s| s.to_string()),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starting_percent_is_zero() {
        let p = SyncProgress::Starting {
            origin: SyncOrigin::Manual,
            total_modules: 14,
        };
        assert_eq!(p.percent(), 0);
    }

    #[test]
    fn pushing_percent_calculates_correctly() {
        let p = SyncProgress::Pushing {
            origin: SyncOrigin::Manual,
            module: "movies".to_string(),
            display_name: "影视数据".to_string(),
            current: 3,
            total: 14,
        };
        assert_eq!(p.percent(), 21); // 3*100/14 = 21
    }

    #[test]
    fn done_percent_is_100() {
        let p = SyncProgress::Done {
            origin: SyncOrigin::Manual,
            duration_ms: 1000,
            pushed_modules: 5,
            pulled_modules: 3,
            uploaded_attachments: 2,
            downloaded_attachments: 1,
        };
        assert_eq!(p.percent(), 100);
    }

    #[test]
    fn local_data_applied_serializes_for_ui_refresh() {
        let p = SyncProgress::LocalDataApplied {
            origin: SyncOrigin::Manual,
            changed_records: 2,
        };

        let json = serde_json::to_string(&p).unwrap();
        assert!(json.contains("\"phase\":\"local_data_applied\""));
        assert!(json.contains("\"changed_records\":2"));
        assert_eq!(p.percent(), 90);
    }

    #[test]
    fn display_text_for_starting() {
        let p = SyncProgress::Starting {
            origin: SyncOrigin::Manual,
            total_modules: 14,
        };
        assert_eq!(p.display_text(), "准备同步...");
    }

    #[test]
    fn display_text_for_pushing() {
        let p = SyncProgress::Pushing {
            origin: SyncOrigin::Manual,
            module: "movies".to_string(),
            display_name: "影视数据".to_string(),
            current: 1,
            total: 14,
        };
        assert_eq!(p.display_text(), "正在上传影视数据...");
    }

    #[test]
    fn display_text_for_attachments_upload() {
        let p = SyncProgress::Attachments {
            origin: SyncOrigin::Manual,
            action: "upload".to_string(),
            current: 2,
            total: 5,
        };
        assert_eq!(p.display_text(), "正在上传附件 2/5...");
    }

    #[test]
    fn display_text_for_error() {
        let p = SyncProgress::Error {
            origin: SyncOrigin::Manual,
            message: "网络超时".to_string(),
            module: Some("movies".to_string()),
        };
        assert_eq!(p.display_text(), "同步失败: 网络超时");
    }

    #[test]
    fn serde_roundtrip_starting() {
        let p = SyncProgress::Starting {
            origin: SyncOrigin::Manual,
            total_modules: 14,
        };
        let json = serde_json::to_string(&p).unwrap();
        let parsed: SyncProgress = serde_json::from_str(&json).unwrap();
        match parsed {
            SyncProgress::Starting {
                origin,
                total_modules,
            } => {
                assert_eq!(origin, SyncOrigin::Manual);
                assert_eq!(total_modules, 14);
            }
            _ => panic!("解析类型错误"),
        }
    }

    #[test]
    fn serde_uses_phase_tag() {
        let p = SyncProgress::Done {
            origin: SyncOrigin::Background,
            duration_ms: 100,
            pushed_modules: 1,
            pulled_modules: 2,
            uploaded_attachments: 3,
            downloaded_attachments: 4,
        };
        let json = serde_json::to_string(&p).unwrap();
        assert!(json.contains("\"phase\":\"done\""), "JSON 必须含 phase 标签");
        assert!(
            json.contains("\"origin\":\"background\""),
            "JSON 必须含 origin 字段"
        );
    }

    #[test]
    fn noop_sender_does_not_panic() {
        let sender = NoopProgressSender;
        sender.send(SyncProgress::Starting {
            origin: SyncOrigin::Manual,
            total_modules: 1,
        });
        sender.send(SyncProgress::Done {
            origin: SyncOrigin::Manual,
            duration_ms: 1,
            pushed_modules: 1,
            pulled_modules: 1,
            uploaded_attachments: 0,
            downloaded_attachments: 0,
        });
    }

    #[test]
    fn percent_handles_zero_total() {
        let p = SyncProgress::Pushing {
            origin: SyncOrigin::Manual,
            module: "x".to_string(),
            display_name: "X".to_string(),
            current: 1,
            total: 0,
        };
        assert_eq!(p.percent(), 0);
    }

    /// ProgressBuilder 应自动填充 origin 字段
    #[test]
    fn progress_builder_fills_origin() {
        use std::sync::{Arc, Mutex};

        /// 测试用的捕获 sender，记录所有收到的事件
        struct CapturingSender {
            events: Arc<Mutex<Vec<SyncProgress>>>,
        }
        impl ProgressSender for CapturingSender {
            fn send(&self, progress: SyncProgress) {
                self.events.lock().unwrap().push(progress);
            }
        }

        let events = Arc::new(Mutex::new(Vec::new()));
        let sender = CapturingSender {
            events: events.clone(),
        };
        let builder = ProgressBuilder::new(&sender, SyncOrigin::Background);

        builder.starting(14);
        builder.pushing("movies", "影视", 1, 14);
        builder.local_data_applied(2);
        builder.done(1000, 1, 0, 0, 0);

        let captured = events.lock().unwrap();
        assert_eq!(captured.len(), 4);

        // 验证所有事件都携带了正确的 origin
        for event in captured.iter() {
            let origin = match event {
                SyncProgress::Starting { origin, .. } => origin,
                SyncProgress::Pushing { origin, .. } => origin,
                SyncProgress::Pulling { origin, .. } => origin,
                SyncProgress::Merging { origin, .. } => origin,
                SyncProgress::LocalDataApplied { origin, .. } => origin,
                SyncProgress::Attachments { origin, .. } => origin,
                SyncProgress::Done { origin, .. } => origin,
                SyncProgress::Error { origin, .. } => origin,
            };
            assert_eq!(*origin, SyncOrigin::Background);
        }
    }

    /// SyncOrigin 序列化为小写字符串
    #[test]
    fn sync_origin_serde_lowercase() {
        assert_eq!(
            serde_json::to_string(&SyncOrigin::Background).unwrap(),
            "\"background\""
        );
        assert_eq!(
            serde_json::to_string(&SyncOrigin::Manual).unwrap(),
            "\"manual\""
        );
        assert_eq!(
            serde_json::to_string(&SyncOrigin::Exit).unwrap(),
            "\"exit\""
        );
    }
}
