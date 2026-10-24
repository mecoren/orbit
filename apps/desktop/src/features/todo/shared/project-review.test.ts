import { describe, expect, it } from "vitest";

import {
  REVIEW_INTERVAL_PRESETS,
  formatLastReviewed,
  formatOverdueDays,
  formatReviewInterval,
} from "./project-review";

const DAY = 86_400_000;

describe("formatReviewInterval", () => {
  it("关闭态：null / 0 / 负数", () => {
    expect(formatReviewInterval(null)).toBe("关闭");
    expect(formatReviewInterval(undefined)).toBe("关闭");
    expect(formatReviewInterval(0)).toBe("关闭");
    expect(formatReviewInterval(-7)).toBe("关闭");
  });

  it("档位天数映射预设标签", () => {
    expect(formatReviewInterval(1)).toBe("每天");
    expect(formatReviewInterval(7)).toBe("每周");
    expect(formatReviewInterval(14)).toBe("每两周");
    expect(formatReviewInterval(30)).toBe("每月");
  });

  it("非档位天数回退「每 N 天」", () => {
    expect(formatReviewInterval(10)).toBe("每 10 天");
  });

  it("预设档位本身无重复天数", () => {
    const days = REVIEW_INTERVAL_PRESETS.map((p) => p.days);
    expect(new Set(days).size).toBe(days.length);
  });
});

describe("formatOverdueDays", () => {
  it("0 与负数 = 今天到期", () => {
    expect(formatOverdueDays(0)).toBe("今天到期");
    expect(formatOverdueDays(-3)).toBe("今天到期");
  });

  it("1 天单复数区分", () => {
    expect(formatOverdueDays(1)).toBe("已逾期 1 天");
    expect(formatOverdueDays(23)).toBe("已逾期 23 天");
  });
});

describe("formatLastReviewed", () => {
  it("null = 从未回顾", () => {
    expect(formatLastReviewed(null, 0)).toBe("从未回顾");
  });

  it("按本地日历日差给相对文案（跨月/跨年同样按日差）", () => {
    const now = new Date(2026, 9, 24, 20, 0).getTime(); // 2026-10-24 本地
    expect(formatLastReviewed(now, now)).toBe("今天回顾过");
    expect(formatLastReviewed(new Date(2026, 9, 23, 8, 0).getTime(), now)).toBe("昨天回顾过");
    expect(formatLastReviewed(new Date(2026, 9, 14, 23, 30).getTime(), now)).toBe("10 天前回顾");
  });

  it("同日不同钟点不误加一天（日历日差而非 24h 差）", () => {
    const now = new Date(2026, 9, 24, 0, 30).getTime();
    const last = new Date(2026, 9, 24, 23, 0).getTime();
    expect(formatLastReviewed(last, now)).toBe("今天回顾过");
  });

  it("≥30 天回退日期文案", () => {
    const now = new Date(2026, 9, 24).getTime();
    expect(formatLastReviewed(now - 40 * DAY, now)).toBe("2026/9/14 回顾");
  });
});
