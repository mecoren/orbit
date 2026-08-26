// apps/desktop/src/features/todo/shared/list-keyboard.test.ts
// 列表键盘导航语义（07 报告 §五-P1#8）
import { describe, expect, it } from "vitest";

import { isListActivationKey, listNavDirection } from "./list-keyboard";

describe("listNavDirection", () => {
  it("j/ArrowDown → down；k/ArrowUp → up；其余 null", () => {
    expect(listNavDirection("j")).toBe("down");
    expect(listNavDirection("ArrowDown")).toBe("down");
    expect(listNavDirection("k")).toBe("up");
    expect(listNavDirection("ArrowUp")).toBe("up");
    expect(listNavDirection("Enter")).toBeNull();
    expect(listNavDirection("a")).toBeNull();
  });
});

describe("isListActivationKey", () => {
  it("Enter 与空格激活；其余否", () => {
    expect(isListActivationKey("Enter")).toBe(true);
    expect(isListActivationKey(" ")).toBe(true);
    expect(isListActivationKey("Spacebar")).toBe(false);
    expect(isListActivationKey("j")).toBe(false);
  });
});
