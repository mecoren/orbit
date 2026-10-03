import { describe, expect, it } from "vitest";
import { formatDuration } from "./time";

describe("formatDuration（预计时长徽标，M9 阶段一）", () => {
  it("分钟 < 60 → Nm", () => {
    expect(formatDuration(45)).toBe("45m");
    expect(formatDuration(1)).toBe("1m");
    expect(formatDuration(59)).toBe("59m");
  });

  it("整小时 → Nh", () => {
    expect(formatDuration(60)).toBe("1h");
    expect(formatDuration(120)).toBe("2h");
  });

  it("非整小时 → Nh Mm", () => {
    expect(formatDuration(90)).toBe("1h30m");
    expect(formatDuration(75)).toBe("1h15m");
  });

  it("未设置/非法值 → null（行内不显示徽标）", () => {
    expect(formatDuration(null)).toBe(null);
    expect(formatDuration(undefined)).toBe(null);
    expect(formatDuration(0)).toBe(null);
    expect(formatDuration(-5)).toBe(null);
  });

  it("小数输入四舍五入到分钟", () => {
    expect(formatDuration(45.4)).toBe("45m");
    expect(formatDuration(45.6)).toBe("46m");
  });
});
