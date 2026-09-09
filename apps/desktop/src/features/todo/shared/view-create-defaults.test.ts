// apps/desktop/src/features/todo/shared/view-create-defaults.test.ts
// 视图内新增自动带标记的默认值矩阵（#39）：
// 周五锚点边界 + 四视图注入值 + 无标记视图返回空。
// 基准：周一起始周（与日历网格一致），本地时区零点。
import { describe, expect, it } from "vitest";

import { quickViewCreateDefaults, weekDefaultDueMs } from "./view-create-defaults";

const midnight = (m: number, d: number) => new Date(2026, m - 1, d).getTime();

describe("weekDefaultDueMs · 本周默认截止（周五锚点，过周五→周日）", () => {
  it("周一 → 当周周五", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 7))).toBe(midnight(9, 11)); // 周一 09-07
  });
  it("周三 → 当周周五", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 9))).toBe(midnight(9, 11));
  });
  it("周五（当天）→ 周五零点（未过）", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 11, 23, 59))).toBe(midnight(9, 11));
  });
  it("周六 → 周日", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 12))).toBe(midnight(9, 13));
  });
  it("周日 → 周日", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 13))).toBe(midnight(9, 13));
  });
  it("跨月边界：周三 09-30 → 周五 10-02", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 30))).toBe(midnight(10, 2));
  });
});

describe("quickViewCreateDefaults · 四视图注入矩阵", () => {
  it("我的一天 → my_day_date = 今天零点", () => {
    const r = quickViewCreateDefaults("my_day", new Date(2026, 8, 9, 15, 0));
    expect(r.myDayMs).toBe(midnight(9, 9));
    expect(r.dueMs).toBeUndefined();
    expect(r.favorite).toBeUndefined();
  });
  it("今天截止 → due_date = 今天零点", () => {
    const r = quickViewCreateDefaults("today", new Date(2026, 8, 9, 15, 0));
    expect(r.dueMs).toBe(midnight(9, 9));
    expect(r.myDayMs).toBeUndefined();
    expect(r.favorite).toBeUndefined();
  });
  it("本周截止 → due_date = 当周周五", () => {
    const r = quickViewCreateDefaults("week", new Date(2026, 8, 9, 15, 0)); // 周三
    expect(r.dueMs).toBe(midnight(9, 11));
  });
  it("收藏 → is_favorite = 1", () => {
    const r = quickViewCreateDefaults("favorite", new Date(2026, 8, 9, 15, 0));
    expect(r.favorite).toBe(1);
    expect(r.dueMs).toBeUndefined();
    expect(r.myDayMs).toBeUndefined();
  });
  it("无标记视图（all/undone/done）与 null → 空", () => {
    for (const v of ["all", "undone", "done", null, undefined] as const) {
      expect(quickViewCreateDefaults(v as never)).toEqual({});
    }
  });
  it("跨零点安全：默认值以传入时刻重算，不缓存", () => {
    // 同一调用点不同时刻返回各自零点（供提交瞬间重算口径锚定）
    expect(quickViewCreateDefaults("today", new Date(2026, 8, 9, 23, 59)).dueMs).toBe(
      midnight(9, 9),
    );
    expect(quickViewCreateDefaults("today", new Date(2026, 8, 10, 0, 1)).dueMs).toBe(
      midnight(9, 10),
    );
  });
});
