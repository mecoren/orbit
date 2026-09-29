/**
 * 节假日范围补写进度文案与百分比（纯函数）
 *
 * 事件链路本身（core 广播 → Tauri emit → listen）由 e2e/mock 覆盖，
 * 这里只锁住「进度 → 展示文案」的映射，含 AC-E7 的「无数据」措辞，
 * 以及 `applyHolidayProgress` 对失败年份的收集（部分成功如实上报的依据）。
 */
import { describe, expect, it } from "vitest";

import {
  INITIAL_HOLIDAY_PROGRESS,
  applyHolidayProgress,
  holidayFailedYearsLabel,
  holidayProgressLabel,
  holidayProgressPercent,
  type HolidayProgressState,
} from "./use-holiday-progress";

describe("holidayProgressLabel", () => {
  it("空值不产出文案", () => {
    expect(holidayProgressLabel(null)).toBe("");
  });

  it("起始阶段带上总年份数", () => {
    expect(holidayProgressLabel({ phase: "starting", total: 5 })).toContain("5");
  });

  it("逐年阶段带 done/total 与年份结果", () => {
    expect(
      holidayProgressLabel({
        phase: "year",
        year: 2022,
        done: 2,
        total: 5,
        ok: true,
        empty: false,
      }),
    ).toContain("2/5");
    expect(
      holidayProgressLabel({
        phase: "year",
        year: 2020,
        done: 1,
        total: 5,
        ok: true,
        empty: true,
      }),
    ).toContain("无数据");
    expect(
      holidayProgressLabel({
        phase: "year",
        year: 2019,
        done: 1,
        total: 5,
        ok: false,
        empty: false,
      }),
    ).toContain("失败");
  });

  it("终态区分取消与部分失败", () => {
    expect(
      holidayProgressLabel({ phase: "done", ok: 3, failed: 1, cancelled: false }),
    ).toContain("失败 1");
    expect(
      holidayProgressLabel({ phase: "done", ok: 3, failed: 0, cancelled: true }),
    ).toContain("已取消");
  });

  it("错误阶段直出原始信息", () => {
    expect(
      holidayProgressLabel({ phase: "error", message: "参数非法" }),
    ).toBe("参数非法");
  });
});

describe("holidayProgressPercent", () => {
  it("逐年阶段按 done/total 折算，终态退化为不确定态", () => {
    expect(holidayProgressPercent(null)).toBeNull();
    expect(holidayProgressPercent({ phase: "starting", total: 4 })).toBe(0);
    expect(
      holidayProgressPercent({
        phase: "year",
        year: 2020,
        done: 1,
        total: 4,
        ok: true,
        empty: false,
      }),
    ).toBe(25);
    expect(
      holidayProgressPercent({ phase: "done", ok: 4, failed: 0, cancelled: false }),
    ).toBeNull();
    expect(
      holidayProgressPercent({ phase: "error", message: "x" }),
    ).toBeNull();
  });
});

describe("applyHolidayProgress", () => {
  const fold = (events: Parameters<typeof applyHolidayProgress>[1][]) =>
    events.reduce<HolidayProgressState>(
      (acc, e) => applyHolidayProgress(acc, e),
      INITIAL_HOLIDAY_PROGRESS,
    );

  it("逐年事件里失败的年份被收集，取消/无数据不计入", () => {
    const state = fold([
      { phase: "starting", total: 3 },
      { phase: "year", year: 2013, done: 1, total: 3, ok: true, empty: false },
      { phase: "year", year: 2014, done: 2, total: 3, ok: false, empty: false },
      { phase: "year", year: 2015, done: 3, total: 3, ok: true, empty: true },
      { phase: "done", ok: 2, failed: 1, cancelled: false },
    ]);
    expect(state.failedYears).toEqual([2014]);
  });

  it("同一轮内重复年份不重复收集", () => {
    const state = fold([
      { phase: "starting", total: 1 },
      { phase: "year", year: 2014, done: 1, total: 1, ok: false, empty: false },
      { phase: "year", year: 2014, done: 1, total: 1, ok: false, empty: false },
    ]);
    expect(state.failedYears).toEqual([2014]);
  });

  it("新一轮 starting 清空上一轮的失败年份", () => {
    const state = fold([
      { phase: "starting", total: 1 },
      { phase: "year", year: 2014, done: 1, total: 1, ok: false, empty: false },
      { phase: "done", ok: 0, failed: 1, cancelled: false },
      { phase: "starting", total: 2 },
    ]);
    expect(state.failedYears).toEqual([]);
  });
});

describe("holidayFailedYearsLabel", () => {
  it("升序顿号分隔；空列表返回空串", () => {
    expect(holidayFailedYearsLabel([2016, 2014])).toBe("2014、2016");
    expect(holidayFailedYearsLabel([])).toBe("");
  });
});
