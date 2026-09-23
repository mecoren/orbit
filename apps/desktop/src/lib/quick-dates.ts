/**
 * 快捷日期/时间选项（参考滴答清单：今天/明天/下周、一小时后/今天晚些时候）
 *
 * 纯函数、无框架依赖；桌面 QuickDateMenu（表单 DatePicker/DateTimePicker、
 * 快捷新增、详情编辑）与移动端 WaitDatePickerSheet 共用同一计算口径，
 * 保证快捷新增 / 新增 / 修改各入口的快捷项文案与目标时间完全一致。
 */
import { format } from "date-fns";
import { zhCN } from "date-fns/locale";

export interface QuickDateOption {
  /** 稳定标识（today / tomorrow / nextWeek / in1h / tonight） */
  key: string;
  /** 主文案，如「明天」 */
  label: string;
  /** 右侧提示，如「周二」「22:00」「周三, 09:00」 */
  hint: string;
  /** 选项对应的目标时间 */
  value: Date;
}

/** 当日零点（本地时区） */
function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/** 当日指定时分 */
function at(d: Date, hour: number, minute = 0): Date {
  const x = startOfDay(d);
  x.setHours(hour, minute, 0, 0);
  return x;
}

/** 加 N 天（零点） */
function addDays(d: Date, n: number): Date {
  const x = startOfDay(d);
  x.setDate(x.getDate() + n);
  return x;
}

/** 下周一（今天为周一也取下周一） */
function nextMonday(now: Date, hour = 0, minute = 0): Date {
  const delta = ((8 - now.getDay()) % 7) || 7;
  return at(addDays(now, delta), hour, minute);
}

/** 周短文案：周二 */
const weekday = (d: Date) => format(d, "eee", { locale: zhCN });
/** HH:mm */
const hm = (d: Date) => format(d, "HH:mm");

/** 日期级快捷项：今天 / 明天 / 下周（下周一 00:00） */
export function buildQuickDateOptions(now: Date = new Date()): QuickDateOption[] {
  const tomorrow = addDays(now, 1);
  const nextMon = nextMonday(now);
  return [
    { key: "today", label: "今天", hint: weekday(now), value: startOfDay(now) },
    { key: "tomorrow", label: "明天", hint: weekday(tomorrow), value: tomorrow },
    { key: "nextWeek", label: "下周", hint: weekday(nextMon), value: nextMon },
  ];
}

/** 提醒「截止当天」锚定时刻：09:00（与移动端 `reminderPresetHour` 同口径） */
export const REMINDER_DUE_HOUR = 9;

const MINUTE_MS = 60_000;

/**
 * 「相对截止」提醒快捷项（对齐移动端 #53 口径）：截止当天 09:00 /
 * 截止前 1 小时 · 30 · 15 分钟。
 *
 * 仅在任务已有截止日期时可用——无截止时返回空数组（调用方不渲染该组；
 * 桌面无截止场景由 [buildQuickDateTimeOptions] 的一小时后/今晚/明天/下周覆盖，
 * 移动端对应档位为「今天/明天 09:00」，两端语义等价、选项集不同源）。
 *
 * 同刻去重（截止恰为 09:00 / 09:15 / 09:30 / 10:00 时会有重复目标）保留首个；
 * 已过期的档位**不过滤**——与日期面板允许选过去时刻同口径（用户可能要补记）。
 */
export function buildReminderDueOptions(
  dueMs: number | null | undefined,
): QuickDateOption[] {
  if (dueMs == null || !Number.isFinite(dueMs)) return [];
  const due = new Date(dueMs);
  const day9 = at(due, REMINDER_DUE_HOUR);
  const before = (minutes: number) => new Date(dueMs - minutes * MINUTE_MS);
  const raw: QuickDateOption[] = [
    {
      key: "dueDay9",
      label: `截止当天 ${String(REMINDER_DUE_HOUR).padStart(2, "0")}:00`,
      hint: hm(day9),
      value: day9,
    },
    { key: "dueBefore1h", label: "截止前 1 小时", hint: hm(before(60)), value: before(60) },
    { key: "dueBefore30m", label: "截止前 30 分钟", hint: hm(before(30)), value: before(30) },
    { key: "dueBefore15m", label: "截止前 15 分钟", hint: hm(before(15)), value: before(15) },
  ];
  const seen = new Set<number>();
  return raw.filter((o) => {
    const t = o.value.getTime();
    if (seen.has(t)) return false;
    seen.add(t);
    return true;
  });
}

/**
 * 日期时间级快捷项：一小时后 / 今天晚些时候(22:00) / 明天 09:00 / 下周(周一 09:00)。
 * 已过 22:00 时隐藏「今天晚些时候」，避免选中过去时间。
 */
export function buildQuickDateTimeOptions(now: Date = new Date()): QuickDateOption[] {
  const in1h = new Date(now.getTime() + 3_600_000);
  const tonight = at(now, 22);
  const tomorrow9 = at(addDays(now, 1), 9);
  const nextMon9 = nextMonday(now, 9);

  const options: QuickDateOption[] = [
    { key: "in1h", label: "一小时后", hint: hm(in1h), value: in1h },
  ];
  if (now.getTime() < tonight.getTime()) {
    options.push({ key: "tonight", label: "今天晚些时候", hint: "22:00", value: tonight });
  }
  options.push(
    { key: "tomorrow", label: "明天", hint: `${weekday(addDays(now, 1))}, 09:00`, value: tomorrow9 },
    { key: "nextWeek", label: "下周", hint: `${weekday(nextMon9)}, 09:00`, value: nextMon9 },
  );
  return options;
}
