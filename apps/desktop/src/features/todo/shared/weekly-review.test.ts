/**
 * 周回顾纯函数单测（G5：引导式 Weekly Review）
 *
 * 三组清单口径：
 * - overdue：逾期未完成（due < 今天零点；今天到期不算逾期）；
 * - undated：无截止日的未完成任务（GTD「下一步」盲区）；
 * - stalled：停滞未完成（updated_at 超 7 天未动，需唤醒）。
 * 三组互斥不要求——stalled 可与 overdue/undated 重叠（同一任务既是逾期
 * 又停滞，就是最需要唤醒的），但每组内去重。
 */
import { describe, expect, it } from "vitest";
import { collectWeeklyReview, REVIEW_STALL_DAYS } from "./weekly-review";
import type { TodoTaskListItem } from "@/lib/tauri";

const DAY = 86_400_000;

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
    duration_minutes: null,
    percent_done: 0,
    position: id * 100,
    is_favorite: 0,
    created_at: 0,
    updated_at: 0,
    version: 0,
    ...over,
  } as TodoTaskListItem;
}

describe("collectWeeklyReview 三组清单", () => {
  it("overdue：逾期未完成；今天到期不算逾期", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const todayZero = new Date(2026, 9, 17, 0, 0).getTime();
    const r = collectWeeklyReview(
      [
        task(1, { due_date: todayZero - DAY }), // 昨天 → 逾期
        task(2, { due_date: todayZero + 1 }), // 今天 → 不算逾期
        task(3, { due_date: todayZero - DAY, done: 1 }), // 已完成
      ],
      now,
    );
    expect(r.overdue.map((t) => t.id)).toEqual([1]);
  });

  it("undated：无截止日的未完成任务", () => {
    const now = Date.now();
    const r = collectWeeklyReview(
      [
        task(1, { due_date: null }),
        task(2, { due_date: now }),
        task(3, { due_date: null, done: 1 }),
      ],
      now,
    );
    expect(r.undated.map((t) => t.id)).toEqual([1]);
  });

  it("stalled：updated_at 超 7 天未动的未完成任务", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const r = collectWeeklyReview(
      [
        task(1, { updated_at: now - (REVIEW_STALL_DAYS + 1) * DAY }), // 8 天前 → 停滞
        task(2, { updated_at: now - 3 * DAY }), // 3 天前 → 不停滞
        task(3, { updated_at: now - 10 * DAY, done: 1 }), // 已完成不计
      ],
      now,
    );
    expect(r.stalled.map((t) => t.id)).toEqual([1]);
  });

  it("停滞与逾期可重叠（同一任务多组出现）", () => {
    const now = new Date(2026, 9, 17, 20, 0).getTime();
    const overdueDue = new Date(2026, 9, 10, 9, 0).getTime();
    const r = collectWeeklyReview(
      [task(1, { due_date: overdueDue, updated_at: now - 10 * DAY })],
      now,
    );
    expect(r.overdue.map((t) => t.id)).toEqual([1]);
    expect(r.stalled.map((t) => t.id)).toEqual([1]);
  });

  it("空列表三组皆空", () => {
    const r = collectWeeklyReview([], Date.now());
    expect(r.overdue).toEqual([]);
    expect(r.undated).toEqual([]);
    expect(r.stalled).toEqual([]);
  });
});

describe("REVIEW_STALL_DAYS 常量", () => {
  it("停滞阈值 7 天", () => {
    expect(REVIEW_STALL_DAYS).toBe(7);
  });
});
