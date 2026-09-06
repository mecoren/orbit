/**
 * 回收站页纯逻辑测试 —— 保留期倒计时文案档位判定
 *
 * trash-page 的 expiresLabel / retentionLabel 语义：永久档显示删除日期，
 * 档位内显示 N 天后自动清除，过期边界显示「即将自动清除」。
 */
import { describe, expect, it } from "vitest";

const DAY_MS = 86_400_000;

// 从 trash-page 提取的同款逻辑（页面内联实现，此处镜像断言语义）
function retentionLabel(days: number): string {
  if (days === 0) return "永久保留";
  return `${days} 天`;
}

function expiresLabel(deletedAt: number, retentionDays: number, now: number): string {
  if (retentionDays === 0) return `删除于 ${new Date(deletedAt).toLocaleDateString()}`;
  const remain = Math.ceil((deletedAt + retentionDays * DAY_MS - now) / DAY_MS);
  if (remain <= 0) return "即将自动清除";
  return `${remain} 天后自动清除`;
}

describe("retentionLabel 保留档位文案", () => {
  it("0 = 永久保留", () => {
    expect(retentionLabel(0)).toBe("永久保留");
  });

  it.each([7, 30, 90])("%d 天档位", (d) => {
    expect(retentionLabel(d)).toBe(`${d} 天`);
  });
});

describe("expiresLabel 倒计时文案", () => {
  const now = Date.now();

  it("永久档显示删除日期", () => {
    const at = now - 10 * DAY_MS;
    expect(expiresLabel(at, 0, now)).toBe(
      `删除于 ${new Date(at).toLocaleDateString()}`,
    );
  });

  it("档位内显示剩余天数", () => {
    // 30 天档、3 天前删 → 27 天后清除
    expect(expiresLabel(now - 3 * DAY_MS, 30, now)).toBe("27 天后自动清除");
  });

  it("刚好在保留期边界 → 即将清除", () => {
    expect(expiresLabel(now - 30 * DAY_MS, 30, now)).toBe("即将自动清除");
  });

  it("超过保留期（守护尚未跑）→ 即将清除", () => {
    expect(expiresLabel(now - 31 * DAY_MS, 30, now)).toBe("即将自动清除");
  });

  it("今天删除 → 完整天数（向上取整）", () => {
    expect(expiresLabel(now - 1000, 7, now)).toBe("7 天后自动清除");
  });
});
