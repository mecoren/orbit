import { describe, expect, it } from "vitest";

import type { TodoProject, TodoTask, ProjectedTaskLabel } from "@/lib/tauri";
import {
  dueBucketOf,
  dueBucketRepresentative,
  kanbanColumnKey,
  kanbanColumns,
  kanbanFallbackKey,
  primaryLabelId,
  type DueBucket,
} from "./kanban-group";

const DAY = 86_400_000;
// 2026-10-05 周一（ mech 周档口径：周一起始）
const monday = (h = 0, m = 0) => new Date(2026, 9, 5, h, m).getTime();

function task(partial: Partial<TodoTask> = {}): TodoTask {
  return {
    id: 1,
    uuid: "u1",
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
    repeat_after: 0,
    repeat_weekdays: 0,
    repeat_end_type: 0,
    repeat_end_param: 0,
    repeat_from_done: 0,
    percent_done: 0,
    position: 1,
    is_favorite: 0,
    my_day_date: null,
    duration_minutes: null,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
    ...partial,
  } as TodoTask;
}

function project(id: number, title: string): TodoProject {
  return {
    id,
    uuid: `p${id}`,
    title,
    description: null,
    hex_color: "#4E8CFF",
    is_archived: 0,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
  } as TodoProject;
}

function label(id: number, title: string): ProjectedTaskLabel {
  return { id, title, hex_color: "#3B82F6" };
}

describe("dueBucketOf（截止五分桶）", () => {
  const now = monday(12);

  it("逾期 / 今天 / 本周 / 以后 / 无日期", () => {
    expect(dueBucketOf(monday(9) - DAY, now)).toBe("overdue");
    expect(dueBucketOf(monday(9), now)).toBe("today");
    expect(dueBucketOf(monday(9) + 3 * DAY, now)).toBe("week");
    expect(dueBucketOf(monday(9) + 30 * DAY, now)).toBe("later");
    expect(dueBucketOf(null, now)).toBe("none");
  });

  it("边界：今日零点归今天，+7 天整归以后", () => {
    const t0 = new Date(2026, 9, 5).getTime();
    expect(dueBucketOf(t0, now)).toBe("today");
    expect(dueBucketOf(t0 - 1, now)).toBe("overdue");
    expect(dueBucketOf(t0 + 7 * DAY, now)).toBe("later");
    expect(dueBucketOf(t0 + 7 * DAY - 1, now)).toBe("week");
  });

  it("非法值回落无日期", () => {
    expect(dueBucketOf(Number.NaN, now)).toBe("none");
    expect(dueBucketOf(undefined, now)).toBe("none");
  });
});

describe("dueBucketRepresentative（桶代表时刻恒落自家）", () => {
  // 周一~周日逐日锁定：代表时刻拖后卡片不跳桶
  const buckets: DueBucket[] = ["overdue", "today", "week", "later"];
  for (let dow = 0; dow < 7; dow++) {
    it(`周${["一", "二", "三", "四", "五", "六", "日"][dow]}各桶代表恒落自家`, () => {
      const now = monday(12) + dow * DAY;
      for (const b of buckets) {
        const rep = dueBucketRepresentative(b, now);
        expect(rep).not.toBeNull();
        expect(dueBucketOf(rep, now)).toBe(b);
      }
      expect(dueBucketRepresentative("none", now)).toBeNull();
    });
  }

  it("今天代表 = 当日 18:00（atViewDueHour 口径）", () => {
    expect(dueBucketRepresentative("today", monday(12))).toBe(monday(18));
    expect(dueBucketRepresentative("overdue", monday(12))).toBe(
      new Date(2026, 9, 4, 18).getTime(),
    );
  });
});

