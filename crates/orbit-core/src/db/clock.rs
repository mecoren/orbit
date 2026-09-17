//! clock — 单调逻辑时钟（HLC: Hybrid Logical Clock 的折叠实现）
//!
//! ## 为什么需要
//! LWW 合并以 `updated_at` 为唯一主键裁决「谁写得更晚」，而 `updated_at` 原先
//! 直接取自设备墙上时钟：设备间时钟漂移（哪怕几十秒）会让「快表」的记录
//! **系统性**压过「慢表」的合法后写，两端各自保留自己的值后持续振荡；同毫秒
//! 并发写入还会退化为「谁先被同步谁赢」的偶然结果。
//!
//! ## 实现口径（为什么不再加一列 hlc）
//! 教科书 HLC 产出 `(physical, logical)` 二元组；本实现把 logical 折叠进同一个
//! 毫秒时间戳整数，直接复用既有的 `updated_at`/`deleted_at` 列：
//! - **推进（send）**：`ts = max(wall_ms, last + 1)`——同设备内严格单调，同毫秒
//!   多次写入不再平局，墙上时钟回拨也不会倒退；
//! - **接收（receive）**：同步合并时 `last = max(last, 远端时间戳)`——见到远端
//!   更大的时间戳后本地立即追上，此后本地写入必大于已见值，因果序成立
//!   （漂移偏置在首次同步后即被消除）。
//!
//! 折叠而非新增 `hlc` 列的理由：`updated_at` 本身就是 LWW 的比较键，另起一列会
//! 让两把键并存（谁先比？旧行怎么补？），并连带 11 张表 DDL、全部写路径、双端
//! DTO 镜像与 FRB 链路（03 文档 §八 曾记为此项成本）。折叠方案值域完全等价、
//! 向后兼容（旧行 `updated_at` 照常参与比较）、零 schema 变更。
//!
//! ## 持久化
//! 进程内状态是 `AtomicI64`；[`load`]/[`persist`] 用本地 KV 表 `cfg_kv` 做跨重启
//! 记忆——否则慢表重启后时间戳回落到墙上时钟，跌回旧值（单调性丢失，旧记录会
//! 反过来赢过重启后的新写入）。`cfg_kv` 是纯本地表（不进 SYNCABLE_TABLES），
//! 时钟状态不会被同步出去。
//!
//! ## 与 `db_loader::now_ms` 的分工
//! `db_loader::now_ms` 保持**纯墙上时钟**语义，仅供同步账面时间使用
//! （`last_synced_at` 设备检查点 → 墓碑回收水位线）。水位线若被逻辑时钟抬到
//! 未来，会让尚未见过墓碑的设备被误判为「已见过」而提前回收墓碑。

use std::sync::atomic::{AtomicI64, Ordering};

use sqlx::SqlitePool;

use crate::error::CoreResult;

/// `cfg_kv` 中的逻辑时钟持久化键
const CLOCK_KEY: &str = "sync_clock_ms";

/// 进程级逻辑时钟（毫秒，含折叠的逻辑分量）
static CLOCK: AtomicI64 = AtomicI64::new(0);

/// 纯函数：推进规则 `max(wall, cur + 1)`
///
/// 抽出以便注入固定输入做单测（HLC 单调性/回拨不变性不依赖真实时钟）。
fn next_value(cur: i64, wall: i64) -> i64 {
    wall.max(cur.saturating_add(1))
}

/// 纯函数：接收规则 `max(cur, remote)`
fn merge_value(cur: i64, remote: i64) -> i64 {
    cur.max(remote)
}

/// 墙上时钟（Unix 毫秒）
fn wall_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 取下一个写入时间戳（推进时钟）
///
/// **有副作用**：每次调用都会推进进程内时钟，同一毫秒内连续调用得到递增序列。
/// 业务写路径的 `updated_at`/`deleted_at` 一律走本函数，不要再直接用墙上时钟。
pub fn next_ms() -> i64 {
    let wall = wall_ms();
    let mut cur = CLOCK.load(Ordering::SeqCst);
    loop {
        let next = next_value(cur, wall);
        match CLOCK.compare_exchange_weak(cur, next, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => return next,
            Err(actual) => cur = actual,
        }
    }
}

