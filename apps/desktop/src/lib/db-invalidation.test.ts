/**
 * db-change 表级失效映射单测：
 * 已知表精确失效对应键组；未知表回退 null（调用方全量失效）。
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import { QueryClient } from "@tanstack/react-query";

import { invalidateByTable, isImmediateFullInvalidation, planFlushCoalesced } from "./db-invalidation";

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

  it("todo_activity_log → 仅历史键（轨迹落库后自发事件，不搭 todo_tasks 竞态车）", () => {
    const { qc, calls } = makeClient();
    invalidateByTable(qc, "todo_activity_log");
    expect(calls).toEqual([{ queryKey: ["task-activity"] }]);
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

describe("D2 突发合并决策", () => {
  it("Lagged 哨兵与 * 立刻全量，不等窗口", () => {
    expect(isImmediateFullInvalidation("*")).toBe(true);
    expect(isImmediateFullInvalidation("todo_tasks", "lagged")).toBe(true);
    expect(isImmediateFullInvalidation("todo_tasks")).toBe(false);
    expect(isImmediateFullInvalidation("mock")).toBe(false);
  });

  it("窗口内出现 * 则吞掉更窄的键，一窗一次全量", () => {
    expect(planFlushCoalesced(["todo_tasks", "*", "todo_labels"])).toEqual({
      full: true,
      tables: [],
    });
  });

  it("同表重复事件去重为一次表级失效", () => {
    expect(planFlushCoalesced(["todo_tasks", "todo_tasks", "todo_tasks"])).toEqual({
      full: false,
      tables: ["todo_tasks"],
    });
  });

  it("未知表不在计划期展开，flush 时回退全量（一窗只一次）", () => {
    const plan = planFlushCoalesced(["todo_tasks", "mock"]);
    expect(plan.full).toBe(false);
    const { qc, calls } = makeClient();
    let full = false;
    for (const t of plan.tables) {
      if (invalidateByTable(qc, t) === null) {
        full = true;
        break;
      }
    }
    expect(full).toBe(true);
    // todo_tasks 的 5 路先进了 calls，全量由调用方补一次（此处只断决策）
    expect(calls).toHaveLength(5);
  });
});
