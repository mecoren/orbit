import { describe, expect, it } from "vitest";
import { buildQuickDateOptions, buildQuickDateTimeOptions } from "./quick-dates";

describe("buildQuickDateOptions", () => {
  it("今天/明天/下周（下周一零点），提示为周短文案", () => {
    const now = new Date(2026, 7, 25, 15, 0); // 2026-08-25 周二
    const [today, tomorrow, nextWeek] = buildQuickDateOptions(now);
    expect(today.label).toBe("今天");
    expect(today.hint).toBe("周二");
    expect(today.value).toEqual(new Date(2026, 7, 25));
    expect(tomorrow.label).toBe("明天");
    expect(tomorrow.hint).toBe("周三");
    expect(tomorrow.value).toEqual(new Date(2026, 7, 26));
    expect(nextWeek.label).toBe("下周");
    expect(nextWeek.hint).toBe("周一");
    expect(nextWeek.value).toEqual(new Date(2026, 7, 31));
  });

  it("今天为周一时「下周」仍取下周一", () => {
    const now = new Date(2026, 7, 24, 9, 0); // 周一
    const nextWeek = buildQuickDateOptions(now)[2];
    expect(nextWeek.value).toEqual(new Date(2026, 7, 31));
  });

  it("周日时「下周」取明天", () => {
    const now = new Date(2026, 7, 30, 9, 0); // 周日
    const nextWeek = buildQuickDateOptions(now)[2];
    expect(nextWeek.value).toEqual(new Date(2026, 7, 31));
  });
});

describe("buildQuickDateTimeOptions", () => {
  it("一小时后/今天晚些时候/明天 09:00/下周 09:00", () => {
    const now = new Date(2026, 7, 25, 15, 0);
    const opts = buildQuickDateTimeOptions(now);
    expect(opts.map((o) => o.key)).toEqual(["in1h", "tonight", "tomorrow", "nextWeek"]);
    expect(opts[0].value).toEqual(new Date(2026, 7, 25, 16, 0));
    expect(opts[0].hint).toBe("16:00");
    expect(opts[1].value).toEqual(new Date(2026, 7, 25, 22, 0));
    expect(opts[1].hint).toBe("22:00");
    expect(opts[2].value).toEqual(new Date(2026, 7, 26, 9, 0));
    expect(opts[2].hint).toBe("周三, 09:00");
    expect(opts[3].value).toEqual(new Date(2026, 7, 31, 9, 0));
    expect(opts[3].hint).toBe("周一, 09:00");
  });

  it("已过 22:00 隐藏「今天晚些时候」", () => {
    const now = new Date(2026, 7, 25, 23, 0);
    const opts = buildQuickDateTimeOptions(now);
    expect(opts.some((o) => o.key === "tonight")).toBe(false);
  });
});
