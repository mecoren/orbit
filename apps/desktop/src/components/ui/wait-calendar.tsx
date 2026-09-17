import * as React from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { DayPicker, useDayPicker } from "react-day-picker";
import { zhCN } from "date-fns/locale";

import { cn } from "@/lib/utils";
import { buttonVariants } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { WaitVirtualizedSelect } from "@/components/ui/wait-virtualized-select";

export type WaitCalendarProps = React.ComponentProps<typeof DayPicker>;

// 左右切换按钮的统一样式：随 caption 行流式排布（shrink-0 不被下拉挤压）。
// 旧实现用 absolute left-1/right-1 定位、中间靠 px-9 让位，其固定内容宽
// （36+72+4+112+36=260px）超出 w-72 弹层内的可用宽（弹层 p-3 12 + 日历 p-3.5 14
// = 26px，仅剩 236px）→ 居中溢出后两侧翻月钮压到月/年下拉上（2026-09-17 详情
// 抽屉截图：左钮压住「9月」、右钮被弹层右边裁切）。改为纯 flex 行后任意容器宽度自适应。
const navButtonClass = cn(
  buttonVariants({ variant: "outline" }),
  "size-7 shrink-0 bg-transparent p-0 opacity-70 hover:opacity-100"
);

// 月 / 年选项列表：1900–2100 共 201 个年份，纯静态。提到模块级只构造一次，
// 并作为固定 React 元素复用，使日历因 hover/翻月频繁重渲染时，201 个
// SelectItem 可被 React 跳过重建（元素引用稳定 → bailout），显著降低重渲染开销。
const MONTH_OPTIONS = Array.from({ length: 12 }, (_, m) => m);
const YEAR_MIN = 1900;
const YEAR_MAX = 2100;
const YEAR_OPTIONS = Array.from(
  { length: YEAR_MAX - YEAR_MIN + 1 },
  (_, i) => YEAR_MIN + i,
);
const monthItems = MONTH_OPTIONS.map((m) => (
  <SelectItem key={m} value={String(m)}>
    {m + 1}月
  </SelectItem>
));

// 年份下拉选项（纯对象，非 React 元素）：与 YEAR_OPTIONS 一起提到模块级只构造一次，
// 日历频繁重渲染时无需重建 201 个对象；真正的 DOM 节点数由 WaitVirtualizedSelect 的
// 虚拟滚动控制在可视窗口内（约 16 个）。
const yearSelectOptions = YEAR_OPTIONS.map((y) => ({
  value: String(y),
  label: `${y}年`,
}));

// 自定义 caption：单行四段流式布局「‹ 月 年 ›」，靠 justify-between 让翻月钮贴两侧、
// 月/年下拉居中；两端钮 shrink-0，年份下拉 min-w-0 可收缩，故容器窄到 236px 也不溢出。
// 中间同时提供「月 / 年」下拉选择：月份用 shadcn Select（与影视媒体类型同款），
// 年份用可复用的虚拟滚动下拉 WaitVirtualizedSelect（同款动画/主题，但只渲染可视区年份）。
// 两个下拉收窄左右内边距（px-2）以给年月文本留足空间（sm 档默认 px-3）。
function CaptionWithNav({ calendarMonth, className, displayIndex: _drop, ...rest }: any) {
  void _drop; // day-picker 内部 prop（周序号），不落 DOM：透传会触发 React 未知 prop 警告
  const { goToMonth, previousMonth, nextMonth } = useDayPicker();
  const current = calendarMonth.date as Date;
  const year = current.getFullYear();
  const month = current.getMonth(); // 0-11

  const changeMonth = (m: number) => goToMonth(new Date(year, m, 1));
  const changeYear = (y: number) => goToMonth(new Date(y, month, 1));

  return (
    <div
      className={cn("flex items-center justify-between gap-1 pt-1", className)}
      {...rest}
    >
      <button
        type="button"
        aria-label="上个月"
        disabled={!previousMonth}
        onClick={() => previousMonth && goToMonth(previousMonth)}
        className={navButtonClass}
      >
        <ChevronLeft className="size-4" />
      </button>
      <div className="flex min-w-0 items-center gap-1">
        <Select
          value={String(month)}
          onValueChange={(v) => changeMonth(Number(v))}
        >
          <SelectTrigger
            size="sm"
            className="w-16 shrink-0 px-2"
            aria-label="选择月份"
          >
            <SelectValue />
          </SelectTrigger>
          <SelectContent>{monthItems}</SelectContent>
        </Select>
        <WaitVirtualizedSelect
          value={String(year)}
          onValueChange={(v) => changeYear(Number(v))}
          options={yearSelectOptions}
          size="sm"
          className="w-[100px] min-w-0 px-2"
          contentWidth={128}
          viewportHeight={256}
          ariaLabel="选择年份"
        />
      </div>
      <button
        type="button"
        aria-label="下个月"
        disabled={!nextMonth}
        onClick={() => nextMonth && goToMonth(nextMonth)}
        className={navButtonClass}
      >
        <ChevronRight className="size-4" />
      </button>
    </div>
  );
}

export function WaitCalendar({
  className,
  classNames,
  showOutsideDays = true,
  ...props
}: WaitCalendarProps) {
  return (
    <DayPicker
      locale={zhCN}
      weekStartsOn={1}
      showOutsideDays={showOutsideDays}
      hideNavigation
      className={cn("p-3.5", className)}
      classNames={{
        // 单月固定纵排：全仓库调用方均为单月；sm:flex-row 会让 month 变成
        // 内容撑宽的 flex item（caption 月 72 + 年 112 + px-9 共 260px），
        // 在 w-72 日期弹层里把日期网格向右顶出边界（左 26px / 右溢出）。
        // 若将来有多月并排需求，调用方用 classNames.months 覆写即可。
        months: "flex flex-col gap-5",
        month: "flex flex-col gap-4.5",
        // 只留定位/宽度：flex 行与对齐由 CaptionWithNav 自管（避免并存的
        // justify-center 与 justify-between 靠类名顺序决胜负）
        month_caption: "relative w-full",
        month_grid: "w-full border-collapse table-fixed",
        weekdays: "w-full",
        weekday:
          "text-muted-foreground rounded-md font-normal text-[13px] py-1.5 text-center",
        week: "w-full mt-2.5",
        day: cn(
          "relative p-0 text-center text-[15px] align-middle focus-within:relative focus-within:z-20",
          "[&:has([aria-selected])]:bg-accent first:[&:has([aria-selected])]:rounded-l-md last:[&:has([aria-selected])]:rounded-r-md"
        ),
        day_button: cn(
          buttonVariants({ variant: "ghost" }),
          "w-full aspect-square p-0 font-normal aria-selected:opacity-100"
        ),
        range_start: "day-range-start",
        range_end: "day-range-end",
        selected:
          "bg-primary text-primary-foreground hover:bg-primary hover:text-primary-foreground focus:bg-primary focus:text-primary-foreground rounded-md",
        today: "bg-accent text-accent-foreground rounded-md",
        outside:
          "day-outside text-muted-foreground aria-selected:bg-accent/50 aria-selected:text-muted-foreground",
        disabled: "text-muted-foreground opacity-50",
        range_middle:
          "aria-selected:bg-accent aria-selected:text-accent-foreground",
        hidden: "invisible",
        ...classNames,
      }}
      components={{
        MonthCaption: CaptionWithNav,
        Chevron: ({ orientation, ...rest }) =>
          orientation === "left" ? (
            <ChevronLeft className="size-4" {...rest} />
          ) : (
            <ChevronRight className="size-4" {...rest} />
          ),
      }}
      {...props}
    />
  );
}
