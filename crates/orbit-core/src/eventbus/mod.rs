//! eventbus — 全局事件总线
//!
//! 取代 Drift 的 `watch()` 响应式能力（详见 design.md 第六节）。
//! 仓储层在写操作成功后 emit 事件，Tauri 端与 FRB 端各自 subscribe
//! 并转发到前端（Tauri emit / Dart Stream）。
//!
//! 设计：tokio::sync::broadcast 多生产者多消费者广播，
//! OnceLock 全局单例，仓储层直接 `EVENT_BUS.emit(event)`。

use tokio::sync::broadcast;

pub mod events;

/// 广播通道容量：覆盖前端短暂无订阅 + 高频批量写入场景
pub const CHANNEL_CAPACITY: usize = 1024;

/// 事件总线句柄（可 Clone，共享同一底层通道）
#[derive(Clone)]
pub struct EventBus {
    sender: broadcast::Sender<events::DbEvent>,
}

impl EventBus {
    pub fn new() -> Self {
        let (sender, _) = broadcast::channel(CHANNEL_CAPACITY);
        Self { sender }
    }

    /// 仓储层在写操作成功后调用，广播数据库变更事件。
    /// 无订阅者时 send 失败，静默忽略（不阻塞写操作）。
    pub fn emit(&self, event: events::DbEvent) {
        let _ = self.sender.send(event);
    }

    /// 双端订阅：返回 broadcast::Receiver。
    /// Tauri 端在 spawn 任务中 recv 后 emit("db-change")；
    /// FRB 端在独立线程 blocking_recv 后推入 StreamSink。
    pub fn subscribe(&self) -> broadcast::Receiver<events::DbEvent> {
        self.sender.subscribe()
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

/// 全局单例事件总线
///
/// 仓储层直接 `eventbus::EVENT_BUS.emit(...)`，无需传递引用。
/// 双端在启动时 `eventbus::EVENT_BUS.subscribe()` 获取接收器。
pub static EVENT_BUS: once_cell::sync::Lazy<EventBus> = once_cell::sync::Lazy::new(EventBus::new);
