/**
 * 节假日范围补写进度文案与百分比（纯函数）
 *
 * 事件链路本身（core 广播 → Tauri emit → listen）由 e2e/mock 覆盖，
 * 这里只锁住「进度 → 展示文案」的映射，含 AC-E7 的「无数据」措辞。
 */
import { describe, expect, it } from "vitest";

import {
  holidayProgressLabel,
  holidayProgressPercent,
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
