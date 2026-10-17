/**
 * 逾期一键顺延单测（G1 温和处置：不逐条消化逾期）
 *
 * 语义边界：
 * - 只有「逾期且未完成」的任务参与（due < now 且 !done）；
 * - 顺延落点 = 目标日（今天/明天），时间语义沿用 rescheduleDue（保时刻 / 零点归 18:00）；
 * - 无变化（如逾期任务原截止恰在目标日）跳过不写库。
 */
import { describe, expect, it } from "vitest";
import { planRollover, rolloverTargetDay } from "./rollover-overdue";
import type { TodoTaskListItem } from "@/lib/tauri";

function task(id: number, over: Partial<TodoTaskListItem> = {}): TodoTaskListItem {
  return {
    id,
    uuid: `u${id}`,
    title: `t${id}`,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    percent_done: 0,
    position: id * 100,
    is_favorite: 0,
    created_at: 0,
    updated_at: 0,
    version: 0,
    ...over,
  } as TodoTaskListItem;
}

describe("rolloverTargetDay 顺延落点日", () => {
  it("今天档 = 当天零点；明天档 = 次日零点", () => {
    const now = new Date(2026, 9, 17, 21, 30);
    expect(rolloverTargetDay("today", now)).toEqual(new Date(2026, 9, 17));
    expect(rolloverTargetDay("tomorrow", now)).toEqual(new Date(2026, 9, 18));
  });

  it("跨月/跨年边界按日历日推进（非固定 24h）", () => {
    const monthEnd = new Date(2026, 9, 31, 23, 59);
    expect(rolloverTargetDay("tomorrow", monthEnd)).toEqual(new Date(2026, 10, 1));
    const yearEnd = new Date(2026, 11, 31, 8, 0);
    expect(rolloverTargetDay("tomorrow", yearEnd)).toEqual(new Date(2027, 0, 1));
  });
});

describe("planRollover 顺延计划", () => {
  it("只挑逾期未完成任务，今日/未来/已完成不参与", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const overdue = task(1, { due_date: new Date(2026, 9, 15, 9, 0).getTime() }); // 前天 → 逾期
    const today = task(2, { due_date: new Date(2026, 9, 17, 22, 0).getTime() }); // 今天 22:00（此刻 20:00）→ 未到期
    const future = task(3, { due_date: new Date(2026, 9, 20, 9, 0).getTime() }); // 后天
    const done = task(4, { due_date: new Date(2026, 9, 15, 9, 0).getTime(), done: 1 });

    const plan = planRollover([overdue, today, future, done], "tomorrow", now);
    expect(plan.map((p) => p.task.id)).toEqual([1]);
  });

  it("逾期任务保留原时刻，只换日期", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const orig = new Date(2026, 9, 15, 9, 30).getTime();
    const plan = planRollover([task(1, { due_date: orig })], "tomorrow", now);
    expect(plan).toHaveLength(1);
    expect(new Date(plan[0].next!)).toEqual(new Date(2026, 9, 18, 9, 30));
  });

  it("零点（仅日期语义）落到目标日 18:00（rescheduleDue 同口径）", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const orig = new Date(2026, 9, 15, 0, 0).getTime();
    const plan = planRollover([task(1, { due_date: orig })], "tomorrow", now);
    expect(new Date(plan[0].next!)).toEqual(new Date(2026, 9, 18, 18, 0));
  });

  it("目标日无变化时跳过不写库（返回空计划）", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    // 昨天逾期、顺延到「今天」→ 目标日今天，原时刻保留 → 有变化；
    // 但若原截止已是今天早些时刻则不算逾期（due < now 但同日），用真实同日构造：
    const sameDay = new Date(2026, 9, 17, 9, 0).getTime(); // 今天 09:00，此刻 20:00 → 已逾期
    const plan = planRollover([task(1, { due_date: sameDay })], "today", now);
    expect(plan).toEqual([]);
  });

  it("空列表零计划", () => {
    expect(planRollover([], "tomorrow", Date.now())).toEqual([]);
  });
});
