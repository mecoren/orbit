import { describe, expect, it } from "vitest";

import type { HolidayInfo } from "@/lib/tauri";
import {
  groupHolidaysByYear,
  holidayMdLabel,
  summarizeHolidayCache,
} from "./calendar-cache-format";

/** 形状对齐 `ipc-mock.ts` MOCK_HOLIDAYS（2026 真实数据节选） */
const ROWS: HolidayInfo[] = [
  { date: "2026-01-01", year: 2026, is_holiday: true, name: "元旦" },
  { date: "2026-01-04", year: 2026, is_holiday: false, name: "元旦后补班" },
  { date: "2026-02-17", year: 2026, is_holiday: true, name: "初一" },
  { date: "2025-10-01", year: 2025, is_holiday: true, name: "国庆节" },
];

describe("summarizeHolidayCache", () => {
  it("总数与放假/补班拆分", () => {
    expect(summarizeHolidayCache(ROWS)).toEqual({
      total: 4,
      offDays: 3,
      workdays: 1,
      years: [2026, 2025],
    });
  });

  it("空缓存汇总为零（行内出空态，不崩）", () => {
    expect(summarizeHolidayCache([])).toEqual({
      total: 0,
      offDays: 0,
      workdays: 0,
      years: [],
    });
  });
});

describe("groupHolidaysByYear", () => {
  it("年份倒序、组内保持 date 升序", () => {
    const groups = groupHolidaysByYear(ROWS);
    expect(groups.map((g) => g.year)).toEqual([2026, 2025]);
    expect(groups[0]?.items.map((h) => h.date)).toEqual([
      "2026-01-01",
      "2026-01-04",
      "2026-02-17",
    ]);
  });
});

describe("holidayMdLabel", () => {
  it("YYYY-MM-DD → M月D日（去前导零）", () => {
    expect(holidayMdLabel("2026-01-01")).toBe("1月1日");
    expect(holidayMdLabel("2026-02-17")).toBe("2月17日");
  });

  it("脏串原样返回", () => {
    expect(holidayMdLabel("not-a-date")).toBe("not-a-date");
  });
});
