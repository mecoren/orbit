import { describe, expect, it } from "vitest";

import { type TodoTask } from "@/lib/tauri";
import { filterTasks, groupDoneByDay, groupEisenhower, groupOverdueFirst, sortTasks, todayStartMs, toggleMyDayValue } from "./task-filters";

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

describe("sortTasks - 排序档位（#26：due/priority/title/created）", () => {
  it("due：有截止升序在前，无截止沉底", () => {
    const out = sortTasks(
      [
        mk({ id: 1, due_date: null }),
        mk({ id: 2, due_date: 300 }),
        mk({ id: 3, due_date: 100 }),
        mk({ id: 4, due_date: 200 }),
      ],
      "due",
    );
    expect(out.map((t) => t.id)).toEqual([3, 4, 2, 1]);
  });

  it("priority：大者在前，同优先级落回拖拽顺序", () => {
    const out = sortTasks(
      [
        mk({ id: 1, priority: 2, position: 1 }),
        mk({ id: 2, priority: 5, position: 3 }),
        mk({ id: 3, priority: 2, position: 0 }),
      ],
      "priority",
    );
    expect(out.map((t) => t.id)).toEqual([2, 3, 1]);
  });

  it("title：中文按 locale 拼音序升序", () => {
    const out = sortTasks(
      [mk({ id: 1, title: "周会" }), mk({ id: 2, title: "备份" }), mk({ id: 3, title: "吃饭" })],
      "title",
    );
    expect(out.map((t) => t.id)).toEqual([2, 3, 1]);
  });

  it("created：创建时间降序（最新在前）", () => {
    const out = sortTasks(
      [mk({ id: 1, created_at: 100 }), mk({ id: 2, created_at: 300 }), mk({ id: 3, created_at: 200 })],
      "created",
    );
    expect(out.map((t) => t.id)).toEqual([2, 3, 1]);
  });

  it("manual（缺省）：维持 position 升序语义不变", () => {
    const out = sortTasks([mk({ id: 3, position: 2 }), mk({ id: 1, position: 1 })], "manual");
    expect(out.map((t) => t.id)).toEqual([1, 3]);
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

describe("filterTasks - quickView my_day（我的一天）", () => {
  /** 与 filterTasks 内部同口径的「今天零点」 */
  const todayStart = () => {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  };

  it("my_day_date == 今天零点 命中", () => {
    const tasks = [mk({ id: 1, my_day_date: todayStart() })];
    expect(filterTasks(tasks, { quickView: "my_day" }).map((t) => t.id)).toEqual([1]);
  });

  it("昨天加入的（my_day_date = 今天-1d）不命中——次日自动退出视图", () => {
    const yesterday = todayStart() - 24 * 3600 * 1000;
    const tasks = [mk({ id: 1, my_day_date: yesterday })];
    expect(filterTasks(tasks, { quickView: "my_day" })).toEqual([]);
  });

  it("null（从未加入）不命中", () => {
    const tasks = [mk({ id: 1, my_day_date: null })];
    expect(filterTasks(tasks, { quickView: "my_day" })).toEqual([]);
  });

  it("已完成任务也保留在 My Day 视图（勾选后不消失，取消完成可反复）", () => {
    const tasks = [mk({ id: 1, my_day_date: todayStart(), done: 1 })];
    expect(filterTasks(tasks, { quickView: "my_day" }).map((t) => t.id)).toEqual([1]);
  });

  it("My Day 视图下状态筛选仍生效（与其它快捷视图同口径）", () => {
    const tasks = [
      mk({ id: 1, my_day_date: todayStart(), done: 0 }),
      mk({ id: 2, my_day_date: todayStart(), done: 1 }),
    ];
    expect(
      filterTasks(tasks, { quickView: "my_day", statusFilter: "undone" }).map((t) => t.id),
    ).toEqual([1]);
  });
});

describe("todayStartMs / toggleMyDayValue 我的一天零点口径", () => {
  // 固定基准：2026-09-11 15:30 本地时区——零点=当日 00:00
  const base = new Date(2026, 8, 11, 15, 30, 0, 0);
  const zeroPoint = new Date(2026, 8, 11, 0, 0, 0, 0).getTime();

  it("todayStartMs 取本地零点（含时分秒时刻归零）", () => {
    expect(todayStartMs(base)).toBe(zeroPoint);
  });

  it("toggleMyDayValue：未加入 → 写今天零点（加入）", () => {
    expect(toggleMyDayValue(null, base)).toBe(zeroPoint);
  });

  it("toggleMyDayValue：已加入（== 今天零点）→ null（移出）", () => {
    expect(toggleMyDayValue(zeroPoint, base)).toBeNull();
  });

  it("toggleMyDayValue：昨天加入 → 仍写今天零点（次日加入新的一天）", () => {
    const yesterday = new Date(2026, 8, 10, 0, 0, 0, 0).getTime();
    expect(toggleMyDayValue(yesterday, base)).toBe(zeroPoint);
  });

  it("toggleMyDayValue：拒绝非零点残留值（Date.now() 类脏数据不匹配判定，重新对齐零点）", () => {
    const dirty = new Date(2026, 8, 11, 15, 30, 0, 0).getTime();
    expect(toggleMyDayValue(dirty, base)).toBe(zeroPoint);
  });
});

describe("groupOverdueFirst 逾期置顶分组", () => {
  const NOW = 1_700_000_000_000;

  it("未完成且截止已过 → 逾期区；其余（无截止/未到期/已完成）→ rest 区", () => {
    const tasks = [
      mk({ id: 1, done: 0, due_date: NOW - 1000 }),
      mk({ id: 2, done: 0, due_date: null }),
      mk({ id: 3, done: 0, due_date: NOW + 1000 }),
      mk({ id: 4, done: 1, due_date: NOW - 1000 }),
    ];
    const g = groupOverdueFirst(tasks, NOW);
    expect(g.overdue.map((t) => t.id)).toEqual([1]);
    expect(g.rest.map((t) => t.id)).toEqual([2, 3, 4]);
  });

  it("无逾期任务时 overdue 为空、rest 为全量原序", () => {
    const tasks = [mk({ id: 1 }), mk({ id: 2 })];
    const g = groupOverdueFirst(tasks, NOW);
    expect(g.overdue).toEqual([]);
    expect(g.rest.map((t) => t.id)).toEqual([1, 2]);
  });

  it("due_date 恰等于 now 不算逾期（未过日界口径，左开右闭）", () => {
    const tasks = [mk({ id: 1, done: 0, due_date: NOW })];
    const g = groupOverdueFirst(tasks, NOW);
    expect(g.overdue).toEqual([]);
    expect(g.rest.map((t) => t.id)).toEqual([1]);
  });

  it("分组保持原相对顺序（逾期区内部顺序不重排）", () => {
    const tasks = [
      mk({ id: 3, done: 0, due_date: NOW - 3000 }),
      mk({ id: 1, done: 0, due_date: NOW - 1000 }),
      mk({ id: 2, done: 0, due_date: NOW - 2000 }),
    ];
    const g = groupOverdueFirst(tasks, NOW);
    expect(g.overdue.map((t) => t.id)).toEqual([3, 1, 2]);
  });
});

describe("filterTasks - hideDone 隐藏已完成（Logbook 治理）", () => {
  it("hideDone 剔除 done 任务，未完成保留", () => {
    const tasks = [
      mk({ id: 1, done: 0 }),
      mk({ id: 2, done: 1, done_at: T0 + 1000 }),
      mk({ id: 3, done: 0, status: "doing" }),
    ];
    const out = filterTasks(tasks, { hideDone: true });
    expect(out.map((t) => t.id)).toEqual([1, 3]);
  });

  it("默认不隐藏（hideDone 缺省 = 现行为不变）", () => {
    const tasks = [mk({ id: 1, done: 1, done_at: T0 })];
    const out = filterTasks(tasks, {});
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("quickView=done 下 hideDone 不生效（完成集入口，否则开关清成空列表）", () => {
    const tasks = [mk({ id: 1, done: 1, done_at: T0 })];
    const out = filterTasks(tasks, { quickView: "done", hideDone: true });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("statusFilter=done 下 hideDone 不生效（明确要看完成集的筛选档）", () => {
    const tasks = [mk({ id: 1, done: 1, done_at: T0 })];
    const out = filterTasks(tasks, { statusFilter: "done", hideDone: true });
    expect(out.map((t) => t.id)).toEqual([1]);
  });

  it("hideDone 在项目视图下同样生效（项目内完成行也隐藏）", () => {
    const tasks = [
      mk({ id: 1, project_id: 5, done: 0 }),
      mk({ id: 2, project_id: 5, done: 1, done_at: T0 }),
    ];
    const out = filterTasks(tasks, { projectId: 5, hideDone: true });
    expect(out.map((t) => t.id)).toEqual([1]);
  });
});

describe("groupDoneByDay 完成日分组（Logbook 数据源）", () => {
  // 固定时区安全基准：本地 2026-09-12（避免跨时区 CI 漂移用本地构造）
  const d12 = new Date(2026, 8, 12);
  const ms10 = (h: number) => new Date(2026, 8, 10, h).getTime();
  const ms12 = (h: number) => new Date(2026, 8, 12, h).getTime();

  it("按 done_at 本地日分组，组间倒序（最近完成日在最前）", () => {
    const tasks = [
      mk({ id: 1, done_at: ms10(9) }),
      mk({ id: 2, done_at: ms12(20) }),
      mk({ id: 3, done_at: ms12(8) }),
    ];
    const groups = groupDoneByDay(tasks, d12);
    expect(groups.map((g) => g.key)).toEqual(["2026-09-12", "2026-09-10"]);
    expect(groups[0].tasks.map((t) => t.id)).toEqual([2, 3]);
  });

  it("组内按完成时刻倒序（同日晚完成的排前）", () => {
    const tasks = [
      mk({ id: 1, done_at: ms12(9) }),
      mk({ id: 2, done_at: ms12(21) }),
    ];
    const groups = groupDoneByDay(tasks, d12);
    expect(groups[0].tasks.map((t) => t.id)).toEqual([2, 1]);
  });

  it("done_at 缺失的脏行兜底落 created_at 日", () => {
    const tasks = [
      mk({ id: 1, done_at: null, created_at: ms10(15) }),
      mk({ id: 2, done_at: ms12(10) }),
    ];
    const groups = groupDoneByDay(tasks, d12);
    expect(groups.map((g) => g.key)).toEqual(["2026-09-12", "2026-09-10"]);
    expect(groups[1].tasks.map((t) => t.id)).toEqual([1]);
  });

  it("空集返回空数组", () => {
    expect(groupDoneByDay([], d12)).toEqual([]);
  });
});

describe("groupEisenhower - 四象限分组（TickTick 矩阵口径，与移动端逐字对齐）", () => {
  // 固定"2026-09-25 14:00"注入，测试与运行日期无关
  const now = new Date(2026, 8, 25, 14, 0);
  const todayEnd = new Date(2026, 8, 26).getTime(); // 今天 24:00 = 紧急界

  it("轴口径：重要 = 优先级≥3，紧急 = 截止≤今天末（含逾期），无截止 = 不紧急", () => {
    const buckets = groupEisenhower(
      [
        mk({ id: 1, priority: 3, due_date: now.getTime() }), // 紧急重要
        mk({ id: 2, priority: 5 }), // 重要不紧急（无截止）
        mk({ id: 3, priority: 0, due_date: todayEnd - 1 }), // 紧急不重要
        mk({ id: 4 }), // 双无
        mk({ id: 5, priority: 2, due_date: todayEnd - 1 }), // 中优先级不算重要
        mk({ id: 6, priority: 3, due_date: todayEnd }), // 明天 0 点起 = 不紧急
      ],
      now,
    );
    expect(buckets.urgentImportant.map((t) => t.id)).toEqual([1]);
    expect(buckets.importantNotUrgent.map((t) => t.id)).toEqual([2, 6]);
    expect(buckets.urgentNotImportant.map((t) => t.id)).toEqual([3, 5]);
    expect(buckets.neither.map((t) => t.id)).toEqual([4]);
  });

  it("已完成不入桶；组内保持入参顺序（排序在调用方做）", () => {
    const buckets = groupEisenhower(
      [
        mk({ id: 1, priority: 3, due_date: now.getTime(), done: 1, status: "done" }),
        mk({ id: 2, priority: 4 }),
        mk({ id: 3, priority: 4 }),
      ],
      now,
    );
    expect(buckets.urgentImportant).toHaveLength(0);
    expect(buckets.importantNotUrgent.map((t) => t.id)).toEqual([2, 3]);
  });

  it("空输入返回四空桶（矩阵格可直接按桶渲染）", () => {
    const buckets = groupEisenhower([], now);
    expect(Object.keys(buckets)).toHaveLength(4);
    expect(Object.values(buckets).every((l) => l.length === 0)).toBe(true);
  });
});
