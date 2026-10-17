/**
 * rollover-overdue — 逾期一键顺延的计划层（纯函数，G1 温和处置）
 *
 * 逾期任务堆叠后只能逐条改期是品类普遍痛点（对标分析 G1：顺延语义缺失）。
 * 本模块只做「算计划」：从任务集里挑出逾期未完成的行，给出各自的顺延目标
 * 截止值。写库与撤销由 batch-actions 的 rolloverOverdueTasks 消费本计划。
 *
 * 时间语义与 rescheduleDue 完全同口径（保时刻 / 零点归 18:00），目标日为
 * 本地日历日（跨月/年按日历推进，非固定 24h）。
 */
import { rescheduleDue } from "./reschedule-due";
import type { TodoTaskListItem } from "@/lib/tauri";

/** 顺延落点档：今天 / 明天 */
export type RolloverPreset = "today" | "tomorrow";

/** 顺延计划条目：该行改期到 next（null 表示无变化不该写库，已在外层过滤） */
export interface RolloverPlan {
  task: TodoTaskListItem;
  next: number;
}

/** 目标日（本地零点 Date）：today=当天，tomorrow=次日（日历日推进） */
export function rolloverTargetDay(preset: RolloverPreset, now = new Date()): Date {
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return preset === "today" ? day : new Date(day.getTime() + 86_400_000);
}

/**
 * 计算顺延计划：只挑「逾期且未完成」（due < now 且 !done）的行；
 * 每行目标截止 = rescheduleDue(原 due, 目标日)，无变化（同日）丢弃。
 */
export function planRollover(
  tasks: TodoTaskListItem[],
  preset: RolloverPreset,
  now = Date.now(),
): RolloverPlan[] {
  const target = rolloverTargetDay(preset, new Date(now));
  const plan: RolloverPlan[] = [];
  for (const t of tasks) {
    if (t.done || t.due_date == null || t.due_date >= now) continue;
    const next = rescheduleDue(t.due_date, target);
    if (next == null) continue;
    plan.push({ task: t, next });
  }
  return plan;
}
