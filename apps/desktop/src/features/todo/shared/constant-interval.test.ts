import { describe, expect, it } from "vitest";

import {
  CONSTANT_INTERVAL_PRESETS_MIN,
  DEFAULT_CONSTANT_INTERVAL_MS,
  MAX_CONSTANT_INTERVAL_MS,
  MIN_CONSTANT_INTERVAL_MS,
  constantIntervalOptions,
  formatConstantInterval,
  normalizeConstantIntervalMs,
} from "./constant-interval";

const MIN = 60_000;

describe("normalizeConstantIntervalMs", () => {
  it("缺失/非正数回落默认 5 分钟（老壳 JSON 不带该字段）", () => {
    expect(normalizeConstantIntervalMs(undefined)).toBe(DEFAULT_CONSTANT_INTERVAL_MS);
    expect(normalizeConstantIntervalMs(null)).toBe(DEFAULT_CONSTANT_INTERVAL_MS);
    expect(normalizeConstantIntervalMs(0)).toBe(DEFAULT_CONSTANT_INTERVAL_MS);
    expect(normalizeConstantIntervalMs(-5)).toBe(DEFAULT_CONSTANT_INTERVAL_MS);
    expect(normalizeConstantIntervalMs(Number.NaN)).toBe(DEFAULT_CONSTANT_INTERVAL_MS);
  });

  it("越界钳到 [1 分钟, 24 小时]（与 core 同口径）", () => {
    expect(normalizeConstantIntervalMs(1_000)).toBe(MIN_CONSTANT_INTERVAL_MS);
    expect(normalizeConstantIntervalMs(7 * 24 * 60 * MIN)).toBe(MAX_CONSTANT_INTERVAL_MS);
  });

  it("档位内原样返回", () => {
    expect(normalizeConstantIntervalMs(15 * MIN)).toBe(15 * MIN);
  });
});

describe("constantIntervalOptions", () => {
  it("预设值命中时不追加（顺序稳定）", () => {
    const options = constantIntervalOptions(10 * MIN);
    expect(options).toEqual(CONSTANT_INTERVAL_PRESETS_MIN.map((m) => m * MIN));
  });

  it("自定义值（跨端写入）补进档位并保持升序，避免选择器空白", () => {
    const options = constantIntervalOptions(45 * MIN);
    expect(options).toContain(45 * MIN);
    expect([...options].sort((a, b) => a - b)).toEqual(options);
    expect(new Set(options).size).toBe(options.length);
  });
});

describe("formatConstantInterval", () => {
  it("整小时档用小时措辞", () => {
    expect(formatConstantInterval(60 * MIN)).toBe("每 1 小时");
    expect(formatConstantInterval(120 * MIN)).toBe("每 2 小时");
  });

  it("非整小时用分钟措辞（含自定义值）", () => {
    expect(formatConstantInterval(5 * MIN)).toBe("每 5 分钟");
    expect(formatConstantInterval(90 * MIN)).toBe("每 90 分钟");
  });

  it("未设置回落默认档文案", () => {
    expect(formatConstantInterval(0)).toBe("每 5 分钟");
  });
});
