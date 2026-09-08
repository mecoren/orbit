import { describe, expect, it } from "vitest";

import type { TodoTask } from "@/lib/tauri";
import { applySavedFilter } from "./saved-filter";

const DAY = 86_400_000;

function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1,
    uuid: "u",
    title: "",
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
    repeat_weekdays: 0,
    repeat_end_type: 0,
    repeat_end_param: 0,
    repeat_from_done: 0,
    percent_done: 0,
    position: 0,
    is_favorite: 0,
    my_day_date: null,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
    ...partial,
  };
}

describe("applySavedFilter", () => {
  it("缺键不过滤：{} 全量通过", () => {
    const tasks = [mk({ id: 1 }), mk({ id: 2, done: 1 })];
    expect(applySavedFilter(tasks, "{}", {}).length).toBe(2);
  });

  it("损坏 JSON 防御性全通过", () => {
    expect(applySavedFilter([mk({ id: 1 })], "not-json", {}).length).toBe(1);
  });

  it("priority_min + due_within_days 组合（P4+ 且 7 天内截止）", () => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const T0 = today.getTime();
    const tasks = [
      mk({ id: 1, priority: 4, due_date: T0 + DAY }), // 命中
      mk({ id: 2, priority: 4, due_date: T0 + 8 * DAY }), // 超窗
      mk({ id: 3, priority: 2, due_date: T0 + DAY }), // 低优先
      mk({ id: 4, priority: 5 }), // 无 due
    ];
    const out = applySavedFilter(
      tasks,
      JSON.stringify({ priority_min: 4, due_within_days: 7 }),
      {},
    );
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("due_overdue：仅未完成 + 已过今天零点", () => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const T0 = today.getTime();
    const tasks = [
      mk({ id: 1, due_date: T0 - DAY }), // 命中
      mk({ id: 2, due_date: T0 - DAY, done: 1 }), // 已完成不算逾期
      mk({ id: 3, due_date: T0 + DAY }), // 未到期
    ];
    const out = applySavedFilter(tasks, JSON.stringify({ due_overdue: true }), {});
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("project_ids 任一命中 + favorite_only", () => {
    const tasks = [
      mk({ id: 1, project_id: 3, is_favorite: 1 }), // 命中
      mk({ id: 2, project_id: 5, is_favorite: 1 }), // 项目不命中
      mk({ id: 3, project_id: 3, is_favorite: 0 }), // 未收藏
      mk({ id: 4, project_id: null, is_favorite: 1 }), // 未分组
    ];
    const out = applySavedFilter(
      tasks,
      JSON.stringify({ project_ids: [3, 7], favorite_only: true }),
      {},
    );
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("label_ids 经标签索引任一命中", () => {
    const tasks = [mk({ id: 1 }), mk({ id: 2 })];
    const labelIndex = { 1: [10, 20], 2: [30] };
    const out = applySavedFilter(
      tasks,
      JSON.stringify({ label_ids: [20, 99] }),
      labelIndex,
    );
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("status 等值", () => {
    const tasks = [mk({ id: 1, status: "doing" }), mk({ id: 2, status: "pending" })];
    const out = applySavedFilter(tasks, JSON.stringify({ status: "doing" }), {});
    expect(out.map((t) => t.id)).toEqual([1]);
  });
});
