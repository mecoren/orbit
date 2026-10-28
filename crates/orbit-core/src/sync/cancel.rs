//! 协作式同步取消令牌（N33）
//!
//! 同步主链是「阶段 → 表桶 → 附件 → 分片」的多层循环，在其中任意位置强杀
//! 在途 HTTP 请求会留下未完成的 multipart 会话（S3 需要显式 Abort，WebDAV
//! 分片目录只能等下轮自愈）。故 ADR 0010 定的口径是**协作式取消**：只置一个
//! 原子标记，由主链在边界读取并立即返回 [`SyncError::Cancelled`]。
//!
//! 检查点（从小到大）：
//! - 适配器每次调用前（`BasePathAdapter`）：数据桶 / 附件 / 清单请求之间
//! - S3 multipart 与 WebDAV 分片循环的每一片：最坏等待约一片（5MiB）
//!
//! 取消是**非故障**：不推进 `last_synced_at`，历史状态记 `cancelled`，
//! 已完成的部分保持原样（pull 按表事务提交、push 按桶条件写，云端清单不变即一致）。

use std::sync::atomic::{AtomicBool, Ordering};

use crate::sync::error::SyncError;

/// 一次同步运行内共享的取消标记
///
/// 由 `SyncEngine` 持有，`AcquireGuard` 建立时复位；壳层只能通过
/// `request_cancel` 置位。读路径只在边界命中，不做忙等。
#[derive(Debug, Default)]
pub struct SyncCancelToken {
    flag: AtomicBool,
}

impl SyncCancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    /// 请求取消（幂等）。只置位，不等待正在进行的请求返回。
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    /// 是否已被取消
    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// 新一轮同步开始前复位（由引擎在拿到运行槽位后调用）。
    pub fn reset(&self) {
        self.flag.store(false, Ordering::SeqCst);
    }

    /// 检查点：已取消则立即返回 `SyncError::Cancelled`
    pub fn check(&self) -> Result<(), SyncError> {
        if self.is_cancelled() {
            Err(SyncError::Cancelled {
                message: "用户取消同步".to_string(),
            })
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_starts_idle_and_checks_ok() {
        let token = SyncCancelToken::new();
        assert!(!token.is_cancelled());
        assert!(token.check().is_ok());
    }

    #[test]
    fn cancel_is_idempotent_and_check_returns_cancelled() {
        let token = SyncCancelToken::new();
        token.cancel();
        token.cancel();
        assert!(token.is_cancelled());
        assert!(matches!(token.check(), Err(SyncError::Cancelled { .. })));
    }

    #[test]
    fn reset_allows_next_run() {
        let token = SyncCancelToken::new();
        token.cancel();
        token.reset();
        assert!(!token.is_cancelled());
        assert!(token.check().is_ok());
    }

    #[test]
    fn cancelled_error_is_not_retryable_or_network() {
        let err = SyncError::Cancelled {
            message: "用户取消同步".to_string(),
        };
        assert!(err.is_cancelled());
        assert!(!err.is_retryable());
    }
}
