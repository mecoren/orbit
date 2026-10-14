import { describe, expect, it } from "vitest";

import { formatBytes, formatCount } from "./diagnostics-format";

describe("formatBytes", () => {
  it("字节档不带小数", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(1023)).toBe("1023 B");
  });

  it("按 1024 进制进位并去掉 .0", () => {
    expect(formatBytes(1024)).toBe("1 KB");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(1024 * 1024)).toBe("1 MB");
    expect(formatBytes(10 * 1024 * 1024 * 1024)).toBe("10 GB");
  });

  it("异常值显示占位符而不是 NaN", () => {
    expect(formatBytes(null)).toBe("—");
    expect(formatBytes(undefined)).toBe("—");
    expect(formatBytes(Number.NaN)).toBe("—");
    expect(formatBytes(-1)).toBe("—");
  });
});

describe("formatCount", () => {
  it("千分位分组", () => {
    expect(formatCount(0)).toBe("0");
    expect(formatCount(1234)).toBe("1,234");
    expect(formatCount(1_000_000)).toBe("1,000,000");
  });

  it("异常值显示占位符", () => {
    expect(formatCount(null)).toBe("—");
    expect(formatCount(Number.NaN)).toBe("—");
  });
});
