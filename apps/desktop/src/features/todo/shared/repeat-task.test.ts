// apps/desktop/src/features/todo/shared/repeat-task.test.ts
// planNextRecurringInstance / subtasksToClone 纯逻辑测试（07 报告 §五-P1#10）
import { describe, expect, it } from "vitest";

import type { TodoSubtask, TodoTask } from "@/lib/tauri";
import { nextRepeatAt, REPEAT_MODE } from "./repeat";
import { planNextRecurringInstance, subtasksToClone } from "./repeat-task";

const DAY = 86_400_000;

/** mk：补齐 TodoTask 必要字段的工厂（其余字段测试不关心，给安全默认值） */
function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1, uuid: "u", title: "任务", description: null, project_id: null,
    priority: 0, status: "pending", done: 0, done_at: null,
    due_date: null, start_date: null, end_date: null,
    repeat_after: 1, repeat_mode: 0, percent_done: 0,
    position: 0, is_favorite: 0, is_deleted: 0,
    created_at: 0, updated_at: 0, deleted_at: null, version: 1,
    ...partial,
  };
}

function sub(partial: Partial<TodoSubtask>): TodoSubtask {
  return {
    id: 1, uuid: "s", task_id: 1, title: "子任务", done: 0, done_at: null,
    position: 0, is_deleted: 0, created_at: 0, updated_at: 0,
    deleted_at: null, version: 1,
    ...partial,
  };
}

describe("planNextRecurringInstance", () => {
  it("每天：next = 原 due + 1 天；start/end 平移同一 delta", () => {
    const due = new Date(2026, 7, 27).getTime();
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.DAILY, repeat_after: 1, due_date: due, start_date: due - DAY }),
      new Date(2026, 7, 26, 12).getTime(),
    )!;
    expect(plan.input.due_date).toBe(due + DAY);
    expect(plan.deltaMs).toBe(DAY);
    expect(plan.input.start_date).toBe(due);
    expect(plan.input.status).toBe("pending");
    expect(plan.input.done).toBe(0);
    expect(plan.input.repeat_mode).toBe(REPEAT_MODE.DAILY);
  });

  it("提前完成仍按原排程推进（from=now 不影响第一步）", () => {
    const due = new Date(2026, 8, 1).getTime(); // 未来到期就提前勾完
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.WEEKLY, due_date: due }),
      new Date(2026, 7, 26).getTime(),
    )!;
    expect(plan.input.due_date).toBe(due + 7 * DAY);
  });

  it("长期逾期：快进到 now 之后最近的一次", () => {
    const due = new Date(2026, 7, 10).getTime(); // 已逾期 16 天
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.DAILY, due_date: due }),
      new Date(2026, 7, 26).getTime(),
    )!;
    expect(plan.input.due_date).toBe(new Date(2026, 7, 27).getTime()); // >now 的首个序列点
  });

  it("每月：月末截断由 nextRepeatAt 保证（1/31 → 2/28）", () => {
    const due = new Date(2026, 0, 31).getTime();
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.MONTHLY, due_date: due }),
      new Date(2026, 1, 1).getTime(),
    )!;
    expect(new Date(plan.input.due_date!).getDate()).toBe(28);
    expect(new Date(plan.input.due_date!).getMonth()).toBe(1);
  });

  it("无规则 / 无 due → null", () => {
    expect(planNextRecurringInstance(mk({ repeat_mode: 0 }), Date.now())).toBeNull();
    expect(planNextRecurringInstance(mk({ repeat_mode: REPEAT_MODE.DAILY }), Date.now())).toBeNull();
  });

  it("克隆字段：标题/描述/项目/优先级/收藏带过去，uuid/id 不带", () => {
    const plan = planNextRecurringInstance(
      mk({
        repeat_mode: REPEAT_MODE.DAILY, due_date: Date.now() + DAY,
        title: "晨会", description: "站会", project_id: 5, priority: 2,
        is_favorite: 1,
      }),
      Date.now(),
    )!;
    expect(plan.input.title).toBe("晨会");
    expect(plan.input.description).toBe("站会");
    expect(plan.input.project_id).toBe(5);
    expect(plan.input.priority).toBe(2);
    expect(plan.input.is_favorite).toBe(1);
    expect("id" in plan.input).toBe(false);
    expect("uuid" in plan.input).toBe(false);
  });
});

describe("subtasksToClone", () => {
  it("过滤软删、按 position 升序、只留标题与位置", () => {
    const rows = [
      sub({ id: 3, title: "丙", position: 2 }),
      sub({ id: 1, title: "甲", position: 0 }),
      sub({ id: 2, title: "乙", position: 1, is_deleted: 1 }),
    ];
    expect(subtasksToClone(rows)).toEqual([
      { title: "甲", position: 0 },
      { title: "丙", position: 2 },
    ]);
  });
});

describe("nextRepeatAt · 月末截断回归（评审 I3，锁定 repeat.ts 修复）", () => {
  it("YEARLY：闰日 2024-02-29 推进一年 clamp 到 2025-02-28（而非滚到 03-01）", () => {
    const base = new Date(2024, 1, 29).getTime();
    const next = nextRepeatAt(base, REPEAT_MODE.YEARLY, 1, new Date(2024, 5, 1).getTime())!;
    expect(new Date(next).getFullYear()).toBe(2025);
    expect(new Date(next).getMonth()).toBe(1);
    expect(new Date(next).getDate()).toBe(28);
  });

  it("MONTHLY：月末日链式推进不回弹（1/31 → 2/28 → 3/28）", () => {
    const jan31 = new Date(2026, 0, 31).getTime();
    const feb = nextRepeatAt(jan31, REPEAT_MODE.MONTHLY, 1, jan31)!;
    expect(new Date(feb).getMonth()).toBe(1);
    expect(new Date(feb).getDate()).toBe(28);
    const mar = nextRepeatAt(feb, REPEAT_MODE.MONTHLY, 1, feb)!;
    expect(new Date(mar).getMonth()).toBe(2);
    expect(new Date(mar).getDate()).toBe(28);
  });
});
