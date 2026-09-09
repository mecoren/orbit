import { describe, expect, it } from "vitest";

import {
  displayReminder,
  reminderClockLabel,
  type TaskReminderMeta,
} from "./reminder-meta";

const NOW = 1_800_000_000_000; // 固定锚点（2027-01-15 前后，绝对值无意义）
const MIN = 60_000;
const HOUR = 3_600_000;

/** 秒级断言不依赖时区：HH:mm 由本地时区决定，用同一 Date 生成期望 */
function clockOf(ms: number): string {
  return new Date(ms).toLocaleString("zh-CN", { hour: "2-digit", minute: "2-digit" });
}

describe("displayReminder —— 行内提醒展示元信息", () => {
  it("无提醒行返回 null", () => {
    expect(displayReminder([], NOW, false)).toBeNull();
  });

  it("过滤软删行；多条取最近未来一条", () => {
    const rows: TaskReminderMeta[] = [
      { id: 1, remind_at: NOW + 2 * HOUR, is_deleted: 0 },
      { id: 2, remind_at: NOW - 3 * HOUR, is_deleted: 1 }, // 软删：不算
      { id: 3, remind_at: NOW + 30 * MIN, is_deleted: 0 },
    ];
    const out = displayReminder(rows, NOW, false);
    expect(out).not.toBeNull();
    expect(out!.id).toBe(3);
    expect(out!.clock).toBe(clockOf(NOW + 30 * MIN));
    expect(out!.fired).toBe(false);
  });

  it("无未来行时回落最早到期行（已过期也展示，fired=true）", () => {
    const rows: TaskReminderMeta[] = [
      { id: 5, remind_at: NOW - 2 * HOUR, is_deleted: 0 },
      { id: 4, remind_at: NOW - 5 * MIN, is_deleted: 0 },
    ];
    const out = displayReminder(rows, NOW, false)!;
    // 全部已过期：取最早的一条（系列首响）
    expect(out.id).toBe(5);
    expect(out.fired).toBe(true);
  });

  it("已过期 + 任务已完成：fired=false（完成实例不再警示）", () => {
    const rows: TaskReminderMeta[] = [{ id: 7, remind_at: NOW - HOUR, is_deleted: 0 }];
    const out = displayReminder(rows, NOW, true)!;
    expect(out.fired).toBe(false);
  });

  it("恰好在当前时刻：fired=true（remind_at <= now 判定）", () => {
    const rows: TaskReminderMeta[] = [{ id: 9, remind_at: NOW, is_deleted: 0 }];
    expect(displayReminder(rows, NOW, false)!.fired).toBe(true);
  });
});

describe("reminderClockLabel —— HH:mm 文案", () => {
  it("与 toLocaleString zh-CN 2-digit 口径一致", () => {
    expect(reminderClockLabel(NOW)).toBe(clockOf(NOW));
  });
});
