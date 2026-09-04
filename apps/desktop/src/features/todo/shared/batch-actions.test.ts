/**
 * 批量动作单测（P2#17）
 *
 * batchUpdate 的核心语义：逐条顺序提交、条目失败不中断、部分失败弹 warning
 * 并返回失败数。todoTaskUpdate 通过 vi.mock("@/lib/tauri") 注入。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { toast } from "sonner";

const updateMock = vi.fn<(id: number, input: unknown) => Promise<unknown>>();

vi.mock("@/lib/tauri", () => ({
  todoTaskUpdate: (id: number, input: unknown) => updateMock(id, input),
  todoTaskUpdatePosition: vi.fn(),
}));
vi.mock("sonner", () => ({
  toast: { warning: vi.fn(), success: vi.fn(), error: vi.fn() },
}));

import { batchUpdate, batchUpdateStatus } from "./batch-actions";
import type { TodoTask } from "@/lib/tauri";

function task(id: number, over: Partial<TodoTask> = {}): TodoTask {
  return {
    id,
    uuid: `u${id}`,
    title: `t${id}`,
    description: null,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    end_date: null,
    repeat_after: 0,
    repeat_mode: 0,
    percent_done: 0,
    position: id * 100,
    is_favorite: 0,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 0,
    ...over,
  } as TodoTask;
}

beforeEach(() => {
  updateMock.mockReset();
  vi.mocked(toast.warning).mockClear();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("batchUpdate", () => {
  it("逐条按 id 顺序提交", async () => {
    updateMock.mockResolvedValue(undefined);
    const failed = await batchUpdate([task(2), task(1), task(3)], () => ({ priority: 3 }), "测试");
    expect(failed).toBe(0);
    expect(updateMock.mock.calls.map((c) => c[0])).toEqual([2, 1, 3]);
    expect(updateMock).toHaveBeenCalledWith(2, { priority: 3 });
    expect(toast.warning).not.toHaveBeenCalled();
  });

  it("条目失败不中断：收集失败数继续后续条目", async () => {
    updateMock.mockImplementation(async (id) => {
      if (id === 2) throw new Error("boom");
      return undefined;
    });
    const failed = await batchUpdate([task(1), task(2), task(3)], () => ({ priority: 1 }), "批量设置优先级");
    expect(failed).toBe(1);
    // 失败条目后仍继续提交 3
    expect(updateMock).toHaveBeenCalledWith(3, { priority: 1 });
    expect(toast.warning).toHaveBeenCalledWith("批量设置优先级：3 条中 1 条失败");
  });

  it("空列表零调用", async () => {
    const failed = await batchUpdate([], () => ({}), "x");
    expect(failed).toBe(0);
    expect(updateMock).not.toHaveBeenCalled();
    expect(toast.warning).not.toHaveBeenCalled();
  });
});

describe("batchUpdateStatus", () => {
  it("完成口径 = done+done_at+status 三字段联动", async () => {
    updateMock.mockResolvedValue(undefined);
    const now = 1700000000000;
    await batchUpdateStatus([task(1)], { done: 1, done_at: now, status: "done" });
    expect(updateMock).toHaveBeenCalledWith(1, { done: 1, done_at: now, status: "done" });
  });
});
