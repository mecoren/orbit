//! 有界集合小工具（内存门禁配套）
//!
//! `perf-metrics/audit-unbounded.mjs` 要求进程生命周期内可达的累加容器给出
//! 上界证据（就地 `bounded*` 标记或 `knownUnbounded` 登记）。
//! 双端提醒轮询各持一份「已通知去重集合」（`crates/orbit-flutter/src/api/events.rs`
//! 与 `apps/desktop/src-tauri/src/commands/notification_scheduler.rs`），
//! 条目只增不减——本模块提供「插入并把集合收敛回上界」的纯函数，两壳共用
//! 一份实现（去重口径本身即双端同源，见 docs/03 §五）。

use std::collections::BTreeSet;

/// 插入 `key` 并把集合收敛到 `max` 条以内，返回本次淘汰的键数。
///
/// 淘汰策略取 `BTreeSet` 的最小键：调用方的键是 `(reminder.id, remind_at)`，
/// id 单调递增，故最小键对应**最旧**的那条提醒——它的行早已被
/// `advance_fired_reminder` 处置（顺延或删除），再留着只占内存。
///
/// `max` 被钳到至少 1：上界为 0 时仍保留刚插入的那条（否则每轮都白插一次，
/// 去重语义直接失效，且调用方看起来"设置了上界"却什么也没记）。
pub fn insert_bounded<K: Ord + Copy>(set: &mut BTreeSet<K>, key: K, max: usize) -> usize {
    set.insert(key);
    let cap = max.max(1);
    let mut evicted = 0;
    while set.len() > cap {
        set.pop_first();
        evicted += 1;
    }
    evicted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_everything_below_cap() {
        let mut set = BTreeSet::new();
        for id in 1..=3 {
            assert_eq!(insert_bounded(&mut set, (id, 0), 5), 0);
        }
        assert_eq!(set.len(), 3);
    }

    #[test]
    fn evicts_oldest_keys_when_over_cap() {
        let mut set = BTreeSet::new();
        for id in 1..=8 {
            insert_bounded(&mut set, (id, 0), 5);
        }
        assert_eq!(set.len(), 5);
        // 键序即淘汰序：最小的 3 个（id 1/2/3）先走
        assert_eq!(set.iter().next().copied(), Some((4, 0)));
        assert_eq!(set.iter().next_back().copied(), Some((8, 0)));
    }

    #[test]
    fn reinserting_old_key_is_not_duplicated() {
        let mut set = BTreeSet::new();
        insert_bounded(&mut set, (7, 100), 5);
        insert_bounded(&mut set, (7, 100), 5);
        assert_eq!(set.len(), 1);
        // 同一 id 顺延后的新 remind_at 是新键（持续提醒 G2 语义）→ 两条并存
        insert_bounded(&mut set, (7, 200), 5);
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn zero_cap_still_remembers_the_latest_key() {
        let mut set = BTreeSet::new();
        assert_eq!(insert_bounded(&mut set, (1, 0), 0), 0);
        insert_bounded(&mut set, (2, 0), 0);
        assert_eq!(set.len(), 1);
        assert_eq!(set.iter().next().copied(), Some((2, 0)));
    }

    #[test]
    fn eviction_count_is_reported() {
        let mut set = BTreeSet::new();
        for id in 1..=5 {
            insert_bounded(&mut set, (id, 0), 3);
        }
        assert_eq!(insert_bounded(&mut set, (6, 0), 3), 1);
        assert_eq!(set.len(), 3);
    }
}
