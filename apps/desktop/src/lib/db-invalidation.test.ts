/**
 * db-change 表级失效映射单测：
 * 已知表精确失效对应键组；未知表回退 null（调用方全量失效）。
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import { QueryClient } from "@tanstack/react-query";

import { invalidateByTable } from "./db-invalidation";

/** 最小 QueryClient 桩：只记录 invalidateQueries 的入参 */
function makeClient() {
  const calls: { queryKey: string[] }[] = [];
  const qc = new QueryClient();
  vi.spyOn(qc, "invalidateQueries").mockImplementation(
    ((arg: { queryKey: string[] }) => {
      calls.push(arg);
      return Promise.resolve();
    }) as never,
  );
  return { qc, calls };
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("invalidateByTable 表级失效映射", () => {
  it("todo_tasks → 主列表 + 详情 + 搜索 + 统计 + 回收站（跨表派生全联动）", () => {
    const { qc, calls } = makeClient();
    const keys = invalidateByTable(qc, "todo_tasks");
    expect(keys).toEqual([["todo_tasks"], ["todo-task-detail"], ["global-search"], ["stats"], ["trash"]]);
    expect(calls).toHaveLength(5);
  });

  it("todo_subtasks → 仅详情键（主列表不含子任务数据）", () => {
    const { qc, calls } = makeClient();
    invalidateByTable(qc, "todo_subtasks");
    expect(calls).toEqual([{ queryKey: ["todo-task-detail"] }]);
  });

  it("todo_reminders → 提醒列表 + 详情", () => {
    const { qc, calls } = makeClient();
    invalidateByTable(qc, "todo_reminders");
    expect(calls).toEqual([{ queryKey: ["todo_reminders"] }, { queryKey: ["todo-task-detail"] }]);
  });

  it("todo_labels → 标签列表 + 详情 + 搜索", () => {
    const { qc, calls } = makeClient();
    invalidateByTable(qc, "todo_labels");
    expect(calls).toEqual([
      { queryKey: ["todo-label"] },
      { queryKey: ["todo-task-detail"] },
      { queryKey: ["global-search"] },
    ]);
  });

  it("todo_templates / todo_saved_filters 各只失效自己的键", () => {
    const { qc, calls } = makeClient();
    invalidateByTable(qc, "todo_templates");
    invalidateByTable(qc, "todo_saved_filters");
    expect(calls).toEqual([{ queryKey: ["templates"] }, { queryKey: ["saved-filters"] }]);
  });

  it("未知表 → null（调用方回退全量失效）", () => {
    const { qc, calls } = makeClient();
    expect(invalidateByTable(qc, "some_future_table")).toBeNull();
    expect(invalidateByTable(qc, "mock")).toBeNull();
    expect(calls).toEqual([]);
  });

  it("全部 11 张同步表都有映射（不漏业务表）", () => {
    const { qc } = makeClient();
    const tables = [
      "todo_tasks",
      "todo_subtasks",
      "todo_projects",
      "todo_labels",
      "todo_task_labels",
      "todo_reminders",
      "todo_comments",
      "todo_task_relations",
      "todo_task_attachments",
      "todo_templates",
      "todo_saved_filters",
    ];
    for (const t of tables) {
      expect(invalidateByTable(qc, t), `表 ${t} 缺映射`).not.toBeNull();
    }
  });
});
