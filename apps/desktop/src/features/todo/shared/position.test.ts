// apps/desktop/src/features/todo/shared/position.test.ts
// midpoint 中值公式（03 文档 §一；看板 kanban-view 与列表拖拽共用）
import { describe, expect, it } from "vitest";

import { midpoint } from "./position";

describe("midpoint", () => {
  it("两侧齐全取中值", () => {
    expect(midpoint(10, 20)).toBe(15);
  });
  it("缺 prev → 0 与 next 的中值（置于列首）", () => {
    expect(midpoint(undefined, 100)).toBe(50);
  });
  it("缺 next → prev 与 100000 的中值（尾部追加）", () => {
    expect(midpoint(100)).toBe(50050);
  });
  it("双缺省 → 50000", () => {
    expect(midpoint()).toBe(50000);
  });
});
