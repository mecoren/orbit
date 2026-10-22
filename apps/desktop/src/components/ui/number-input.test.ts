import { describe, expect, it } from "vitest";

import { nudgeNumberValue } from "./number-input";

describe("nudgeNumberValue", () => {
  it("正常步进按 step 增减", () => {
    expect(nudgeNumberValue("480", 1, { step: 15 })).toBe("495");
    expect(nudgeNumberValue("480", -1, { step: 15 })).toBe("465");
  });

  it("默认 step = 1", () => {
    expect(nudgeNumberValue("10", 1)).toBe("11");
    expect(nudgeNumberValue("10", -1)).toBe("9");
  });

  it("空值时增加 = 一档 step（未设 → 有值）", () => {
    expect(nudgeNumberValue("", 1, { min: 1, step: 15 })).toBe("15");
  });

  it("空值时减少落到下限 min（无 min 取 0）", () => {
    expect(nudgeNumberValue("", -1, { min: 1 })).toBe("1");
    expect(nudgeNumberValue("", -1)).toBe("0");
  });

  it("min / max 夹取", () => {
    expect(nudgeNumberValue("8", -1, { min: 1, step: 15 })).toBe("1");
    expect(nudgeNumberValue("1440", 1, { max: 1440 })).toBe("1440");
  });

  it("非法输入视同未设", () => {
    expect(nudgeNumberValue("abc", 1, { min: 0 })).toBe("1");
    expect(nudgeNumberValue("", 1, { min: 5 })).toBe("5");
  });
});
