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

// 左右切换按钮的统一样式：绝对定位在 caption 容器内的左右两侧，
// 垂直居中（top-1/2 -translate-y-1/2），绝不会落到日期网格上。
const navButtonClass = cn(
  buttonVariants({ variant: "outline" }),
  "size-7 bg-transparent p-0 opacity-70 hover:opacity-100 absolute top-1/2 -translate-y-1/2 z-10"
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

// 自定义 caption：自带 relative 容器，prev/next 按钮作为其子元素绝对定位，
// 因此定位上下文明确为 caption 本身，不会再与下方日期重叠。
// 中间同时提供「月 / 年」下拉选择：月份用 shadcn Select（与影视媒体类型同款），
// 年份用可复用的虚拟滚动下拉 WaitVirtualizedSelect（同款动画/主题，但只渲染可视区年份）。
function CaptionWithNav({ calendarMonth, className, ...rest }: any) {
  const { goToMonth, previousMonth, nextMonth } = useDayPicker();
  const current = calendarMonth.date as Date;
  const year = current.getFullYear();
  const month = current.getMonth(); // 0-11

  const changeMonth = (m: number) => goToMonth(new Date(year, m, 1));
  const changeYear = (y: number) => goToMonth(new Date(y, month, 1));

  return (
    <div
      className={cn("relative flex items-center justify-center gap-1 pt-1", className)}
      {...rest}
    >
      <button
        type="button"
        aria-label="上个月"
        disabled={!previousMonth}
        onClick={() => previousMonth && goToMonth(previousMonth)}
        className={cn(navButtonClass, "left-1")}
      >
        <ChevronLeft className="size-4" />
      </button>
      <div className="flex items-center gap-1 px-9">
        <Select
          value={String(month)}
          onValueChange={(v) => changeMonth(Number(v))}
        >
          <SelectTrigger size="sm" className="w-[72px]" aria-label="选择月份">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>{monthItems}</SelectContent>
        </Select>
        <WaitVirtualizedSelect
          value={String(year)}
          onValueChange={(v) => changeYear(Number(v))}
          options={yearSelectOptions}
          size="sm"
          className="w-[112px]"
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
        className={cn(navButtonClass, "right-1")}
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
        months: "flex flex-col sm:flex-row gap-5",
        month: "flex flex-col gap-4.5",
        month_caption: "flex justify-center pt-1 relative items-center w-full",
        caption_label: "text-[15px] font-medium px-9",
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
