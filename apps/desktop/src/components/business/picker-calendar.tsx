/**
 * 选择器月历（日期选择弹层专用，与日历视图同一套日格视觉）
 *
 * 复用日历视图的 `MonthCalendar`（md 档）渲染日格口径：农历/节日/节气副标签、
 * 休/班徽标、周末蓝字、今天实心块、选中 1.5px 描边；节假日与日历视图共用
 * 同一份 `useHolidayMarks`（queryKey `["holidays","list"]`）缓存。
 *
 * 与日历视图的差异仅在头部：弹层里要做远距离跳月/跳年，所以是
 * 「‹ 月下拉 年虚拟下拉 ›」单行（年份 1900–2100 走虚拟滚动），不渲染
 * 月历大字标题与内置翻月钮（`showHeader={false}`，年月由本组件受控驱动）。
 */
import { useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";

import { cn } from "@/lib/utils";
import { MonthCalendar } from "@/components/business/month-calendar";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { WaitVirtualizedSelect } from "@/components/ui/wait-virtualized-select";
import { daySubLabel } from "@/features/todo/shared/almanac";
import { useHolidayMarks } from "@/features/todo/shared/use-holiday-marks";

// 静态列表提到模块级只构造一次：弹层内 hover/翻月频繁重渲染时，
// 201 个年份选项对象与 12 个月份元素引用稳定，React 可直接 bailout。
const MONTH_OPTIONS = Array.from({ length: 12 }, (_, m) => m);
const YEAR_MIN = 1900;
const YEAR_MAX = 2100;
const monthItems = MONTH_OPTIONS.map((m) => (
  <SelectItem key={m} value={String(m)}>
    {m + 1}月
  </SelectItem>
));
const yearSelectOptions = Array.from(
  { length: YEAR_MAX - YEAR_MIN + 1 },
  (_, i) => YEAR_MIN + i,
).map((y) => ({ value: String(y), label: `${y}年` }));

const navButtonClass =
  "size-7 shrink-0 bg-transparent p-0 opacity-70 hover:opacity-100";

export interface PickerCalendarProps {
  selected?: Date;
  onSelect?: (date: Date) => void;
  className?: string;
}

export function PickerCalendar({
  selected,
  onSelect,
  className,
}: PickerCalendarProps) {
  // 初始展示月：优先已选日期，其次今天（不随外部值变化重定位——与
  // react-day-picker 的 defaultMonth 语义一致，避免打开后又被弹回）
  const [view, setView] = useState(() => {
    const base = selected ?? new Date();
    return { year: base.getFullYear(), month: base.getMonth() };
  });
  const { year, month } = view;

  const holidayMarks = useHolidayMarks();

  const goPrev = () =>
    setView(month === 0 ? { year: year - 1, month: 11 } : { year, month: month - 1 });
  const goNext = () =>
    setView(month === 11 ? { year: year + 1, month: 0 } : { year, month: month + 1 });

  return (
    // 宽度 368 ≈ 7 格 × 49px + 6 × 4px 间距：日格副标签可用宽约 41px，
    // 恰好容下 4 字节日名（「抗战胜利」「烈士纪念日」不截断成省略号）
    <div className={cn("flex w-[368px] flex-col gap-2", className)}>
      <div className="flex items-center justify-between gap-1">
        <Button
          variant="outline"
          size="icon"
          className={navButtonClass}
          onClick={goPrev}
          aria-label="上个月"
        >
          <ChevronLeft className="size-4" />
        </Button>
        <div className="flex min-w-0 items-center gap-1">
          <Select
            value={String(month)}
            onValueChange={(v) => setView({ year, month: Number(v) })}
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
            onValueChange={(v) => setView({ year: Number(v), month })}
            options={yearSelectOptions}
            size="sm"
            className="w-[100px] min-w-0 px-2"
            contentWidth={128}
            viewportHeight={256}
            ariaLabel="选择年份"
          />
        </div>
        <Button
          variant="outline"
          size="icon"
          className={navButtonClass}
          onClick={goNext}
          aria-label="下个月"
        >
          <ChevronRight className="size-4" />
        </Button>
      </div>

      <MonthCalendar
        size="md"
        showHeader={false}
        year={year}
        month={month}
        onMonthChange={(y, m) => setView({ year: y, month: m })}
        selected={selected}
        onDayClick={onSelect}
        holidays={holidayMarks}
        subLabel={daySubLabel}
      />
    </div>
  );
}
