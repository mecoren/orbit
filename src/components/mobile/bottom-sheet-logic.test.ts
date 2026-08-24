import { describe, expect, it } from "vitest";
import { pickSnapIndex, springStep } from "./bottom-sheet-logic";

describe("pickSnapIndex", () => {
  const snaps = [350, 650, 800]; // px（屏高 800 例：min .35 / initial .65 / max 1.0）
  it("静止时吸附最近点", () => {
    expect(pickSnapIndex(600, 0, snaps)).toBe(1);
  });
  it("快速上滑(负速度)强制向上选点", () => {
    expect(pickSnapIndex(640, -600, snaps)).toBe(2);
  });
  it("快速下滑(正速度)强制向下选点", () => {
    expect(pickSnapIndex(360, 600, snaps)).toBe(0);
  });
  it("慢速时阈值内就近", () => {
    expect(pickSnapIndex(500, 100, snaps)).toBe(0);
  });
});

describe("springStep", () => {
  it("朝目标收敛", () => {
    let [p, v] = [800, 0];
    for (let i = 0; i < 200; i++) [p, v] = springStep(p, v, 520, 170, 24, 1 / 60);
    expect(Math.abs(p - 520)).toBeLessThan(1);
    expect(Math.abs(v)).toBeLessThan(5);
  });
});
