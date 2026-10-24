import { describe, expect, it } from "vitest";

import type { TodoProject, TodoTaskListItem } from "@/lib/tauri";

import {
  TRIAGE_PRIORITY_CYCLE,
  collectTriageQueue,
  formatTriageSummary,
  nextTriagePriority,
  projectKeyMap,
} from "./triage";

function task(p: Partial<TodoTaskListItem>): TodoTaskListItem {
  return {
    id: 1,
    title: "t",
    description: null,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    repeat_mode: 0,
    percent_done: 0,
    position: 0,
    is_favorite: 0,
    my_day_date: null,
    duration_minutes: null,
    is_deleted: 0,
    created_at: 1,
    updated_at: 1,
    ...p,
  } as TodoTaskListItem;
}

function proj(id: number, sort: number, archived = 0): TodoProject {
  return {
    id,
    uuid: `u${id}`,
    title: `项目${id}`,
    description: null,
    hex_color: "#3B82F6",
    sort_order: sort,
    parent_uuid: null,
    review_interval_days: null,
    review_last_at: null,
    review_snooze_until: null,
    is_archived: archived,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
  };
}

describe("collectTriageQueue", () => {
  it("只收未分组的未完成任务", () => {
    const queue = collectTriageQueue([
      task({ id: 1, title: "收件箱任务" }),
      task({ id: 2, project_id: 5, title: "已有项目" }),
      task({ id: 3, done: 1, title: "已完成" }),
      task({ id: 4, due_date: 123, title: "有日期但未分组" }),
    ]);
    expect(queue.map((t) => t.id)).toEqual([1, 4]);
  });

  it("排序对齐未分组列表 manual 档：position 升序 → created_at 降序", () => {
    const queue = collectTriageQueue([
      task({ id: 1, position: 3, created_at: 100 }),
      task({ id: 2, position: 1, created_at: 50 }),
      task({ id: 3, position: 1, created_at: 90 }),
    ]);
    expect(queue.map((t) => t.id)).toEqual([3, 2, 1]);
  });
});

describe("projectKeyMap", () => {
  it("数字键 1-9 映射列表序前 9 个活跃项目", () => {
    const projects = Array.from({ length: 12 }, (_, i) => proj(i + 1, i));
    const map = projectKeyMap(projects);
    expect(map.size).toBe(9);
    expect(map.get(1)?.id).toBe(1);
    expect(map.get(9)?.id).toBe(9);
    expect(map.has(0)).toBe(false);
  });

  it("归档项目不占键位", () => {
    const map = projectKeyMap([proj(10, 0, 1), proj(2, 1)]);
    expect(map.get(1)?.id).toBe(2);
  });
});

describe("nextTriagePriority", () => {
  it("循环 无→高→紧急→无", () => {
    expect(nextTriagePriority(0)).toBe(3);
    expect(nextTriagePriority(3)).toBe(4);
    expect(nextTriagePriority(4)).toBe(0);
  });

  it("循环外的档位（低/中/立即处理）回落到循环下一档", () => {
    // 循环 indexOf 命不中返回 -1 → (+1)%3 = 0 档（无）——从任意脏值回到循环内
    expect(TRIAGE_PRIORITY_CYCLE).toContain(nextTriagePriority(1));
    expect(TRIAGE_PRIORITY_CYCLE).toContain(nextTriagePriority(2));
    expect(TRIAGE_PRIORITY_CYCLE).toContain(nextTriagePriority(5));
  });
});

describe("formatTriageSummary", () => {
  it("归属与排期合计「已分诊」；跳过恒显；删除为 0 时省略", () => {
    expect(formatTriageSummary(3, 2, 1, 0)).toBe("已分诊 5 · 跳过 1");
    expect(formatTriageSummary(3, 2, 1, 2)).toBe("已分诊 5 · 跳过 1 · 删除 2");
  });
});