/// 读取当前逻辑时钟（不推进）；从未初始化时为 0
pub fn peek() -> i64 {
    CLOCK.load(Ordering::SeqCst)
}

/// 接收远端时间戳（HLC receive 规则）
///
/// 同步合并对每条远端记录的 `updated_at` 与墓碑 `deleted_at` 调用一次；
/// 只增不减，因此重复观察同一值无副作用。
pub fn observe_ms(remote_ms: i64) {
    if remote_ms <= 0 {
        return; // 0/NULL 旧数据不得把时钟拉回起点
    }
    let mut cur = CLOCK.load(Ordering::SeqCst);
    loop {
        let next = merge_value(cur, remote_ms);
        if next == cur {
            return; // 本地已不小于远端，无需写入
        }
        match CLOCK.compare_exchange_weak(cur, next, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => return,
            Err(actual) => cur = actual,
        }
    }
}

/// 从 `cfg_kv` 恢复时钟（进程启动/建池后调用一次）
///
/// 取 `max` 而非直接覆盖：同一进程内可能有多个库（测试/切换库），
/// 单调性是进程级不变量，倒退会破坏 LWW 的收敛前提。
pub async fn load(pool: &SqlitePool) -> CoreResult<()> {
    let row: Option<(String,)> = sqlx::query_as("SELECT value FROM cfg_kv WHERE key = ?")
        .bind(CLOCK_KEY)
        .fetch_optional(pool)
        .await?;
    if let Some(saved) = row.and_then(|(value,)| value.parse::<i64>().ok()) {
        CLOCK.fetch_max(saved, Ordering::SeqCst);
    }
    Ok(())
}

/// 把当前时钟写回 `cfg_kv`（同步合并结束后调用一次即可）
pub async fn persist(pool: &SqlitePool) -> CoreResult<()> {
    let cur = peek();
    sqlx::query(
        "INSERT INTO cfg_kv (key, value, updated_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
    )
    .bind(CLOCK_KEY)
    .bind(cur.to_string())
    .bind(cur)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_value_is_strictly_monotonic() {
        assert_eq!(next_value(0, 1000), 1000, "首次取墙上时钟");
        assert_eq!(next_value(1000, 1000), 1001, "同毫秒写入必须递增");
        assert_eq!(next_value(1000, 1001), 1001, "墙上时钟前进则直接采用");
    }

    #[test]
    fn next_value_survives_clock_rollback() {
        // 墙上时钟回拨（NTP 校正/时区误改）不得让时间戳倒退
        assert_eq!(next_value(9000, 100), 9001, "回拨时仍取 last + 1");
    }

    #[test]
    fn merge_value_only_moves_forward() {
        assert_eq!(merge_value(100, 500), 500);
        assert_eq!(merge_value(500, 100), 500, "较旧远端不影响本地");
    }

    #[test]
    fn observe_ignores_non_positive() {
        // 0/NULL 旧数据不得把时钟拉回起点
        let before = peek();
        observe_ms(0);
        observe_ms(-5);
        assert_eq!(peek(), before);
    }

    #[test]
    fn next_ms_never_regresses() {
        let a = next_ms();
        let b = next_ms();
        let c = next_ms();
        assert!(b > a && c > b, "连续推进必须严格递增: {a} {b} {c}");
    }

    #[test]
    fn observe_then_next_is_greater_than_observed() {
        // 用纯函数验证 receive → send 的因果序，避免污染进程级 static
        let observed = merge_value(0, 5_000_000_000_000);
        assert_eq!(observed, 5_000_000_000_000);
        assert!(
            next_value(observed, 4_000_000_000_000) > observed,
            "观察到远端后本地写入必须更大（墙上时钟更慢也一样）"
        );
    }
}
