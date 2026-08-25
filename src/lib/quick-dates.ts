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
