// apps/desktop/src/features/todo/shared/view-create-defaults.test.ts
// 视图内新增自动带标记的默认值矩阵（#39）：
// 周五锚点边界 + 四视图注入值 + 无标记视图返回空。
// 截止时刻口径（2026-09-09 修订）：今日/本周一律落当日 18:00；
// 我的一天标记保持零点（视图过滤精确匹配今天零点）。
// 基准：周一起始周（与日历网格一致），本地时区。
import { describe, expect, it } from "vitest";

import {
  atViewDueHour,
  quickViewCreateDefaults,
  weekDefaultDueMs,
} from "./view-create-defaults";

/** 当日 18:00（本地时区） */
const at18 = (m: number, d: number) => new Date(2026, m - 1, d, 18).getTime();
const midnight = (m: number, d: number) => new Date(2026, m - 1, d).getTime();

describe("atViewDueHour · 截止时刻归一到 18:00", () => {
  it("任意时刻 → 当日 18:00（保留日期）", () => {
    expect(atViewDueHour(new Date(2026, 8, 9, 0, 0).getTime())).toBe(at18(9, 9));
    expect(atViewDueHour(new Date(2026, 8, 9, 9, 30).getTime())).toBe(at18(9, 9));
    expect(atViewDueHour(new Date(2026, 8, 9, 23, 59).getTime())).toBe(at18(9, 9));
    expect(atViewDueHour(at18(9, 9))).toBe(at18(9, 9)); // 已是 18 点幂等
  });
  it("跨月边界：09-30 23:00 → 09-30 18:00（日期不进位）", () => {
    expect(atViewDueHour(new Date(2026, 8, 30, 23, 0).getTime())).toBe(at18(9, 30));
  });
});

describe("weekDefaultDueMs · 本周默认截止（周五锚点 18:00，周末→周日）", () => {
  it("周一 → 当周周五 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 7))).toBe(at18(9, 11)); // 2026-09-07 周一
  });
  it("周三 → 当周周五 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 9))).toBe(at18(9, 11));
  });
  it("周五（当天深夜）→ 周五 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 11, 23, 59))).toBe(at18(9, 11));
  });
  it("周六 → 周日 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 12))).toBe(at18(9, 13));
  });
  it("周日 → 周日 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 13))).toBe(at18(9, 13));
  });
  it("跨月边界：周三 09-30 → 周五 10-02 18:00", () => {
    expect(weekDefaultDueMs(new Date(2026, 8, 30))).toBe(at18(10, 2));
  });
});

describe("quickViewCreateDefaults · 四视图注入矩阵", () => {
  it("我的一天 → my_day_date = 今天零点（保持零点：过滤精确匹配）", () => {
    const r = quickViewCreateDefaults("my_day", new Date(2026, 8, 9, 15, 0));
    expect(r.myDayMs).toBe(midnight(9, 9));
    expect(r.dueMs).toBeUndefined();
    expect(r.favorite).toBeUndefined();
  });
  it("今天截止 → due_date = 今天 18:00", () => {
    const r = quickViewCreateDefaults("today", new Date(2026, 8, 9, 15, 0));
    expect(r.dueMs).toBe(at18(9, 9));
    expect(r.myDayMs).toBeUndefined();
    expect(r.favorite).toBeUndefined();
  });
  it("本周截止 → due_date = 当周周五 18:00", () => {
    const r = quickViewCreateDefaults("week", new Date(2026, 8, 9, 15, 0)); // 周三
    expect(r.dueMs).toBe(at18(9, 11));
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
    // 同一调用点不同时刻返回各自 18 点（供提交瞬间重算口径锚定）
    expect(quickViewCreateDefaults("today", new Date(2026, 8, 9, 23, 59)).dueMs).toBe(
      at18(9, 9),
    );
    expect(quickViewCreateDefaults("today", new Date(2026, 8, 10, 0, 1)).dueMs).toBe(
      at18(9, 10),
    );
  });
});
