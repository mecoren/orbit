import { describe, expect, it } from "vitest";

import { type TodoTask } from "@/lib/tauri";
import { filterTasks, sortTasks } from "./task-filters";

/** 补齐 TodoTask 全部必填字段的工厂 */
function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1,
    uuid: "uuid-1",
    title: "",
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
    position: 0,
    is_favorite: 0,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
    ...partial,
  };
}

/** 当日零点基准（与现实现一致） */
const DAY_MS = 24 * 3600 * 1000;
const todayStart = new Date();
todayStart.setHours(0, 0, 0, 0);
const T0 = todayStart.getTime();

describe("filterTasks - 互斥目标（ungrouped > projectId > quickView）", () => {
  it("ungrouped 只保留 project_id == null", () => {
    const tasks = [mk({ id: 1, project_id: null }), mk({ id: 2, project_id: 5 })];
    const out = filterTasks(tasks, { ungrouped: true });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("projectId 只保留匹配项", () => {
    const tasks = [mk({ id: 1, project_id: 3 }), mk({ id: 2, project_id: 4 })];
    const out = filterTasks(tasks, { projectId: 3 });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("ungrouped 优先于 projectId 与 quickView（收藏视图任务因属于项目被排除）", () => {
    const tasks = [
      mk({ id: 1, project_id: 5, is_favorite: 1 }),
      mk({ id: 2, project_id: null }),
    ];
    const out = filterTasks(tasks, {
      ungrouped: true,
      projectId: 5,
      quickView: "favorite",
    });
    expect(out.map((t) => t.id)).toEqual([2]);
  });
});

describe("filterTasks - quickView today 边界", () => {
  const cases = [
    { name: "恰好今日 00:00 命中", due: T0, hit: true },
    { name: "今日 23:59:59.999 命中", due: T0 + DAY_MS - 1, hit: true },
    { name: "明日 00:00 不命中", due: T0 + DAY_MS, hit: false },
  ];
  for (const c of cases) {
    it(c.name, () => {
      const out = filterTasks([mk({ id: 9, due_date: c.due })], { quickView: "today" });
      expect(out.map((t) => t.id)).toEqual(c.hit ? [9] : []);
    });
  }

  it("due_date 为 null 不命中", () => {
    const out = filterTasks([mk({ id: 9, due_date: null })], { quickView: "today" });
    expect(out).toEqual([]);
  });
});

describe("filterTasks - quickView week 边界（today ≤ d < today+7d）", () => {
  const cases = [
    { name: "今日 00:00 命中", due: T0 },
    { name: "today+6d23:59:59.999 命中", due: T0 + 7 * DAY_MS - 1 },
    { name: "恰好 today+7d 整点不命中", due: T0 + 7 * DAY_MS, hit: false },
  ] as Array<{ name: string; due: number; hit?: boolean }>;
  for (const c of cases) {
    it(c.name, () => {
      const out = filterTasks(
        [mk({ id: 9, due_date: c.due }), mk({ id: 8, due_date: T0 - 1 })],
        { quickView: "week" },
      );
      expect(out.map((t) => t.id)).toEqual(c.hit === false ? [] : [9]);
    });
  }
});

describe("filterTasks - quickView favorite / undone / done", () => {
  it("favorite：is_favorite 1 命中、0 不命中", () => {
    const tasks = [mk({ id: 1, is_favorite: 1 }), mk({ id: 2, is_favorite: 0 })];
    const out = filterTasks(tasks, { quickView: "favorite" });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("undone 视图只保留未完成", () => {
    const tasks = [mk({ id: 1, done: 0 }), mk({ id: 2, done: 1 })];
    const out = filterTasks(tasks, { quickView: "undone" });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("done 视图只保留已完成", () => {
    const tasks = [mk({ id: 1, done: 0 }), mk({ id: 2, done: 1 })];
    const out = filterTasks(tasks, { quickView: "done" });
    expect(out.map((t) => t.id)).toEqual([2]);
  });

  it("all 视图不过滤", () => {
    const tasks = [mk({ id: 1, done: 1 }), mk({ id: 2 })];
    expect(filterTasks(tasks, { quickView: "all" }).length).toBe(2);
  });
});

describe("filterTasks - keyword 大小写不敏感包含 title+description", () => {
  it("命中 title", () => {
    const out = filterTasks([mk({ id: 1, title: "Buy MILK tomorrow" })], { keyword: "milk" });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("命中 description", () => {
    const out = filterTasks(
      [mk({ id: 1, title: "x", description: "call the Bank" }), mk({ id: 2, title: "y", description: null })],
      { keyword: "bank" },
    );
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("null/空 keyword 放行全部", () => {
    const tasks = [mk({ id: 1, title: "a" }), mk({ id: 2, title: "b" })];
    expect(filterTasks(tasks, { keyword: null }).length).toBe(2);
    expect(filterTasks(tasks, {}).length).toBe(2);
  });
});

describe("filterTasks - statusFilter / priorityFilter", () => {
  it("statusFilter=done：done 标记或 status==='done' 均命中", () => {
    const tasks = [
      mk({ id: 1, done: 1, status: "pending" }),
      mk({ id: 2, done: 0, status: "done" }),
      mk({ id: 3, done: 0, status: "pending" }),
    ];
    const out = filterTasks(tasks, { statusFilter: "done" });
    expect(out.map((t) => t.id)).toEqual([1, 2]);
  });

  it("statusFilter=pending / doing / undone", () => {
    const tasks = [
      mk({ id: 1, done: 0, status: "pending" }),
      mk({ id: 2, done: 0, status: "doing" }),
      mk({ id: 3, done: 1, status: "done" }),
    ];
    expect(filterTasks(tasks, { statusFilter: "pending" }).map((t) => t.id)).toEqual([1]);
    expect(filterTasks(tasks, { statusFilter: "doing" }).map((t) => t.id)).toEqual([2]);
    expect(filterTasks(tasks, { statusFilter: "undone" }).map((t) => t.id)).toEqual([1, 2]);
  });

  it("priorityFilter 精确匹配数值", () => {
    const tasks = [mk({ id: 1, priority: 2 }), mk({ id: 2, priority: 3 })];
    expect(filterTasks(tasks, { priorityFilter: 2 }).map((t) => t.id)).toEqual([1]);
    expect(filterTasks(tasks, { priorityFilter: null }).length).toBe(2);
  });

  it("priorityFilter=0 命中无优先级任务（falsy 陷阱回归）", () => {
    const tasks = [mk({ id: 1, priority: 0 }), mk({ id: 2, priority: 2 })];
    const out = filterTasks(tasks, { priorityFilter: 0 });
    expect(out.map((t) => t.id)).toEqual([1]);
  });
});

describe("sortTasks - position 升序，同 position 按 created_at 降序", () => {
  it("position 升序", () => {
    const out = sortTasks([mk({ id: 3, position: 2 }), mk({ id: 1, position: 1 })]);
    expect(out.map((t) => t.id)).toEqual([1, 3]);
  });

  it("position 相同按 created_at 降序", () => {
    const out = sortTasks([
      mk({ id: 1, position: 1, created_at: 100 }),
      mk({ id: 2, position: 1, created_at: 300 }),
      mk({ id: 3, position: 1, created_at: 200 }),
    ]);
    expect(out.map((t) => t.id)).toEqual([2, 3, 1]);
  });

  it("不修改入参数组", () => {
    const input = [mk({ id: 2, position: 5 }), mk({ id: 1, position: 1 })];
    sortTasks(input);
    expect(input.map((t) => t.id)).toEqual([2, 1]);
  });
});

describe("工具栏筛选门控（桌面等价不变量锁定）", () => {
  it("projectId 视图下 statusFilter/priorityFilter 不生效", () => {
    const tasks = [
      mk({ id: 1, project_id: 3, done: 0, priority: 5 }),
      mk({ id: 2, project_id: 3, done: 1, priority: 1 }),
    ];
    const out = filterTasks(tasks, { projectId: 3, statusFilter: "done", priorityFilter: 1 });
    expect(out.map((t) => t.id).sort()).toEqual([1, 2]);
  });

  it("ungrouped 视图下 statusFilter/priorityFilter 不生效", () => {
    const tasks = [
      mk({ id: 1, project_id: null, done: 0, priority: 5 }),
      mk({ id: 2, project_id: null, done: 1, priority: 1 }),
    ];
    const out = filterTasks(tasks, { ungrouped: true, statusFilter: "done", priorityFilter: 1 });
    expect(out.map((t) => t.id).sort()).toEqual([1, 2]);
  });
});
