/**
 * holiday-meta —— 节假日记账（`holiday_meta`）的展示文案单一出口
 *
 * 同一份记账要在三处露面：设置页「日历」概览、日历页工具栏两处 tooltip、以及
 * 移动端缓存页概览（Dart 侧 `_stampLabel` 同口径）。此前桌面三处各拼各的字符串，
 * 于是口径一动就漏：2026-09-29 自动更新由「每日固定时刻」改「每月一次」后，
 * 模块注释与分类说明三处仍停在旧口径（`bd4d315` 才补上）。
 *
 * 这里把「记账字段 → 文案」与「失败态要不要亮出来」的判断收敛成纯函数，配
 * `holiday-meta.test.ts` 锁分支——文案改一次即全端生效。
 *
 * 纯函数无 React/IPC 依赖（时间戳直接算，不引 date-fns），便于单测。
 */
import type { HolidayMeta } from "@/lib/tauri";

/** 自动更新口径短句（设置页开关说明与日历页 tooltip 共用同一份措辞） */
export function holidayAutoLabel(autoEnabled: boolean): string {
  return autoEnabled ? "每月自动更新" : "已关闭每月自动更新";
}

/**
 * 记账时间戳 → `M月d日 HH:mm`；非本年补 `YYYY年` 前缀。
 *
 * 补年前缀不是洁癖：用户可能跨年才打开应用，只写「12月31日」看不出是哪一年，
 * 而「上次成功更新」正是判断新鲜度的字段（`last_update_ms` 只在自动更新范围内的
 * 年份成功后才推进，历史年份补写只写 `last_attempt_ms`）。
 */
export function holidayStampLabel(ms: number, now = new Date()): string {
  const d = new Date(ms);
  const two = (n: number) => n.toString().padStart(2, "0");
  const md = `${d.getMonth() + 1}月${d.getDate()}日 ${two(d.getHours())}:${two(d.getMinutes())}`;
  return d.getFullYear() === now.getFullYear() ? md : `${d.getFullYear()}年${md}`;
}

/** 概览区文案（null = 该行不渲染） */
export interface HolidayMetaLines {
  /** 「上次成功更新：…」；从未成功过给兜底文案 */
  lastUpdate: string;
  /** 「上次尝试：…」；仅失败态有值——正常态两条时间戳冗余，白占版面 */
  lastAttempt: string | null;
  /** 「连续失败 N 次（旧缓存保留可用）」；仅失败态有值（core 成功一次即清零） */
  failure: string | null;
}

/**
 * 记账 → 概览三行文案。
 *
 * `lastAttempt` 与 `failure` 只在 `failure_count > 0` 时给出：这是「自动更新连挂
 * 几天」的诊断位——只有失败计数而没有「上次尝试」时刻，用户分不清调度器是还在
 * 重试（刚试过）还是早就放弃（几天没动）。
 */
export function holidayMetaLines(
  meta: HolidayMeta | undefined,
  now = new Date(),
): HolidayMetaLines {
  const failureCount = meta?.failure_count ?? 0;
  return {
    lastUpdate:
      meta && meta.last_update_ms > 0
        ? `上次成功更新：${holidayStampLabel(meta.last_update_ms, now)}`
        : "尚未成功更新过",
    lastAttempt:
      failureCount > 0 && meta && meta.last_attempt_ms > 0
        ? `上次尝试：${holidayStampLabel(meta.last_attempt_ms, now)}`
        : null,
    failure:
      failureCount > 0 ? `连续失败 ${failureCount} 次（旧缓存保留可用）` : null,
  };
}

/** 日历页 tooltip 尾部补充：失败态才亮出计数，正常态返回空串 */
export function holidayFailureSuffix(meta: HolidayMeta | undefined): string {
  const failureCount = meta?.failure_count ?? 0;
  return failureCount > 0 ? `，连续失败 ${failureCount} 次` : "";
}
