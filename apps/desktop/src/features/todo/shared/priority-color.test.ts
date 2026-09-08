/**
 * 优先级色板口径单测：P0「无」转正浅灰 #D1D5DB，六档全显
 * （列表竖条/看板条/日历圆点/各选择器/统计图共用 PRIORITY_COLOR）
 */
import { describe, expect, it } from "vitest";
import { PRIORITY_COLOR, PRIORITY_LABELS } from "./constants";

describe("PRIORITY_COLOR 优先级六档色板", () => {
  it("六档每档都有色（P0「无」浅灰，不再空串隐藏）", () => {
    expect(PRIORITY_COLOR).toHaveLength(6);
    for (const c of PRIORITY_COLOR) expect(c).toMatch(/^#[0-9A-F]{6}$/i);
  });

  it("P0 浅灰与 P1 灰可区分（低明度档不撞色）", () => {
    expect(PRIORITY_COLOR[0]).toBe("#D1D5DB");
    expect(PRIORITY_COLOR[1]).toBe("#6B7280");
    expect(PRIORITY_COLOR[0]).not.toBe(PRIORITY_COLOR[1]);
  });

  it("色板与文案档位一一对齐", () => {
    expect(PRIORITY_LABELS).toHaveLength(PRIORITY_COLOR.length);
  });
});
