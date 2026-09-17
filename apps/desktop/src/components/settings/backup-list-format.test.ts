import { describe, expect, it } from "vitest";

import { formatBackupSize, formatBackupTime } from "./backup-list-format";

describe("formatBackupTime", () => {
  it("零值与负值显示时间未知", () => {
    expect(formatBackupTime(0)).toBe("时间未知");
    expect(formatBackupTime(-5)).toBe("时间未知");
    expect(formatBackupTime(Number.NaN)).toBe("时间未知");
  });

  it("正常时间戳按本地展示（含年份）", () => {
    const text = formatBackupTime(1758067200);
    expect(text).not.toBe("时间未知");
    expect(text).toContain("2025");
  });
});

describe("formatBackupSize", () => {
  it("零值与负值显示大小未知", () => {
    expect(formatBackupSize(0)).toBe("大小未知");
    expect(formatBackupSize(-1)).toBe("大小未知");
  });

  it("B/KB/MB 阶梯", () => {
    expect(formatBackupSize(512)).toBe("512 B");
    expect(formatBackupSize(2048)).toBe("2.0 KB");
    expect(formatBackupSize(3 * 1024 * 1024)).toBe("3.0 MB");
  });
});
