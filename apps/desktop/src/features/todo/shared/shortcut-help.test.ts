// apps/desktop/src/features/todo/shared/shortcut-help.test.ts
import { describe, expect, it } from "vitest";

import { SHORTCUT_GROUPS, isHelpShortcut } from "./shortcut-help";

describe("shortcut-help 常量表", () => {
  it("分组齐全：全局 / 任务列表 / 任务详情", () => {
    expect(SHORTCUT_GROUPS.map((g) => g.title)).toEqual(["全局", "任务列表", "任务详情"]);
  });

  it("每个分组非空且条目有键位与说明", () => {
    for (const g of SHORTCUT_GROUPS) {
      expect(g.entries.length).toBeGreaterThan(0);
      for (const e of g.entries) {
        expect(e.keys.length).toBeGreaterThan(0);
        expect(e.action.length).toBeGreaterThan(0);
      }
    }
  });

  it("全局分组收录四个已落地命令键（P/K/Z/?）", () => {
    const globalKeys = SHORTCUT_GROUPS[0]!.entries.map((e) => e.keys);
    expect(globalKeys).toContain("Ctrl+P");
    expect(globalKeys).toContain("Ctrl+K");
    expect(globalKeys).toContain("Ctrl+Z");
    expect(globalKeys).toContain("?");
  });

  it("键位无重复（同键不同义是文档缺陷）", () => {
    const all = SHORTCUT_GROUPS.flatMap((g) => g.entries.map((e) => e.keys));
    expect(new Set(all).size).toBe(all.length);
  });
});

describe("isHelpShortcut", () => {
  it("Shift+/ 与 Shift+? 均命中（键盘布局差异）", () => {
    expect(isHelpShortcut({ shiftKey: true, key: "?" })).toBe(true);
    expect(isHelpShortcut({ shiftKey: true, key: "/" })).toBe(true);
  });

  it("纯 / 不命中（避免输入框内误开）", () => {
    expect(isHelpShortcut({ shiftKey: false, key: "/" })).toBe(false);
  });

  it("带 Ctrl/Cmd 不命中（浏览器快捷键不劫持）", () => {
    expect(isHelpShortcut({ shiftKey: true, ctrlKey: true, key: "?" })).toBe(false);
    expect(isHelpShortcut({ shiftKey: true, metaKey: true, key: "?" })).toBe(false);
  });
});
