// apps/desktop/src/features/todo/shared/repeat-task.ts
/**
 * 重复任务实例推进（07 报告 §五-P1#10）
 *
 * 语义：完成旧实例 → 以规则生成下一实例（替代旧的「重建 reminder」机制）。
 * due 序列始终锚定**原 due_date** 逐步推进（nextRepeatAt 内部快进越过 now），
 * 提前完成不改变节奏，长期逾期自动追赶到未来最近的序列点；
 * start/end 平移与 due 相同的 delta；子任务仅复制标题与顺序，完成态重置。
 * 不复制提醒（明确排除，见计划 Global Constraints）。
 */
import type { TodoSubtask, TodoTask, TodoTaskCreateInput } from "@/lib/tauri";
import { nextRepeatAt, REPEAT_MODE } from "./repeat";

export interface NextInstancePlan {
  input: TodoTaskCreateInput;
  /** 下一 due 与原 due 的差值(ms)，start/end 等派生时间用它对齐 */
  deltaMs: number;
}

/** 计算下一实例；无规则、无 due 或快进超限（>5000 步）返回 null */
export function planNextRecurringInstance(task: TodoTask, nowMs: number): NextInstancePlan | null {
  if (!task.repeat_mode || task.repeat_mode === REPEAT_MODE.NONE) return null;
  if (task.due_date == null) return null;
  const nextDue = nextRepeatAt(task.due_date, task.repeat_mode, task.repeat_after, nowMs);
  if (nextDue == null) return null;
  const deltaMs = nextDue - task.due_date;
  const shift = (ms: number | null): number | null => (ms == null ? null : ms + deltaMs);
  return {
    input: {
      title: task.title,
      description: task.description,
      project_id: task.project_id,
      priority: task.priority,
      status: "pending",
      done: 0,
      done_at: null,
      due_date: nextDue,
      start_date: shift(task.start_date),
      repeat_after: task.repeat_after,
      repeat_mode: task.repeat_mode,
      is_favorite: task.is_favorite,
    },
    deltaMs,
  };
}

/** 待克隆到新实例的子任务：过滤软删、position 升序、完成态不带走 */
export function subtasksToClone(subtasks: TodoSubtask[]): { title: string; position: number }[] {
  return subtasks
    .filter((s) => !s.is_deleted)
    .sort((a, b) => a.position - b.position)
    .map((s) => ({ title: s.title, position: s.position }));
}
