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
} from "@/lib/quick-dates";

/** 各快捷项图标（缺省回退日历图标） */
const OPTION_ICONS: Record<string, LucideIcon> = {
  today: CalendarDays,
  tomorrow: CircleArrowRight,
  nextWeek: ChevronsRight,
  in1h: Clock,
  tonight: Clock,
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
}

export function QuickDateMenu({
  kind,
  value,
  onSelect,
  customLabel,
  onCustom,
}: QuickDateMenuProps) {
  const options = useMemo(
    () => (kind === "date" ? buildQuickDateOptions() : buildQuickDateTimeOptions()),
    [kind],
  );
  const CustomIcon = kind === "date" ? Calendar : CalendarClock;

  return (
    <div className="p-1">
      {options.map((opt) => {
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
      })}
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
