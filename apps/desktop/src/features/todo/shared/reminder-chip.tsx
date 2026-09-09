/**
 * ReminderChip —— 行内提醒徽标（列表行/看板卡/日历任务行共用）
 *
 * 无提醒数据的行不渲染（调用方传 null）。展示口径见 reminder-meta：
 * - 未来：Bell + HH:mm（muted，与其他元信息同色）；
 * - 已到期且任务未完成：BellRing + 红色警示（与逾期截止同色系
 *   OVERDUE_COLOR_CLASS——「响过没处理」与「逾期」同为需要用户注意的态）。
 */
import { Bell, BellRing } from "lucide-react";

import { cn } from "@/lib/utils";

import { OVERDUE_COLOR_CLASS } from "./constants";
import type { DisplayReminder } from "./reminder-meta";

export function ReminderChip({ reminder }: { reminder: DisplayReminder | null }) {
  if (!reminder) return null;
  const Icon = reminder.fired ? BellRing : Bell;
  return (
    <span
      data-testid="reminder-chip"
      data-fired={reminder.fired ? "true" : "false"}
      className={cn(
        "inline-flex shrink-0 items-center gap-0.5 tabular-nums",
        reminder.fired && OVERDUE_COLOR_CLASS,
      )}
      title={reminder.fired ? `提醒已到期（${reminder.clock}）` : `提醒 ${reminder.clock}`}
    >
      <Icon size={11} className={cn(reminder.fired && "animate-pulse")} />
      {reminder.clock}
    </span>
  );
}
