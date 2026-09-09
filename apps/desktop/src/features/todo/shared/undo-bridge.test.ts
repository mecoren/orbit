import { describe, expect, it, vi } from "vitest";
import { pushUndo, setUndoPusher } from "./undo-bridge";
import type { UndoEntry } from "./undo-stack";

describe("undo-bridge（非 React 模块的入栈注册点）", () => {
  it("未注册时 pushUndo 静默 no-op", () => {
    expect(() => pushUndo({ label: "完成任务", undo: async () => {} })).not.toThrow();
  });

  it("注册后转发条目；置 null 后恢复 no-op", () => {
    const received: UndoEntry[] = [];
    setUndoPusher((e) => received.push(typeof e === "function" ? e() : e));
    pushUndo({ label: "完成任务", undo: async () => {} });
    pushUndo(() => ({ label: "取消完成", undo: async () => {} }));
    expect(received.map((r) => r.label)).toEqual(["完成任务", "取消完成"]);
    setUndoPusher(null);
    pushUndo({ label: "不应到达", undo: async () => {} });
    expect(received).toHaveLength(2);
  });

  it("惰性构造：传入函数仅在 pusher 存在时调用", () => {
    const factory = vi.fn(() => ({ label: "x", undo: async () => {} }));
    setUndoPusher(null);
    pushUndo(factory);
    expect(factory).not.toHaveBeenCalled();
  });
});
