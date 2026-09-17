import { describe, expect, it } from "vitest";

import { formatHoldLabel } from "./dangerous-confirm-dialog";

describe("formatHoldLabel", () => {
  it("倒计时未走完显示剩余秒数", () => {
    expect(formatHoldLabel(5, "确认恢复")).toBe("请阅读后果（5s）");
    expect(formatHoldLabel(1, "确认恢复")).toBe("请阅读后果（1s）");
  });

  it("倒计时走完显示确认文案", () => {
    expect(formatHoldLabel(0, "确认恢复")).toBe("确认恢复");
  });

  it("异常负值按走完处理", () => {
    expect(formatHoldLabel(-1, "确认")).toBe("确认");
  });
});
