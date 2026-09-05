// apps/desktop/src/features/todo/shared/reminder-snooze.test.ts
// 推迟纯逻辑（snoozeRemindAt / 标签）+ snoozeReminder 编排测试：
// 删旧建新锚点语义、删除失败仍建新（续排竞态下行已消失）、缓存失效。
import { beforeEach, describe, expect, it, vi } from "vitest";

const deleteMock = vi.fn<(id: number) => Promise<void>>();
const createMock = vi.fn<(input: unknown) => Promise<unknown>>();

vi.mock("@/lib/tauri", () => ({
  todoReminderDelete: (id: number) => deleteMock(id),
  todoReminderCreate: (input: unknown) => createMock(input),
}));

import {
  SNOOZE_PRESETS,
  remindAtClockLabel,
  snoozeRemindAt,
  snoozeReminder,
  snoozeTargetLabel,
} from "./reminder-snooze";

const MIN = 60_000;

/** QueryClient 替身：只需 invalidateQueries 可调用 */
const invalidateMock = vi.fn();
const qcLike = { invalidateQueries: invalidateMock } as unknown as Parameters<
  typeof snoozeReminder
>[4];

beforeEach(() => {
  deleteMock.mockReset();
  createMock.mockReset();
  invalidateMock.mockReset();
});

describe("snoozeRemindAt", () => {
  it("锚点为原 remind_at 而非 now：10:00 推迟 30 分钟 = 10:30", () => {
    const base = new Date(2026, 8, 5, 10, 0).getTime();
    expect(snoozeRemindAt(base, 30)).toBe(base + 30 * MIN);
  });

  it("三档预设为 10 / 30 / 60 分钟", () => {
    expect(SNOOZE_PRESETS.map((p) => p.minutes)).toEqual([10, 30, 60]);
  });
});

describe("snoozeReminder", () => {
  it("删旧建新：新行 remind_at = 原时间 + N 分钟，失效详情缓存", async () => {
    deleteMock.mockResolvedValue(undefined);
    createMock.mockResolvedValue({});
    const base = new Date(2026, 8, 5, 10, 0).getTime();

    const ok = await snoozeReminder(7, 3, base, 10, qcLike);

    expect(ok).toBe(true);
    expect(deleteMock).toHaveBeenCalledWith(7);
    expect(createMock).toHaveBeenCalledWith({ task_id: 3, remind_at: base + 10 * MIN });
    expect(qcLike.invalidateQueries).toHaveBeenCalled();
  });

  it("删除失败（续排竞态下行已消失）不阻断：仍新建推迟行", async () => {
    deleteMock.mockRejectedValue(new Error("row gone"));
    createMock.mockResolvedValue({});
    const base = new Date(2026, 8, 5, 10, 0).getTime();

    const ok = await snoozeReminder(7, 3, base, 60, qcLike);

    expect(ok).toBe(true);
    expect(createMock).toHaveBeenCalledWith({ task_id: 3, remind_at: base + 60 * MIN });
  });

  it("新建失败返回 false（不静默吞掉，调用方可回退提示）", async () => {
    deleteMock.mockResolvedValue(undefined);
    createMock.mockRejectedValue(new Error("db locked"));

    const ok = await snoozeReminder(7, 3, 0, 10, qcLike);

    expect(ok).toBe(false);
  });
});

describe("snoozeTargetLabel", () => {
  it("未来目标显示相对分钟；已过期目标回退钟点串", () => {
    const now = Date.now();
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date(2026, 8, 5, 10, 0));
      const base = new Date(2026, 8, 5, 9, 55).getTime();
      // 9:55 推迟 10 分钟 → 10:05，距 now 5 分钟
      expect(snoozeTargetLabel(base, 10)).toBe("5 分钟后");
      // 8:00 推迟 30 分钟 → 8:30 已过期 → 回退钟点
      expect(snoozeTargetLabel(new Date(2026, 8, 5, 8, 0).getTime(), 30)).toBe(
        remindAtClockLabel(new Date(2026, 8, 5, 8, 30).getTime()),
      );
    } finally {
      vi.useRealTimers();
    }
    expect(now).toBeGreaterThan(0);
  });
});
