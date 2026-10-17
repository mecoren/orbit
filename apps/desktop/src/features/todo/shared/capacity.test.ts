/**
 * 今日容量纯函数单测（G4：今天「装得下」多少任务）
 *
 * 判定口径：
 * - 今日排程量 = 今日截止且未完成任务的 duration_minutes 之和（未设时长不计）；
 * - 容量档位：充足 < 80% ≤ 偏紧 < 100% ≤ 超载；
 * - 未设预算（null）→ 不做超载判定，只报「已排」。
 */
import { describe, expect, it } from "vitest";
import { capacityStatus, DEFAULT_CAPACITY_MINUTES, todayLoadMinutes, formatMinutesShort, capacityHint } from "./capacity";
import type { TodoTaskListItem } from "@/lib/tauri";

function task(id: number, over: Partial<TodoTaskListItem> = {}): TodoTaskListItem {
  return {
    id,
    uuid: `u${id}`,
    title: `t${id}`,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    duration_minutes: null,
    percent_done: 0,
    position: id * 100,
    is_favorite: 0,
    created_at: 0,
    updated_at: 0,
    version: 0,
    ...over,
  } as TodoTaskListItem;
}

describe("todayLoadMinutes 今日排程量", () => {
  it("只累计今日截止且未完成的时长；未设时长不计", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const todayDue = new Date(2026, 9, 17, 18, 0).getTime();
    const tomorrowDue = new Date(2026, 9, 18, 18, 0).getTime();
    const load = todayLoadMinutes(
      [
        task(1, { due_date: todayDue, duration_minutes: 60 }),
        task(2, { due_date: todayDue, duration_minutes: 30 }),
        task(3, { due_date: todayDue, duration_minutes: null }), // 未设时长
        task(4, { due_date: tomorrowDue, duration_minutes: 120 }), // 明天
        task(5, { due_date: todayDue, duration_minutes: 90, done: 1 }), // 已完成
      ],
      now,
    );
    expect(load).toBe(90);
  });

  it("逾期任务不计入今日排程（归 G1 顺延处置）", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const yesterdayDue = new Date(2026, 9, 16, 18, 0).getTime();
    expect(todayLoadMinutes([task(1, { due_date: yesterdayDue, duration_minutes: 60 })], now)).toBe(0);
  });

  it("空列表 / 全未设时长 → 0", () => {
    const now = Date.now();
    expect(todayLoadMinutes([], now)).toBe(0);
    expect(todayLoadMinutes([task(1, { due_date: now, duration_minutes: null })], now)).toBe(0);
  });

  it("非正时长视同未设（防御脏值）", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const todayDue = new Date(2026, 9, 17, 18, 0).getTime();
    expect(todayLoadMinutes([task(1, { due_date: todayDue, duration_minutes: -30 })], now)).toBe(0);
    expect(todayLoadMinutes([task(1, { due_date: todayDue, duration_minutes: 0 })], now)).toBe(0);
  });
});

describe("capacityStatus 容量档位", () => {
  it("无预算（null）→ unknown，不做超载判定", () => {
    expect(capacityStatus(600, null).level).toBe("unknown");
    expect(capacityStatus(0, null).level).toBe("unknown");
  });

  it("充足 < 80% ≤ 偏紧 < 100% ≤ 超载", () => {
    expect(capacityStatus(383, 480).level).toBe("ok"); // 79.8%
    expect(capacityStatus(384, 480).level).toBe("tight"); // 80% 整
    expect(capacityStatus(479, 480).level).toBe("tight");
    expect(capacityStatus(480, 480).level).toBe("over"); // 100% 整
    expect(capacityStatus(600, 480).level).toBe("over");
    expect(capacityStatus(0, 480).level).toBe("ok");
  });

  it("超出分钟数只在超载时为正", () => {
    expect(capacityStatus(600, 480).overBy).toBe(120);
    expect(capacityStatus(400, 480).overBy).toBe(0);
    expect(capacityStatus(400, null).overBy).toBe(0);
  });

  it("预算为 0 或负 → 视同未设（不判超载）", () => {
    expect(capacityStatus(60, 0).level).toBe("unknown");
    expect(capacityStatus(60, -1).level).toBe("unknown");
  });
});

describe("formatMinutesShort 分钟→短文案", () => {
  it("整小时 / 带分钟 / 不足小时", () => {
    expect(formatMinutesShort(480)).toBe("8h");
    expect(formatMinutesShort(510)).toBe("8h30m");
    expect(formatMinutesShort(45)).toBe("45m");
    expect(formatMinutesShort(0)).toBe("0m");
    expect(formatMinutesShort(-10)).toBe("0m");
  });
});

describe("默认预算", () => {
  it("默认 480 分钟（8 小时工作日）", () => {
    expect(DEFAULT_CAPACITY_MINUTES).toBe(480);
  });
});

describe("capacityHint 容量提示文案（双端统一措辞）", () => {
  it("充足/偏紧 → 已排 X / 预算 Y", () => {
    expect(capacityHint(120, 480)).toBe("今日已排 2h / 预算 8h");
    expect(capacityHint(400, 480)).toBe("今日已排 6h40m / 预算 8h");
  });

  it("超载带超出量；恰好排满报「已排满」", () => {
    expect(capacityHint(600, 480)).toBe("今日已排 10h · 超出 2h");
    expect(capacityHint(480, 480)).toBe("今日已排 8h · 已排满");
  });

  it("未设预算 → 只报已排量", () => {
    expect(capacityHint(120, null)).toBe("今日已排 2h");
    expect(capacityHint(0, null)).toBe("今日已排 0m");
  });
});
