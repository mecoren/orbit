/**
 * 任务重复规则（todo_tasks.repeat_after / repeat_mode 字段的语义约定）
 *
 * mode：0=不重复 1=按天 2=按周 3=按月 4=按年；after=间隔数（≥1）。
 * nextRepeatAt 同时服务两处调度：重复任务真引擎（task-actions.completeTask
 * 完成时推进下一实例，07 报告 P1#10）与重复提醒续排
 * （use-todo-reminder-listener，仅对未完成实例生效）。
 */
export const REPEAT_MODE = {
  NONE: 0,
  DAILY: 1,
  WEEKLY: 2,
  MONTHLY: 3,
  YEARLY: 4,
} as const;

/** 月重复模式（与 Rust REPEAT_MONTH_* 对齐；仅 MONTHLY 生效） */
export const REPEAT_MONTH_MODE = {
  DAY: 0,
  NTH: 1,
} as const;

/** repeat_nth_week 取值：1-5=第 N 个，6=最后一个，0=未指定 */
export const REPEAT_NTH_LAST = 6;

/** 序数中文（1-5 + 末） */
const NTH_WEEK_LABEL: Record<number, string> = {
  1: "第 1 个",
  2: "第 2 个",
  3: "第 3 个",
  4: "第 4 个",
  5: "第 5 个",
  [REPEAT_NTH_LAST]: "最后一个",
};

/** 预设项（详情抽屉选择器用；自定义 N 天走 DAILY + after=N） */
export const REPEAT_PRESETS = [
  { mode: REPEAT_MODE.DAILY, after: 1, label: "每天" },
  { mode: REPEAT_MODE.WEEKLY, after: 1, label: "每周" },
  { mode: REPEAT_MODE.MONTHLY, after: 1, label: "每月" },
  { mode: REPEAT_MODE.YEARLY, after: 1, label: "每年" },
] as const;

/** 星期几位掩码 chips（bit0=周一 … bit6=周日；与 Rust weekday_bit 对齐） */
export const WEEKDAY_CHIPS = [
  { bit: 1, label: "一" },
  { bit: 2, label: "二" },
  { bit: 4, label: "三" },
  { bit: 8, label: "四" },
  { bit: 16, label: "五" },
  { bit: 32, label: "六" },
  { bit: 64, label: "日" },
] as const;

/** 星期几位掩码 → 「周一三五」式短标签 */
export function weekdayMaskLabel(mask: number): string {
  if (mask === 0) return "";
  const names = ["一", "二", "三", "四", "五", "六", "日"];
  const parts: string[] = [];
  for (let i = 0; i < 7; i++) {
    if ((mask & (1 << i)) !== 0) parts.push(names[i]);
  }
  return parts.join("");
}

/** 掩码最低位对应的星期（周一=0 … 周日=6；0 掩码返回 null） */
export function firstWeekdayInMask(mask: number): number | null {
  for (let b = 0; b < 7; b++) {
    if ((mask & (1 << b)) !== 0) return b;
  }
  return null;
}

/** 序数标签（nth=6 → "最后一个"，其余 "第 N 个"；非法返回 null） */
export function nthWeekLabel(nth: number): string | null {
  return NTH_WEEK_LABEL[nth] ?? null;
}

/** 规则中文标签（徽标 / 属性行共用；#34 扩展字段可选，#72 加月高级语义） */
export function repeatLabel(
  mode: number,
  after: number,
  ext?: {
    weekdays?: number;
    endType?: number;
    endParam?: number;
    fromDone?: number;
    monthMode?: number;
    nthWeek?: number;
  },
): string {
  const n = Math.max(1, after || 1);
  let base: string;
  switch (mode) {
    case REPEAT_MODE.DAILY:
      base = n === 1 ? "每天" : `每 ${n} 天`;
      break;
    case REPEAT_MODE.WEEKLY: {
      const wd = ext?.weekdays ?? 0;
      if (wd !== 0) {
        base = n === 1 ? `每周${weekdayMaskLabel(wd)}` : `每 ${n} 周${weekdayMaskLabel(wd)}`;
      } else {
        base = n === 1 ? "每周" : `每 ${n} 周`;
      }
      break;
    }
    case REPEAT_MODE.MONTHLY: {
      // 月高级语义：每月第 N 个星期 X（掩码取最低位，UI 层限制单选）
      const nthLabel =
        ext?.monthMode === REPEAT_MONTH_MODE.NTH
          ? nthWeekLabel(ext?.nthWeek ?? 0)
          : null;
      const wd = nthLabel != null ? firstWeekdayInMask(ext?.weekdays ?? 0) : null;
      if (nthLabel != null && wd != null) {
        const wdName = ["一", "二", "三", "四", "五", "六", "日"][wd];
        base = n === 1 ? `每月${nthLabel}周${wdName}` : `每 ${n} 个月${nthLabel}周${wdName}`;
      } else {
        base = n === 1 ? "每月" : `每 ${n} 个月`;
      }
      break;
    }
    case REPEAT_MODE.YEARLY:
      base = n === 1 ? "每年" : `每 ${n} 年`;
      break;
    default:
      return "不重复";
  }
  const suffix: string[] = [];
  if (ext?.fromDone) suffix.push("按完成日");
  if (ext?.endType === 2 && ext.endParam && ext.endParam > 0) suffix.push(`剩 ${ext.endParam} 次`);
  if (ext?.endType === 1 && ext.endParam) suffix.push(`至 ${new Date(ext.endParam).toLocaleDateString()}`);
  return suffix.length > 0 ? `${base}（${suffix.join("，")}）` : base;
}

