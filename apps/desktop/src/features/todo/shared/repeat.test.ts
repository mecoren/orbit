/**
 * repeat.ts 单测：月高级语义标签 + TS nth 步进（与 Rust 同口径，固定日期锁定）。
 */
import { describe, expect, it } from "vitest";

import {
  firstWeekdayInMask,
  nextMonthlyNth,
  nextRepeatLabel,
  nthWeekLabel,
  nthWeekdayInMonth,
  REPEAT_MODE,
  REPEAT_MONTH_MODE,
  REPEAT_NTH_LAST,
  repeatLabel,
} from "./repeat";

const TUE = 2; // 周二 bit
const TUE_MON0 = 1; // 周二（周一=0）

describe("nthWeekLabel / firstWeekdayInMask", () => {
  it("序数中文 + 末", () => {
    expect(nthWeekLabel(2)).toBe("第 2 个");
    expect(nthWeekLabel(REPEAT_NTH_LAST)).toBe("最后一个");
    expect(nthWeekLabel(0)).toBeNull();
    expect(nthWeekLabel(9)).toBeNull();
  });

  it("掩码最低位", () => {
    expect(firstWeekdayInMask(0b10101)).toBe(0); // 一三五 → 周一
    expect(firstWeekdayInMask(TUE)).toBe(1);
    expect(firstWeekdayInMask(0)).toBeNull();
  });
});

describe("repeatLabel 月高级语义", () => {
  it("每月第 2 个周二", () => {
    expect(
      repeatLabel(REPEAT_MODE.MONTHLY, 1, { monthMode: REPEAT_MONTH_MODE.NTH, nthWeek: 2, weekdays: TUE }),
    ).toBe("每月第 2 个周二");
  });

  it("每 N 个月 + 末个周五", () => {
    expect(
      repeatLabel(REPEAT_MODE.MONTHLY, 2, { monthMode: REPEAT_MONTH_MODE.NTH, nthWeek: REPEAT_NTH_LAST, weekdays: 16 }),
    ).toBe("每 2 个月最后一个周五");
  });

  it("日号模式与非法配置回落", () => {
    expect(repeatLabel(REPEAT_MODE.MONTHLY, 1)).toBe("每月");
    expect(
      repeatLabel(REPEAT_MODE.MONTHLY, 1, { monthMode: REPEAT_MONTH_MODE.NTH, nthWeek: 2, weekdays: 0 }),
    ).toBe("每月");
    expect(
      repeatLabel(REPEAT_MODE.MONTHLY, 1, { monthMode: REPEAT_MONTH_MODE.NTH, nthWeek: 9, weekdays: TUE }),
    ).toBe("每月");
  });

  it("后缀照常拼接", () => {
    expect(
      repeatLabel(REPEAT_MODE.MONTHLY, 1, {
        monthMode: REPEAT_MONTH_MODE.NTH,
        nthWeek: 2,
        weekdays: TUE,
        fromDone: 1,
      }),
    ).toBe("每月第 2 个周二（按完成日）");
  });
});

describe("nthWeekdayInMonth", () => {
  it("第 2 个周二 / 末个周五 / 缺月 null", () => {
    expect(nthWeekdayInMonth(2026, 0, 2, TUE_MON0)).toBe(13); // 1 月
    expect(nthWeekdayInMonth(2026, 3, 6, 4)).toBe(24); // 4 月末个周五
    expect(nthWeekdayInMonth(2026, 6, 5, 0)).toBeNull(); // 7 月无第 5 个周一
    expect(nthWeekdayInMonth(2026, 7, 5, 0)).toBe(31); // 8 月第 5 个周一
  });
});

describe("nextMonthlyNth（与 Rust 同口径）", () => {
  const at = (y: number, m0: number, d: number, h = 18, mi = 0) =>
    new Date(y, m0, d, h, mi).getTime();

  it("第 2 个周二：1/13 → 2/10，时刻沿用", () => {
    const base = at(2026, 0, 13);
    expect(nextMonthlyNth(base, 1, TUE_MON0, 2, base)).toBe(at(2026, 1, 10));
    // 30 分时刻同样沿用
    expect(nextMonthlyNth(at(2026, 0, 13, 18, 30), 1, TUE_MON0, 2, base)).toBe(
      at(2026, 1, 10, 18, 30),
    );
  });

  it("第 5 个周一跳过缺月：6/29 → 8/31", () => {
    const base = at(2026, 5, 29, 9);
    expect(nextMonthlyNth(base, 1, 0, 5, base)).toBe(at(2026, 7, 31, 9));
  });

  it("末个周五 + 每 2 月", () => {
    expect(nextMonthlyNth(at(2026, 2, 27, 9), 1, 4, REPEAT_NTH_LAST, at(2026, 2, 27, 9))).toBe(
      at(2026, 3, 24, 9),
    );
    expect(nextMonthlyNth(at(2026, 0, 13), 2, TUE_MON0, 2, at(2026, 0, 13))).toBe(
      at(2026, 2, 10),
    );
  });
});

describe("nextRepeatLabel 月高级语义", () => {
  it("nth 规则预览具体日期", () => {
    const base = new Date(2026, 0, 13, 18).getTime();
    expect(
      nextRepeatLabel(REPEAT_MODE.MONTHLY, 1, base, base, 0, {
        monthMode: REPEAT_MONTH_MODE.NTH,
        nthWeek: 2,
        weekdays: TUE,
      }),
    ).toBe("2月10日（周二）");
  });

  it("非法配置回落日号预览（不抛 null 也不误导）", () => {
    const base = new Date(2026, 0, 31, 9).getTime();
    expect(
      nextRepeatLabel(REPEAT_MODE.MONTHLY, 1, base, base, 0, {
        monthMode: REPEAT_MONTH_MODE.NTH,
        nthWeek: 2,
        weekdays: 0,
      }),
    ).toBe("2月28日（周六）");
  });
});