describe("kanbanColumns（分列）", () => {
  const labelsByTask = new Map<number, ProjectedTaskLabel[]>();

  it("status：固定三列", () => {
    const cols = kanbanColumns("status", [], labelsByTask, []);
    expect(cols.map((c) => c.key)).toEqual(["pending", "doing", "done"]);
  });

  it("priority：P5→P0 固定六列", () => {
    const cols = kanbanColumns("priority", [], labelsByTask, []);
    expect(cols.map((c) => c.key)).toEqual([
      "pri:5",
      "pri:4",
      "pri:3",
      "pri:2",
      "pri:1",
      "pri:0",
    ]);
    expect(cols[0].title).toBe("立即处理");
    expect(cols[5].title).toBe("无");
  });

  it("label：有任务标签各一列（标题排序）+ 末列未贴标签", () => {
    const tasks = [task({ id: 1 }), task({ id: 2 }), task({ id: 3 })];
    const byTask = new Map<number, ProjectedTaskLabel[]>([
      [1, [label(2, "工作"), label(1, "生活")]],
      [2, [label(2, "工作")]],
    ]);
    const cols = kanbanColumns("label", [], byTask, tasks);
    expect(cols.map((c) => c.key)).toEqual(["lbl:2", "lbl:1", "lbl:none"]);
    // 标题排序：工作 < 生活（localeCompare 中文拼音序）
    expect(cols.map((c) => c.title)).toEqual(["工作", "生活", "未贴标签"]);
  });

  it("label：空任务集只有未贴标签列", () => {
    const cols = kanbanColumns("label", [], new Map(), []);
    expect(cols.map((c) => c.key)).toEqual(["lbl:none"]);
  });

  it("due：固定五桶", () => {
    const cols = kanbanColumns("due", [], labelsByTask, []);
    expect(cols.map((c) => c.key)).toEqual([
      "due:overdue",
      "due:today",
      "due:week",
      "due:later",
      "due:none",
    ]);
  });

  it("project：全部项目 + 末列未分组（历史口径：空项目列保留）", () => {
    const cols = kanbanColumns(
      "project",
      [project(2, "乙"), project(1, "甲")],
      labelsByTask,
      [],
    );
    expect(cols.map((c) => c.key)).toEqual(["1", "2", "ungrouped"]);
  });
});

describe("kanbanColumnKey（归属键）", () => {
  const empty = new Map<number, ProjectedTaskLabel[]>();
  const now = monday(12);

  it("priority/label/due 三档", () => {
    expect(kanbanColumnKey("priority", task({ priority: 4 }), empty, now)).toBe("pri:4");
    const byTask = new Map<number, ProjectedTaskLabel[]>([
      [1, [label(9, "乙"), label(3, "甲")]],
    ]);
    // 多标签取最小 id 单归属
    expect(kanbanColumnKey("label", task({ id: 1 }), byTask, now)).toBe("lbl:3");
    expect(kanbanColumnKey("label", task({ id: 7 }), byTask, now)).toBe("lbl:none");
    expect(
      kanbanColumnKey("due", task({ due_date: monday(9) - DAY }), empty, now),
    ).toBe("due:overdue");
    expect(kanbanColumnKey("due", task({ due_date: null }), empty, now)).toBe("due:none");
  });

  it("脏值回落（status 脏值不再抛异常）", () => {
    expect(kanbanColumnKey("status", task({ status: "weird" }), empty, now)).toBe("pending");
    expect(kanbanColumnKey("priority", task({ priority: 99 }), empty, now)).toBe("pri:0");
    expect(kanbanFallbackKey("status")).toBe("pending");
    expect(kanbanFallbackKey("project")).toBe("ungrouped");
    expect(kanbanFallbackKey("priority")).toBe("pri:0");
    expect(kanbanFallbackKey("label")).toBe("lbl:none");
    expect(kanbanFallbackKey("due")).toBe("due:none");
  });

  it("primaryLabelId：最小 id / 空表 null", () => {
    expect(primaryLabelId([label(5, "a"), label(2, "b")])).toBe(2);
    expect(primaryLabelId([])).toBeNull();
    expect(primaryLabelId(undefined)).toBeNull();
  });
});