/**
 * 「下次：M月d日（周X）」预览标签（表单 RepeatField / 详情 RepeatEditor 共用，
 * 对齐 Things 3 配规则即见具体日期的口径——用户配完规则即可见下次到底哪天）。
 * 锚点语义与完成引擎一致：fromDone=0 按原 due 锚点推进（节奏恒定，提前
 * 完成不改变节奏）；fromDone=1 按完成时刻推进（下一实例 = 完成后一个完整
 * 周期）。无规则 / 无锚点日期 / 快进超限返回 null（调用方不渲染徽标）。
 */
export function nextRepeatLabel(
  mode: number,
  after: number,
  anchorMs: number | null,
  fromMs: number,
  fromDone?: number,
  ext?: { weekdays?: number; monthMode?: number; nthWeek?: number },
): string | null {
  if (mode === REPEAT_MODE.NONE || anchorMs == null) return null;
  // 月高级语义：nth 步进预览（与 Rust next_monthly_nth_from 同口径；
  // 非法配置回落日号语义，见下）
  if (mode === REPEAT_MODE.MONTHLY && ext?.monthMode === REPEAT_MONTH_MODE.NTH) {
    const wd = firstWeekdayInMask(ext.weekdays ?? 0);
    const nth = ext.nthWeek ?? 0;
    if (wd != null && nthWeekLabel(nth) != null) {
      const base = !fromDone ? anchorMs : Math.max(anchorMs, fromMs);
      const from = !fromDone ? Math.max(anchorMs, fromMs) : fromMs;
      const next = nextMonthlyNth(base, after, wd, nth, from);
      return next == null ? null : formatCnDate(next);
    }
  }
  // 节奏档：从 due 锚点快进到 now 之后（与完成引擎同一 nextRepeatAt 调用形态）
  if (!fromDone) {
    const next = nextRepeatAt(anchorMs, mode, after, Math.max(anchorMs, fromMs));
    return next == null ? null : formatCnDate(next);
  }
  // 按完成日档：锚点抬到当前时刻（>= now），下一实例 = 完成后一个完整周期
  const next = nextRepeatAt(Math.max(anchorMs, fromMs), mode, after, fromMs);
  return next == null ? null : formatCnDate(next);
}

/** 毫秒时间戳 →「M月d日（周X）」中文短日期（完成提示条幅复用，与移动端 formatCnDate 同口径） */
export function formatCnDate(ms: number): string {
  const d = new Date(ms);
  const wd = "一二三四五六日"[d.getDay() === 0 ? 6 : d.getDay() - 1];
  return `${d.getMonth() + 1}月${d.getDate()}日（周${wd}）`;
}

/**
 * base 的下一次发生时间（> from）；无规则或快进超限返回 null。
 * 天/周为固定毫秒数；月/年走日历语义（日号超过目标月天数时截断到月末，
 * 如 1/31 → 2/28，避免 setMonth 溢出滚入下下月）。
 * 语义注记（评审 M3）：截断后锚点随链式推进永久退化为短月日号——
 * 1/31 → 2/28 → 3/28；长期逾期快进同理落在当期截断值。
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

/**
 * 某年月第 N 个星期 X 是几号（Rust nth_weekday_in_month 的 TS 镜像；
 * month0 = JS 月份 0 基；nth 6=最后一个；无 occurrence 返回 null）。
 */
export function nthWeekdayInMonth(
  year: number,
  month0: number,
  nth: number,
  weekdayMon0: number,
): number | null {
  const firstWd = (new Date(year, month0, 1).getDay() + 6) % 7; // 周一=0
  const first = 1 + (((weekdayMon0 - firstWd) % 7) + 7) % 7;
  const lastDay = new Date(year, month0 + 1, 0).getDate();
  if (nth === REPEAT_NTH_LAST) {
    const lastWd = (new Date(year, month0, lastDay).getDay() + 6) % 7;
    return lastDay - (((lastWd - weekdayMon0) % 7) + 7) % 7;
  }
  if (nth < 1 || nth > 5) return null;
  const day = first + 7 * (nth - 1);
  return day <= lastDay ? day : null;
}

/**
 * 每月第 N 个星期 X 步进（Rust next_monthly_nth_from 的 TS 镜像，
 * 供 nextRepeatLabel 预览用；调度真值在 core）。
 *
 * 口径：锚定 anchor 所在月，按 after 步长逐月取首个 > from 的 occurrence
 * （k 从 1 起：anchor 当月属当前周期）；无 occurrence 的月份跳过；
 * 时刻沿用 anchor 本地时刻。DST 不存在时刻 JS Date 自动顺延（预览级误差，
 * Rust 侧跳过该月——国内无夏令时，无实际分歧）。
 */
export function nextMonthlyNth(
  anchorMs: number,
  after: number,
  weekdayMon0: number,
  nth: number,
  fromMs: number,
): number | null {
  const anchor = new Date(anchorMs);
  const step = Math.max(1, after || 1);
  const h = anchor.getHours();
  const mi = anchor.getMinutes();
  const s = anchor.getSeconds();
  const ms = anchor.getMilliseconds();
  for (let k = 1; k <= 5000; k++) {
    const total = anchor.getFullYear() * 12 + anchor.getMonth() + k * step;
    const ty = Math.floor(total / 12);
    const tm = ((total % 12) + 12) % 12;
    const day = nthWeekdayInMonth(ty, tm, nth, weekdayMon0);
    if (day == null) continue;
    const cand = new Date(ty, tm, day, h, mi, s, ms).getTime();
    if (cand > fromMs) return cand;
  }
  return null;
}
