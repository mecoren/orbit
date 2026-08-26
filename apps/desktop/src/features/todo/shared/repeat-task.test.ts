// apps/desktop/src/features/todo/shared/repeat-task.test.ts
// planNextRecurringInstance / subtasksToClone 纯逻辑测试（07 报告 §五-P1#10）
import { describe, expect, it } from "vitest";

import type { TodoSubtask, TodoTask } from "@/lib/tauri";
import { REPEAT_MODE } from "./repeat";
import { planNextRecurringInstance, subtasksToClone } from "./repeat-task";

const DAY = 86_400_000;

/** mk：补齐 TodoTask 必要字段的工厂（其余字段测试不关心，给安全默认值） */
function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1, uuid: "u", title: "任务", description: null, project_id: null,
    priority: 0, status: "pending", done: 0, done_at: null,
    due_date: null, start_date: null, end_date: null,
    repeat_after: 1, repeat_mode: 0, hex_color: "", percent_done: 0,
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

  it("克隆字段：标题/描述/项目/优先级/颜色/收藏带过去，uuid/id 不带", () => {
    const plan = planNextRecurringInstance(
      mk({
        repeat_mode: REPEAT_MODE.DAILY, due_date: Date.now() + DAY,
        title: "晨会", description: "站会", project_id: 5, priority: 2,
        hex_color: "#FF0000", is_favorite: 1,
      }),
      Date.now(),
    )!;
    expect(plan.input.title).toBe("晨会");
    expect(plan.input.description).toBe("站会");
    expect(plan.input.project_id).toBe(5);
    expect(plan.input.priority).toBe(2);
    expect(plan.input.hex_color).toBe("#FF0000");
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
