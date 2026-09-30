import { describe, expect, it } from "vitest";

import { GRID_COLS, MONTH_GRID_ROWS, buildMonthGrid, buildWeekGrid } from "./calendar-grid";
import { formatYmd } from "./date-utils";

describe("buildMonthGrid", () => {
  const grid = buildMonthGrid(2026, 8); // 2026-09

  it("恒 6×7 = 42 格，首格为周一", () => {
    expect(grid).toHaveLength(GRID_COLS * MONTH_GRID_ROWS);
    expect(grid).toHaveLength(42);
    expect(grid[0].getDay()).toBe(1);
  });

  it("逐格递增一天（含前后月补位无空洞）", () => {
    for (let i = 1; i < grid.length; i++) {
      expect(grid[i].getTime() - grid[i - 1].getTime()).toBe(86_400_000);
    }
  });

  it("首格不晚于当月 1 号，末格不早于当月最后一天", () => {
    expect(grid[0].getTime()).toBeLessThanOrEqual(new Date(2026, 8, 1).getTime());
    expect(grid[41].getTime()).toBeGreaterThanOrEqual(new Date(2026, 8, 30).getTime());
  });

  it("2026-09 首格为 8月31日（9/1 是周二，需补 1 格）", () => {
    expect(formatYmd(grid[0])).toBe("2026-08-31");
    expect(formatYmd(grid[6])).toBe("2026-09-06");
  });

  it("行数恒定：28 天的 2 月同样 42 格", () => {
    expect(buildMonthGrid(2026, 1)).toHaveLength(42);
    expect(buildMonthGrid(2027, 1)).toHaveLength(42);
  });
});

describe("buildWeekGrid", () => {
  it("恒 7 格且周一→周日", () => {
    const week = buildWeekGrid(new Date(2026, 8, 1)); // 周二
    expect(week).toHaveLength(7);
    expect(formatYmd(week[0])).toBe("2026-08-31");
    expect(formatYmd(week[6])).toBe("2026-09-06");
    expect(week.map((d) => d.getDay())).toEqual([1, 2, 3, 4, 5, 6, 0]);
  });

  it("锚点为周日时归入**本周**（首格为其前 6 天的周一）", () => {
    const week = buildWeekGrid(new Date(2026, 7, 30, 20, 0)); // 2026-08-30 周日
    expect(formatYmd(week[0])).toBe("2026-08-24");
    expect(formatYmd(week[6])).toBe("2026-08-30");
  });

  it("锚点时刻被归一化（同日任意时刻得同一周）", () => {
    const a = buildWeekGrid(new Date(2026, 8, 3, 0, 0));
    const b = buildWeekGrid(new Date(2026, 8, 3, 23, 59));
    expect(a.map(formatYmd)).toEqual(b.map(formatYmd));
  });

  it("跨年周原样返回 7 天（不裁剪月份）", () => {
    const week = buildWeekGrid(new Date(2027, 0, 1)); // 2027-01-01 周五
    expect(formatYmd(week[0])).toBe("2026-12-28");
    expect(formatYmd(week[6])).toBe("2027-01-03");
  });

  it("相邻周恰好相差 7 天（翻页口径）", () => {
    const cur = buildWeekGrid(new Date(2026, 8, 3));
    const next = buildWeekGrid(new Date(2026, 8, 10));
    expect(next[0].getTime() - cur[0].getTime()).toBe(7 * 86_400_000);
  });
});
