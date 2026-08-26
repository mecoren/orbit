/**
 * 任务重复规则（todo_tasks.repeat_after / repeat_mode 占位字段的语义约定）
 *
 * mode：0=不重复 1=按天 2=按周 3=按月 4=按年；after=间隔数（≥1）。
 * 调度在前端：提醒触发后（use-todo-reminder-listener）按规则计算下一次
 * 时间并删旧建新 todo_reminders 行，实现"重复提醒"。
 */
export const REPEAT_MODE = {
  NONE: 0,
  DAILY: 1,
  WEEKLY: 2,
  MONTHLY: 3,
  YEARLY: 4,
} as const;

/** 预设项（详情抽屉选择器用；自定义 N 天走 DAILY + after=N） */
export const REPEAT_PRESETS = [
  { mode: REPEAT_MODE.DAILY, after: 1, label: "每天" },
  { mode: REPEAT_MODE.WEEKLY, after: 1, label: "每周" },
  { mode: REPEAT_MODE.MONTHLY, after: 1, label: "每月" },
  { mode: REPEAT_MODE.YEARLY, after: 1, label: "每年" },
] as const;

/** 规则中文标签（徽标 / 属性行共用） */
export function repeatLabel(mode: number, after: number): string {
  const n = Math.max(1, after || 1);
  switch (mode) {
    case REPEAT_MODE.DAILY:
      return n === 1 ? "每天" : `每 ${n} 天`;
    case REPEAT_MODE.WEEKLY:
      return n === 1 ? "每周" : `每 ${n} 周`;
    case REPEAT_MODE.MONTHLY:
      return n === 1 ? "每月" : `每 ${n} 个月`;
    case REPEAT_MODE.YEARLY:
      return n === 1 ? "每年" : `每 ${n} 年`;
    default:
      return "不重复";
  }
}

/**
 * base 的下一次发生时间（> from）；无规则或快进超限返回 null。
 * 天/周为固定毫秒数；月/年走日历语义（日号超过目标月天数时截断到月末，
 * 如 1/31 → 2/28，避免 setMonth 溢出滚入下下月）。
 */
function advanceCalendarMonths(d: Date, months: number): void {
  const moved = new Date(
    d.getFullYear(),
    d.getMonth() + months,
    1,
    d.getHours(),
    d.getMinutes(),
    d.getSeconds(),
    d.getMilliseconds(),
  );
  const daysInTarget = new Date(moved.getFullYear(), moved.getMonth() + 1, 0).getDate();
  moved.setDate(Math.min(d.getDate(), daysInTarget));
  d.setTime(moved.getTime());
}

export function nextRepeatAt(
  baseMs: number,
  mode: number,
  after: number,
  fromMs: number,
): number | null {
  if (mode === REPEAT_MODE.NONE) return null;
  const step = Math.max(1, after || 1);
  const next = new Date(baseMs);
  // 逐步快进直到越过 from；上限 5000 步（按天约 13 年）防异常数据死循环
  for (let i = 0; i < 5000; i++) {
    switch (mode) {
      case REPEAT_MODE.DAILY:
        next.setDate(next.getDate() + step);
        break;
      case REPEAT_MODE.WEEKLY:
        next.setDate(next.getDate() + 7 * step);
        break;
      case REPEAT_MODE.MONTHLY:
        advanceCalendarMonths(next, step);
        break;
      case REPEAT_MODE.YEARLY:
        advanceCalendarMonths(next, 12 * step);
        break;
      default:
        return null;
    }
    if (next.getTime() > fromMs) return next.getTime();
  }
  return null;
}
