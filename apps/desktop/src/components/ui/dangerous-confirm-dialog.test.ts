import { describe, expect, it } from "vitest";

import { formatHoldLabel, resolveHoldLabel } from "./dangerous-confirm-dialog";

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

describe("resolveHoldLabel", () => {
  it("门控暂停中显示等待文案（倒计时尚未起算）", () => {
    expect(resolveHoldLabel(5, "确认恢复", true, "正在解密预览…")).toBe(
      "正在解密预览…",
    );
    // 即使倒计时已走完，暂停中仍显示等待（调用方翻门控后才重计满格）
    expect(resolveHoldLabel(0, "确认恢复", true, "正在解密预览…")).toBe(
      "正在解密预览…",
    );
  });

  it("门控放行后走正常倒计时文案", () => {
    expect(resolveHoldLabel(5, "确认恢复", false, "正在解密预览…")).toBe(
      "请阅读后果（5s）",
    );
    expect(resolveHoldLabel(0, "确认恢复", false, "正在解密预览…")).toBe(
      "确认恢复",
    );
  });
});
