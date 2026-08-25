import { describe, expect, it } from "vitest";
import { DELAYS, createBlock, stepBlock } from "./eq-spinner-physics";

const DT = 1 / 60;

describe("eq-spinner 物理模型（蓝本 bounce-blocks 移植回归）", () => {
  it("挤压量恒有界（不发散、无 NaN）——回归：触地冲量逐帧泵入导致翻转爆炸", () => {
    const blocks = DELAYS.map((d) => createBlock(d));
    let ok = true;
    for (let i = 0; i < Math.round(10 / DT); i++) {
      for (const b of blocks) stepBlock(b, DT);
      for (const b of blocks) {
        if (!Number.isFinite(b.squash) || b.squash < -0.6 || b.squash > 0.6) ok = false;
        if (!Number.isFinite(b.vy)) ok = false;
      }
    }
    expect(ok).toBe(true);
  });

  it("每球经历多次起跳循环（resting→重置→再起跳），动画不休眠", () => {
    const blocks = DELAYS.map((d) => createBlock(d));
    const prevCyc = blocks.map((b) => b.cycElapsed);
    const cycles = blocks.map(() => 0);
    for (let i = 0; i < Math.round(12 / DT); i++) {
      blocks.forEach((b, j) => {
        stepBlock(b, DT);
        // cycElapsed 回绕 = 完成一轮 resting→立即再起跳 的循环
        if (b.cycElapsed < prevCyc[j]) cycles[j]++;
        prevCyc[j] = b.cycElapsed;
      });
    }
    // 12s 内至少完成两轮完整循环
    for (const c of cycles) expect(c).toBeGreaterThanOrEqual(2);
  });

  it("反弹衰减后进入 resting 静置贴地（无无限微跳空转）", () => {
    const blocks = DELAYS.map((d) => createBlock(d));
    // 三球相位错落，不要求同时 resting；断言各自都到达过 resting 状态
    const everRested = blocks.map(() => false);
    let ok = false;
    for (let i = 0; i < Math.round(6 / DT); i++) {
      blocks.forEach((b, j) => {
        stepBlock(b, DT);
        if (b.resting) everRested[j] = true;
      });
      if (everRested.every(Boolean)) {
        ok = true;
        break;
      }
    }
    expect(ok).toBe(true);
  });
});
