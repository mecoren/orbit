/**
 * calendar-date-field — 日历视图的日期口径（纯函数）
 *
 * 日历格子与右栏列表按任务的哪个日期排布：
 * - `due`   = 截止日期（历史默认，月/周/年/议程一律按它分桶）；
 * - `start` = 开始日期（排期视角，适合按「什么时候动手」看排期）。
 *
 * 两个口径都以**本地日界**分桶（dayKey），与任务列表的日期语义同源；
 * 该口径缺失的任务在此口径下**不回落**另一字段——回落会让「开始」与
 * 「截止」两种语义在同一格子里混排，用户无法判断拖拽改的是哪个字段。
 */

import type { TodoTaskListItem } from "@/lib/tauri";

export type CalendarDateField = "due" | "start";

/** 持久化值解析：只认 `"start"`，其余（含脏值）一律回落历史默认 `"due"` */
export function parseCalendarDateField(raw: string | null): CalendarDateField {
  return raw === "start" ? "start" : "due";
}

/** 口径展示文案（右栏标题提示 / 空态 / 拖拽 toast 共用单一出口） */
export function calendarDateFieldLabel(field: CalendarDateField): string {
  return field === "start" ? "开始日期" : "截止日期";
}

/** 任务在该口径下的日期毫秒；缺失 = null（不参与分桶，也不进右栏列表） */
export function calendarTaskDateMs(
  task: Pick<TodoTaskListItem, "due_date" | "start_date">,
  field: CalendarDateField,
): number | null {
  return field === "start" ? task.start_date : task.due_date;
}

/** 两个毫秒时间戳是否落在同一本地日 */
function isSameLocalDay(a: number, b: number): boolean {
  const da = new Date(a);
  const db = new Date(b);
  return (
    da.getFullYear() === db.getFullYear() &&
    da.getMonth() === db.getMonth() &&
    da.getDate() === db.getDate()
  );
}

/**
 * 拖到另一格 = 修改任务开始日期；同日返回 null（无变化，不写库）。
 *
 * `start_date` 惯例存本地零点，但时间轴排程可带精确时刻——故**保留原时分秒**
 * （零点仍零点）。不能复用 [rescheduleDue]：它把零点原值升级成 18:00，
 * 那是截止日期的口径，套到开始日期上会让「仅日期」的排期平白多出时刻。
 * 无原值时兜底目标日零点（开始日期是日期级字段的第一性语义）。
 */
export function rescheduleStartDate(original: number | null, targetDay: Date): number | null {
  const target = new Date(
    targetDay.getFullYear(),
    targetDay.getMonth(),
    targetDay.getDate(),
  );
  if (original == null) return target.getTime();
  if (isSameLocalDay(original, target.getTime())) return null;
  const orig = new Date(original);
  const next = new Date(target);
  next.setHours(orig.getHours(), orig.getMinutes(), orig.getSeconds(), orig.getMilliseconds());
  return next.getTime();
}
