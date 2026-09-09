import { describe, expect, it, vi } from "vitest";
import {
  createUndoStack,
  isUndoShortcut,
  undoToastText,
  type UndoEntry,
} from "./undo-stack";

const entry = (label: string, over: Partial<UndoEntry> = {}): UndoEntry => ({
  label,
  undo: async () => {},
  ...over,
});

describe("createUndoStack", () => {
  it("push 后 last 可见，undo 弹出执行并清栈", async () => {
    const undoFn = vi.fn().mockResolvedValue(undefined);
    const stack = createUndoStack();
    stack.push(entry("完成任务", { undo: undoFn }));
    expect(stack.last?.label).toBe("完成任务");
    const out = await stack.undo();
    expect(out.undone).toBe(true);
    expect(undoFn).toHaveBeenCalledTimes(1);
    expect(stack.last).toBeNull();
  });

  it("空栈 undo 返回 empty 且不报错", async () => {
    const stack = createUndoStack();
    const out = await stack.undo();
    expect(out).toEqual({ undone: false, reason: "empty" });
  });

  it("栈容量上限 30，超限丢最旧", async () => {
    const stack = createUndoStack();
    for (let i = 0; i < 35; i++) {
      stack.push(entry(`操作${i}`));
    }
    // 35 推入只留最近 30（op5..op34）
    let seen: string[] = [];
    for (let i = 0; i < 30; i++) {
      const e = stack.last;
      if (e) seen.push(e.label);
      await stack.undo();
    }
    expect(seen[0]).toBe("操作34");
    expect(seen[29]).toBe("操作5");
    expect(stack.last).toBeNull();
  });

  it("undo 回调抛错返回 failed，不炸栈可继续弹后续", async () => {
    const good = vi.fn().mockResolvedValue(undefined);
    const stack = createUndoStack();
    stack.push(entry("坏操作", { undo: async () => { throw new Error("boom"); } }));
    stack.push(entry("好操作", { undo: good }));
    const first = await stack.undo(); // 弹好操作
    expect(first.undone).toBe(true);
    const second = await stack.undo(); // 弹坏操作：吞错
    expect(second.undone).toBe(false);
    if (second.undone === false && second.reason === "failed") {
      expect(second.entry.label).toBe("坏操作");
      expect(second.error).toBeInstanceOf(Error);
    } else {
      throw new Error("应为 failed 分支");
    }
    expect(good).toHaveBeenCalledTimes(1);
  });

  it("clear 清空栈", () => {
    const stack = createUndoStack();
    stack.push(entry("a"));
    stack.push(entry("b"));
    stack.clear();
    expect(stack.last).toBeNull();
  });
});

describe("isUndoShortcut", () => {
  it("ctrl/cmd+z 命中；shift 组合（redo 语义）不命中", () => {
    expect(isUndoShortcut({ ctrlKey: true, key: "z" })).toBe(true);
    expect(isUndoShortcut({ metaKey: true, key: "z" })).toBe(true);
    expect(isUndoShortcut({ ctrlKey: true, key: "Z" })).toBe(true);
    expect(isUndoShortcut({ ctrlKey: true, shiftKey: true, key: "z" })).toBe(false);
    expect(isUndoShortcut({ ctrlKey: true, key: "y" })).toBe(false);
    expect(isUndoShortcut({ key: "z" })).toBe(false);
  });
});

describe("undoToastText", () => {
  it("单条不带条数，批量带 count", () => {
    expect(undoToastText(entry("完成任务"))).toBe("已撤销：完成任务");
    expect(undoToastText(entry("完成任务", { count: 3 }))).toBe("已撤销：完成任务 3 条");
  });
});
