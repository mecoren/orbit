import { describe, expect, it } from "vitest";

import { testDataConfirmCopy, type TestDataAction } from "./test-data-confirm";

const ACTIONS: TestDataAction[] = ["seed", "clear"];

describe("testDataConfirmCopy", () => {
  it("生成与清除都必须是两步确认", () => {
    for (const action of ACTIONS) {
      const step1 = testDataConfirmCopy(action, 1, 300);
      const step2 = testDataConfirmCopy(action, 2, 300);
      expect(step1.title).toContain("第 1 步");
      expect(step1.confirmLabel).toBe("继续");
      // 第二步必须能一眼看出是「再来一次」，否则两步退化成一次长文案
      expect(step2.title).toContain("再次确认");
      expect(step2.title).toContain("第 2 步");
      expect(step2.confirmLabel).not.toBe(step1.confirmLabel);
    }
  });

  it("生成文案带规模与「先清上一批」，清除文案强调不可撤销", () => {
    const seed = testDataConfirmCopy("seed", 1, 1_200);
    expect(seed.description).toContain("1,200");
    expect(seed.description).toContain("清掉上一批");
    expect(testDataConfirmCopy("seed", 2, 1_200).description).toContain("1,200");

    const clear = testDataConfirmCopy("clear", 2, 1_200);
    expect(clear.description).toContain("不可撤销");
  });
});
