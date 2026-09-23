/**
 * QuickDateMenu — 日期/日期时间快捷选项列表（交互参考滴答清单）
 *
 * 选项文案与目标时间统一由 lib/quick-dates 计算；桌面各入口
 * （表单 DatePicker/DateTimePicker、快捷新增、详情编辑器）共用本组件，
 * 保证快捷项口径一致。尾部「选择日期(和时间)」行由调用方切换到完整日历视图。
 */
import { useMemo } from "react";
import { format } from "date-fns";
import {
  Bell,
  Calendar,
  CalendarClock,
  CalendarDays,
  ChevronsRight,
  CircleArrowRight,
  Clock,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";
import {
  buildQuickDateOptions,
  buildQuickDateTimeOptions,
  buildReminderDueOptions,
  type QuickDateOption,
} from "@/lib/quick-dates";

/** 各快捷项图标（缺省回退日历图标） */
const OPTION_ICONS: Record<string, LucideIcon> = {
  today: CalendarDays,
  tomorrow: CircleArrowRight,
  nextWeek: ChevronsRight,
  in1h: Clock,
  tonight: Clock,
  // 「相对截止」提醒档（铃铛，与行内提醒徽标同语义）
  dueDay9: Bell,
  dueBefore1h: Bell,
  dueBefore30m: Bell,
  dueBefore15m: Bell,
};

interface QuickDateMenuProps {
  /** date=日期级（今天/明天/下周）；datetime=含时间（一小时后/今晚/明天/下周） */
  kind: "date" | "datetime";
  /** 当前值（date: YYYY-MM-DD；datetime: YYYY-MM-DDTHH:MM），用于选中高亮 */
  value?: string;
  /** 点选快捷项（选中即确认，由调用方回写并关闭弹层） */
  onSelect: (d: Date) => void;
  /** 尾部自定义入口文案，如「选择日期」 */
  customLabel: string;
  /** 点选自定义入口（调用方切换到完整日历视图） */
  onCustom: () => void;
  /**
   * 任务截止日期（ms）：datetime 档据此前置一组「相对截止」提醒档
   * （截止当天 09:00 / 前推 1 小时·30·15 分钟，对齐移动端 #53 口径）。
   * 缺省或 null 时该组不渲染——非提醒场景（截止日期选择器）不要传。
   */
  dueDateMs?: number | null;
}

export function QuickDateMenu({
  kind,
  value,
  onSelect,
  customLabel,
  onCustom,
  dueDateMs,
}: QuickDateMenuProps) {
  const options = useMemo(
    () => (kind === "date" ? buildQuickDateOptions() : buildQuickDateTimeOptions()),
    [kind],
  );
  // 「相对截止」组：仅 datetime 且给了截止日期时出现
  const dueOptions = useMemo(
    () => (kind === "datetime" ? buildReminderDueOptions(dueDateMs) : []),
    [kind, dueDateMs],
  );
  const CustomIcon = kind === "date" ? Calendar : CalendarClock;

  const renderOption = (opt: QuickDateOption) => {
    const Icon = OPTION_ICONS[opt.key] ?? Calendar;
    const optValue =
      kind === "date"
        ? format(opt.value, "yyyy-MM-dd")
        : format(opt.value, "yyyy-MM-dd'T'HH:mm");
    const active = (value ?? "") === optValue;
    return (
      <button
        key={opt.key}
        type="button"
        onClick={() => onSelect(opt.value)}
        className={cn(
          "flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-sm outline-none hover:bg-accent focus-visible:bg-accent",
          active && "bg-accent font-medium",
        )}
      >
        <Icon className="size-4 shrink-0 text-muted-foreground" />
        <span className="flex-1 text-left">{opt.label}</span>
        <span className="text-xs text-muted-foreground">{opt.hint}</span>
      </button>
    );
  };

  return (
    <div className="p-1">
      {dueOptions.length > 0 && (
        <>
          <p className="px-2 pb-0.5 pt-1 text-[11px] font-medium text-muted-foreground">
            相对截止
          </p>
          {dueOptions.map(renderOption)}
          <div className="my-1 border-t" />
        </>
      )}
      {options.map(renderOption)}
      <div className="my-1 border-t" />
      <button
        type="button"
        onClick={onCustom}
        className="flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-sm outline-none hover:bg-accent focus-visible:bg-accent"
      >
        <CustomIcon className="size-4 shrink-0 text-muted-foreground" />
        <span className="flex-1 text-left">{customLabel}</span>
      </button>
    </div>
  );
}
