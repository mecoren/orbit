import { describe, expect, it } from "vitest";

import {
  addDays,
  dayKey,
  dayLabel,
  formatYmd,
  relativeLabel,
  startOfDay,
  startOfWeek,
  weekRangeLabel,
} from "./date-utils";

describe("startOfDay / addDays", () => {
  it("归零到本地零点且不改原实例", () => {
    const src = new Date(2026, 8, 6, 23, 59, 59, 999);
    const zero = startOfDay(src);
    expect(zero).toEqual(new Date(2026, 8, 6));
    expect(src.getHours()).toBe(23); // 原实例未被 mutate
  });

  it("跨月 / 跨年正确进位", () => {
    expect(addDays(new Date(2026, 8, 30), 1)).toEqual(new Date(2026, 9, 1));
    expect(addDays(new Date(2026, 11, 31), 1)).toEqual(new Date(2027, 0, 1));
    expect(addDays(new Date(2027, 0, 1), -1)).toEqual(new Date(2026, 11, 31));
  });

  it("闰年 2 月 29 日存在（2028 为闰年）", () => {
    expect(addDays(new Date(2028, 1, 28), 1)).toEqual(new Date(2028, 1, 29));
  });
});

describe("startOfWeek", () => {
  it("周一锚点返回自身（零点）", () => {
    expect(startOfWeek(new Date(2026, 7, 24, 13, 0))).toEqual(new Date(2026, 7, 24));
  });

  it("周日锚点退回**本周**周一（不得前滚到下周）", () => {
    // 2026-08-30 是周日，其所在周为 08-24（周一）～ 08-30
    expect(startOfWeek(new Date(2026, 7, 30, 9, 0))).toEqual(new Date(2026, 7, 24));
  });

  it("周六锚点回到本周一", () => {
    expect(startOfWeek(new Date(2026, 7, 29))).toEqual(new Date(2026, 7, 24));
  });

  it("跨月周的周一落在上个月", () => {
    // 2026-09-01 是周二 → 本周一为 2026-08-31
    expect(startOfWeek(new Date(2026, 8, 1))).toEqual(new Date(2026, 7, 31));
  });

  it("跨年周的周一落在上一年", () => {
    // 2027-01-01 是周五 → 本周一为 2026-12-28
    expect(startOfWeek(new Date(2027, 0, 1))).toEqual(new Date(2026, 11, 28));
  });
});

describe("formatYmd / dayKey", () => {
  it("月日补零到两位", () => {
    expect(formatYmd(new Date(2026, 0, 5))).toBe("2026-01-05");
    expect(formatYmd(new Date(2026, 11, 31, 23, 30))).toBe("2026-12-31");
  });

  it("毫秒时间戳按本地时区取年月日", () => {
    expect(dayKey(new Date(2026, 8, 6, 12, 0).getTime())).toBe("2026-09-06");
    // 本地日界两侧：23:59 与次日 00:00 分属两天
    expect(dayKey(new Date(2026, 8, 6, 23, 59).getTime())).toBe("2026-09-06");
    expect(dayKey(new Date(2026, 8, 7, 0, 0).getTime())).toBe("2026-09-07");
  });

  it("定宽零填充使字典序即时间序（周档区间过滤依赖）", () => {
    const a = formatYmd(new Date(2026, 8, 9));
    const b = formatYmd(new Date(2026, 9, 1));
    expect(a < b).toBe(true);
  });
});

describe("relativeLabel", () => {
  it("今天 / N天后 / N天前", () => {
    const today = new Date();
    expect(relativeLabel(today)).toBe("今天");
    expect(relativeLabel(addDays(today, 3))).toBe("3天后");
    expect(relativeLabel(addDays(today, -2))).toBe("2天前");
  });

  it("同日不同时刻仍判为今天（按零点对齐）", () => {
    const base = new Date(2026, 8, 6, 8, 0);
    const late = new Date(2026, 8, 6, 23, 50);
    const diff = Math.round(
      (startOfDay(late).getTime() - startOfDay(base).getTime()) / 86_400_000,
    );
    expect(diff).toBe(0);
  });
});

describe("dayLabel / weekRangeLabel", () => {
  it("中文日期标签", () => {
    expect(dayLabel(new Date(2026, 8, 6))).toBe("9月6日");
  });

  it("同年周区间不带年份", () => {
    expect(weekRangeLabel(new Date(2026, 8, 1), new Date(2026, 8, 7))).toBe(
      "9月1日 – 9月7日",
    );
  });

  it("跨月周区间两端各带月份", () => {
    expect(weekRangeLabel(new Date(2026, 7, 31), new Date(2026, 8, 6))).toBe(
      "8月31日 – 9月6日",
    );
  });

  it("跨年周区间起点前置年份", () => {
    expect(weekRangeLabel(new Date(2026, 11, 28), new Date(2027, 0, 3))).toBe(
      "2026年12月28日 – 1月3日",
    );
  });
});
