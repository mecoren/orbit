import { describe, expect, it } from "vitest";

import { consumeWheelStep, WHEEL_STEP_THRESHOLD_PX } from "./wheel-nav";

describe("consumeWheelStep", () => {
  it("阈值以下只累积不触发", () => {
    const r = consumeWheelStep(0, WHEEL_STEP_THRESHOLD_PX - 1);
    expect(r.fire).toBe(false);
    expect(r.rest).toBe(WHEEL_STEP_THRESHOLD_PX - 1);
  });

  it("跨阈值触发一次并保留余量", () => {
    const r = consumeWheelStep(10, WHEEL_STEP_THRESHOLD_PX);
    expect(r.fire).toBe(true);
    expect(r.dir).toBe(1);
    expect(r.rest).toBe(10);
  });

  it("负方向对称", () => {
    const r = consumeWheelStep(-10, -WHEEL_STEP_THRESHOLD_PX);
    expect(r.fire).toBe(true);
    expect(r.dir).toBe(-1);
    expect(r.rest).toBe(-10);
  });

  it("多次小增量累积后触发（触控板慢滑）", () => {
    let acc = 0;
    let fired = 0;
    for (const d of [8, 8, 8, 8]) {
      const r = consumeWheelStep(acc, d);
      acc = r.rest;
      if (r.fire) fired += 1;
    }
    expect(fired).toBe(1);
    expect(acc).toBe(32 - WHEEL_STEP_THRESHOLD_PX);
  });

  it("零位移不触发不改累积", () => {
    const r = consumeWheelStep(5, 0);
    expect(r.fire).toBe(false);
    expect(r.rest).toBe(5);
  });
});
