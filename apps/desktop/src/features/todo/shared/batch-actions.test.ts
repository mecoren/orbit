/**
 * 批量动作单测（P2#17；引擎下沉后完成口径改走 todoTaskComplete）
 *
 * batchUpdate 的核心语义：逐条顺序提交、条目失败不中断、部分失败弹 warning
 * 并返回失败数。todoTaskUpdate/todoTaskComplete 通过 vi.mock("@/lib/tauri") 注入。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { toast } from "sonner";

const updateMock = vi.fn<(id: number, input: unknown) => Promise<unknown>>();
const completeMock = vi.fn<(id: number) => Promise<{ task: unknown; next_instance: unknown }>>();
const deleteMock = vi.fn<(id: number) => Promise<void>>();

vi.mock("@/lib/tauri", () => ({
  todoTaskUpdate: (id: number, input: unknown) => updateMock(id, input),
  todoTaskUpdatePosition: vi.fn(),
  todoTaskComplete: (id: number) => completeMock(id),
  todoTaskDelete: (id: number) => deleteMock(id),
}));
vi.mock("sonner", () => ({
  toast: { warning: vi.fn(), success: vi.fn(), error: vi.fn() },
}));

import { batchDuePresetDate, batchSetDueDate, batchUpdate, batchUpdateStatus } from "./batch-actions";
import type { TodoTask } from "@/lib/tauri";
import { QueryClient } from "@tanstack/react-query";

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
  completeMock.mockReset();
  deleteMock.mockReset();
  // 引擎完成命令默认返回「无下一实例」（undo 注册读取 next_instance）
  completeMock.mockResolvedValue({ task: null, next_instance: null });
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
  it("批量完成走统一完成命令（与单条 completeTask 同一 Rust 入口，重复任务推进下一实例）", async () => {
    completeMock.mockResolvedValue({ task: null, next_instance: null });
    await batchUpdateStatus([task(1), task(2)], { done: 1, done_at: 0, status: "done" });
    expect(completeMock).toHaveBeenCalledWith(1);
    expect(completeMock).toHaveBeenCalledWith(2);
    expect(updateMock).not.toHaveBeenCalled();
  });

  it("已完成条目跳过（幂等，不重复推进重复实例）", async () => {
    completeMock.mockResolvedValue({ task: null, next_instance: null });
    await batchUpdateStatus([task(1, { done: 1 })], { done: 1, done_at: 0, status: "done" });
    expect(completeMock).not.toHaveBeenCalled();
  });

  it("取消完成 / 状态切换仍走普通 update", async () => {
    updateMock.mockResolvedValue(undefined);
    await batchUpdateStatus([task(1)], { done: 0, done_at: null, status: "pending" });
    expect(updateMock).toHaveBeenCalledWith(1, { done: 0, done_at: null, status: "pending" });
    expect(completeMock).not.toHaveBeenCalled();
  });

  it("完成失败不中断：收集失败数并弹 warning", async () => {
    completeMock.mockImplementation(async (id) => {
      if (id === 2) throw new Error("boom");
      return { task: null, next_instance: null };
    });
    const failed = await batchUpdateStatus([task(1), task(2), task(3)], { done: 1, done_at: 0, status: "done" });
    expect(failed).toBe(1);
    expect(toast.warning).toHaveBeenCalledWith("批量更新状态：3 条中 1 条失败");
  });
});

describe("batchDuePresetDate", () => {
  it("today/tomorrow/clear 档位输出（clear = null）", () => {
    const now = new Date(2026, 8, 12, 15, 30); // 周六
    expect(batchDuePresetDate("today", now)?.getDate()).toBe(12);
    expect(batchDuePresetDate("tomorrow", now)?.getDate()).toBe(13);
    expect(batchDuePresetDate("clear", now)).toBeNull();
  });

  it("next_monday：周一~周日都锚下一周一（周一起始周）", () => {
    // 周六（2026-09-12）→ 下周一 09-14；周一（09-07）→ 下周一 09-14
    expect(batchDuePresetDate("next_monday", new Date(2026, 8, 12))?.getDate()).toBe(14);
    expect(batchDuePresetDate("next_monday", new Date(2026, 8, 7))?.getDate()).toBe(14);
  });
});

describe("batchSetDueDate", () => {
  it("按档位换日期：保留原时分秒（rescheduleDue 同口径）", async () => {
    updateMock.mockResolvedValue(undefined);
    // 原截止 2026-09-01 14:30；tomorrow 档以运行时今天为基准 → 明天 14:30
    const due = new Date(2026, 8, 1, 14, 30).getTime();
    await batchSetDueDate([task(1, { due_date: due })], "tomorrow");
    const expected = (() => {
      const now = new Date();
      const t = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
      t.setHours(14, 30, 0, 0);
      return t.getTime();
    })();
    expect(updateMock).toHaveBeenCalledWith(1, { due_date: expected });
  });

  it("clear 档写 null 清除截止；已无截止条目幂等跳过", async () => {
    updateMock.mockResolvedValue(undefined);
    await batchSetDueDate([task(1, { due_date: 100 }), task(2, { due_date: null })], "clear");
    expect(updateMock).toHaveBeenCalledTimes(1);
    expect(updateMock).toHaveBeenCalledWith(1, { due_date: null });
  });

  it("同日档位无变化跳过写库", async () => {
    updateMock.mockResolvedValue(undefined);
    const today = new Date();
    today.setHours(18, 0, 0, 0);
    await batchSetDueDate([task(1, { due_date: today.getTime() })], "today");
    expect(updateMock).not.toHaveBeenCalled();
  });

  it("条目失败不中断并弹 warning", async () => {
    updateMock.mockImplementation(async (id) => {
      if (id === 1) throw new Error("boom");
    });
    const failed = await batchSetDueDate([task(1), task(2)], "tomorrow");
    expect(failed).toBe(1);
    expect(toast.warning).toHaveBeenCalledWith("批量改期：2 条中 1 条失败");
  });
});

describe("D5 乐观 patch（可选 qc）", () => {
  function seedClient(ids: number[]) {
    const qc = new QueryClient();
    qc.setQueryData(
      ["todo_tasks", "", {}],
      ids.map((id) => task(id)),
    );
    return qc;
  }
  const prioOf = (qc: QueryClient, id: number) =>
    qc.getQueryData<TodoTask[]>(["todo_tasks", "", {}])!.find((t) => t.id === id)?.priority;

  it("batchUpdate：循环前一次性 patch，失败 id 精确回滚", async () => {
    updateMock.mockImplementation(async (id) => {
      if (id === 2) throw new Error("boom");
      return undefined;
    });
    const qc = seedClient([1, 2, 3]);
    const failed = await batchUpdate([task(1), task(2), task(3)], () => ({ priority: 3 }), "测试", qc);
    expect(failed).toBe(1);
    expect(prioOf(qc, 1)).toBe(3);
    expect(prioOf(qc, 3)).toBe(3);
    // 失败行回滚到传入快照（priority 0），而非残留乐观值
    expect(prioOf(qc, 2)).toBe(0);
  });

  it("batchUpdateStatus 完成态：先全翻 done，失败行回滚", async () => {
    completeMock.mockImplementation(async (id) => {
      if (id === 2) throw new Error("boom");
      return { task: { done: 1, done_at: 9, status: "done" }, next_instance: null };
    });
    const qc = seedClient([1, 2]);
    const failed = await batchUpdateStatus(
      [task(1), task(2)],
      { done: 1, done_at: 0, status: "done" },
      qc,
    );
    expect(failed).toBe(1);
    const rows = qc.getQueryData<TodoTask[]>(["todo_tasks", "", {}])!;
    expect(rows.find((t) => t.id === 1)?.done).toBe(1);
    expect(rows.find((t) => t.id === 2)?.done).toBe(0);
  });

  it("无 qc 时行为不变（不碰缓存，旧 12 例口径）", async () => {
    updateMock.mockResolvedValue(undefined);
    const qc = seedClient([1]);
    await batchUpdate([task(1)], () => ({ priority: 3 }), "测试");
    expect(prioOf(qc, 1)).toBe(0);
  });
});
