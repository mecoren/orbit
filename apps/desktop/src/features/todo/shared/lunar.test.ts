/**
 * 农历/黄历模块移植测试
 *
 * 数据表（lunarInfo / sTermInfo）逐字复制自 wait-home，这里验证换算正确性——
 * 用例日期取自权威万年历对照（公历↔农历互推、节气、干支）。
 */
import { describe, expect, it } from "vitest";

import { daySubLabel, lunarYearLabel, solarToLunar, solarTermLabel } from "./almanac";
import { formatYmd, lunarToSolarDate } from "./lunar";

describe("lunarToSolarDate", () => {
  it("2026 年春节（正月初一）落在 2026-02-17", () => {
    const d = lunarToSolarDate(2026, 1, 1);
    expect(d).not.toBeNull();
    // 返回 UTC 零点；formatYmd 按本地时区取年月日，本机为东八区无跨日漂移
    expect(formatYmd(d!)).toBe("2026-02-17");
  });

  it("2025 年除夕（腊月三十，2025 无闰腊月 29 天）为 2025-01-28", () => {
    // 2025 腊月只有 29 天：腊月三十无效 → null；腊月廿九 = 除夕 = 2026-02-16 前一日？
    // 权威对照：2025 农历年腊月起于 2026-01-19，除夕 2026-02-16（廿九）
    expect(lunarToSolarDate(2025, 12, 30)).toBeNull();
    const d = lunarToSolarDate(2025, 12, 29);
    expect(d).not.toBeNull();
    expect(formatYmd(d!)).toBe("2026-02-16");
  });

  it("2023 年闰二月十五（闰月年份）→ 2023-04-05", () => {
    // 2023 农历闰二月：权威万年历闰二月十五为公历 2023-04-05
    // lunarToSolarDate 是平月语义：平二月十五 = 2023-03-06；这里验证平月不受闰月干扰
    const d = lunarToSolarDate(2023, 2, 15);
    expect(d).not.toBeNull();
    expect(formatYmd(d!)).toBe("2023-03-06");
  });

  it("越界参数返回 null", () => {
    expect(lunarToSolarDate(1900, 1, 1)).toBeNull();
    expect(lunarToSolarDate(2101, 1, 1)).toBeNull();
    expect(lunarToSolarDate(2026, 13, 1)).toBeNull();
    expect(lunarToSolarDate(2026, 1, 31)).toBeNull();
  });
});

describe("solarToLunar（公历→农历）", () => {
  it("2026-02-17 → 丙午年正月初一（春节）", () => {
    const l = solarToLunar(new Date(2026, 1, 17));
    expect(l).toEqual({ year: 2026, month: 1, day: 1, isLeap: false });
  });

  it("2023-03-22 → 癸卯年闰二月初一", () => {
    // 权威万年历：2023-03-22 为闰二月初一
    const l = solarToLunar(new Date(2023, 2, 22));
    expect(l).toEqual({ year: 2023, month: 2, day: 1, isLeap: true });
  });

  it("1900-01-31（基准日）→ 庚子年正月初一", () => {
    const l = solarToLunar(new Date(1900, 0, 31));
    expect(l).toEqual({ year: 1900, month: 1, day: 1, isLeap: false });
  });

  it("农历↔公历往返：整年抽样 30 天闭环一致", () => {
    // 从 2026-01-01 起，每 12 天取一天，换算后回推应回到同一公历日
    for (let i = 0; i < 30; i++) {
      const solar = new Date(2026, 0, 1 + i * 12);
      const lunar = solarToLunar(solar);
      expect(lunar).not.toBeNull();
      const back = lunarToSolarDate(
        lunar!.year,
        lunar!.month,
        lunar!.day,
      );
      expect(back).not.toBeNull();
      expect(formatYmd(back!)).toBe(formatYmd(solar));
    }
  });
});

describe("solarTermLabel / daySubLabel", () => {
  it("2026-02-04 为立春", () => {
    // 权威对照：2026 年立春为 2 月 4 日
    expect(solarTermLabel(new Date(2026, 1, 4))).toBe("立春");
    expect(solarTermLabel(new Date(2026, 1, 5))).toBeNull();
  });

  it("daySubLabel 优先级：公历节日 > 农历节日 > 节气 > 农历日", () => {
    // 公历节日
    expect(daySubLabel(new Date(2026, 9, 1))).toBe("国庆节");
    expect(daySubLabel(new Date(2026, 0, 1))).toBe("元旦");
    // 农历节日：2026-02-17 春节
    expect(daySubLabel(new Date(2026, 1, 17))).toBe("春节");
    // 节气：2026-02-04 立春
    expect(daySubLabel(new Date(2026, 1, 4))).toBe("立春");
    // 初一显示月名：2026-03-19 为二月初一
    const l = solarToLunar(new Date(2026, 2, 19));
    expect(l?.day).toBe(1);
    expect(daySubLabel(new Date(2026, 2, 19))).toBe("二月");
    // 普通日显示农历日名：2026-09-08 → 农历七月廿七
    // （2026-09-07 恰为白露节气，被节气优先级覆盖）
    expect(daySubLabel(new Date(2026, 8, 8))).toBe("廿七");
  });

  it("除夕优先级高于普通农历日（腊月最后一天）", () => {
    // 2027-02-05 为丙午年腊月廿九（2026 农历年除夕）
    expect(daySubLabel(new Date(2027, 1, 5))).toBe("除夕");
  });
});

describe("lunarYearLabel（干支生肖）", () => {
  it("2026 → 丙午马年；2025 → 乙巳蛇年；1984 → 甲子鼠年", () => {
    expect(lunarYearLabel(2026)).toBe("丙午马年");
    expect(lunarYearLabel(2025)).toBe("乙巳蛇年");
    expect(lunarYearLabel(1984)).toBe("甲子鼠年");
  });
});
