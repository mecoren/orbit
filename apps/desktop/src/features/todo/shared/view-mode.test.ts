import { describe, expect, it } from "vitest";

import { VIEW_MODE_ORDER, VIEW_MODE_SHORT_LABEL, nextViewMode, type ViewMode } from "./view-mode";

describe("nextViewMode", () => {
  it("按 VIEW_MODE_ORDER 顺序逐档前进", () => {
    expect(nextViewMode("list")).toBe("kanban");
    expect(nextViewMode("kanban")).toBe("calendar");
    expect(nextViewMode("calendar")).toBe("table");
    expect(nextViewMode("table")).toBe("matrix");
  });

  it("末档回到首档（循环闭合）", () => {
    expect(nextViewMode("matrix")).toBe("list");
  });

  it("从任一档出发连续走满一轮回到自身（顺序无跳档/无重复）", () => {
    let mode: ViewMode = "list";
    const seen: ViewMode[] = [];
    for (let i = 0; i < VIEW_MODE_ORDER.length; i += 1) {
      seen.push(mode);
      mode = nextViewMode(mode);
    }
    expect(mode).toBe("list");
    expect(seen).toEqual([...VIEW_MODE_ORDER]);
  });

  it("每档都有短名（tooltip 不能出现 undefined）", () => {
    for (const key of VIEW_MODE_ORDER) {
      expect(VIEW_MODE_SHORT_LABEL[key]).toBeTruthy();
    }
  });
});
