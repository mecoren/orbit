import { describe, expect, it } from "vitest";

import { clampTimeUnit, formatTimeUnit, sanitizeTimeDigits } from "./time-hm-select";

describe("sanitizeTimeDigits", () => {
  it("只留数字并截断到 2 位", () => {
    expect(sanitizeTimeDigits("15")).toBe("15");
    expect(sanitizeTimeDigits("1a6b")).toBe("16");
    expect(sanitizeTimeDigits("123")).toBe("12");
    expect(sanitizeTimeDigits("")).toBe("");
    expect(sanitizeTimeDigits("时")).toBe("");
  });
});

describe("clampTimeUnit", () => {
  it("钳制到上下界", () => {
    expect(clampTimeUnit(15, 23)).toBe(15);
    expect(clampTimeUnit(25, 23)).toBe(23);
    expect(clampTimeUnit(-3, 59)).toBe(0);
    expect(clampTimeUnit(59, 59)).toBe(59);
  });

  it("非数字按 0 处理", () => {
    expect(clampTimeUnit(NaN, 23)).toBe(0);
  });
});

describe("formatTimeUnit", () => {
  it("钳制后补零", () => {
    expect(formatTimeUnit(9, 23)).toBe("09");
    expect(formatTimeUnit(15, 23)).toBe("15");
    expect(formatTimeUnit(25, 23)).toBe("23");
    expect(formatTimeUnit(7, 59)).toBe("07");
    expect(formatTimeUnit(78, 59)).toBe("59");
  });
});
