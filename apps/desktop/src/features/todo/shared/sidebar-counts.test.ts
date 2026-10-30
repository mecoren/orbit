import { describe, expect, it } from "vitest";

import { buildQuickViewCounts } from "./sidebar-counts";

const INPUT = {
  undone: 28,
  done: 9,
  today: 3,
  week: 7,
  favorite: 2,
  myDay: 4,
};

describe("buildQuickViewCounts 侧栏角标口径", () => {
  it("全部与未完成共用未完成总数（角标答「还剩多少要做」）", () => {
    const counts = buildQuickViewCounts(INPUT);
    expect(counts.all).toBe(28);
    expect(counts.undone).toBe(28);
  });

  it("已完成视图取完成数，其余视图各取自己的 COUNT", () => {
    const counts = buildQuickViewCounts(INPUT);
    expect(counts.done).toBe(9);
    expect(counts.today).toBe(3);
    expect(counts.week).toBe(7);
    expect(counts.favorite).toBe(2);
    expect(counts.my_day).toBe(4);
  });
});
