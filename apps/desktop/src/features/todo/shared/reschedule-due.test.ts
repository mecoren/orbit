import { describe, expect, it } from "vitest";

import { rescheduleDue } from "./reschedule-due";

describe("rescheduleDue 拖拽改期时间语义", () => {
  it("无截止任务落到目标日 18:00", () => {
    const target = new Date(2026, 8, 20); // 9月20日
    expect(rescheduleDue(null, target)).toBe(
      new Date(2026, 8, 20, 18, 0, 0, 0).getTime(),
    );
  });

  it("原截止零点（仅日期语义）落到目标日 18:00", () => {
    const orig = new Date(2026, 8, 10, 0, 0, 0, 0).getTime();
    const target = new Date(2026, 8, 20);
    expect(rescheduleDue(orig, target)).toBe(
      new Date(2026, 8, 20, 18, 0, 0, 0).getTime(),
    );
  });

  it("原截止带时刻 → 保留时分只换日期", () => {
    const orig = new Date(2026, 8, 10, 15, 30, 0, 0).getTime();
    const target = new Date(2026, 8, 20, 3, 0, 0, 0); // 目标取日期分量，时刻无关
    expect(rescheduleDue(orig, target)).toBe(
      new Date(2026, 8, 20, 15, 30, 0, 0).getTime(),
    );
  });

  it("同日落回原处返回 null（不写库）", () => {
    const orig = new Date(2026, 8, 10, 15, 30, 0, 0).getTime();
    const target = new Date(2026, 8, 10);
    expect(rescheduleDue(orig, target)).toBeNull();
  });

  it("零点同日同样返回 null", () => {
    const orig = new Date(2026, 8, 10, 0, 0, 0, 0).getTime();
    const target = new Date(2026, 8, 10);
    expect(rescheduleDue(orig, target)).toBeNull();
  });

  it("跨月/跨年边界正确换算", () => {
    const orig = new Date(2026, 11, 30, 9, 0, 0, 0).getTime();
    const target = new Date(2027, 0, 2);
    expect(rescheduleDue(orig, target)).toBe(
      new Date(2027, 0, 2, 9, 0, 0, 0).getTime(),
    );
  });
});
