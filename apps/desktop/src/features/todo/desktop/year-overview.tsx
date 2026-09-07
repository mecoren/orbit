/**
 * 年视图内联面板（Days Matter 风格）
 *
 * 移植自 wait-home apps/desktop/src/modules/important-date/year-overview.tsx，
 * 适配 orbit 待办日历：
 * - 12 个迷你月历铺满左半区（3 列 × 4 行），行高等分容器、任意窗口不挤压
 * - 头部：大年份（点击返回月视图）+ 干支生肖标签 + 春节/初一下划线图例 + 切年箭头
 * - 标记口径：今天 = 主色实心胶囊 + 白字；春节（正月初一）红下划线；每月初一蓝下划线
 * - 点击任意日期回到月视图并定位该日
 */
import { useMemo } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { lunarYearLabel, solarToLunar } from "@/features/todo/shared/almanac";
import { formatYmd } from "@/features/todo/shared/lunar";

const WEEKDAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"];
const TODAY_BG = "#4C7DF0";
const MIN_YEAR = 1901;
const MAX_YEAR = 2100;

export interface YearOverviewPanelProps {
  year: number;
  /** 左上角年份点击：回到月视图 */
  onBack: () => void;
  /** 点击任意日期：回到月视图并定位该日 */
  onSelect: (date: Date) => void;
  /** 点击迷你月标题：回月视图定位该月 1 号 */
  onPickMonth?: (month: number) => void;
  onYearChange: (year: number) => void;
  className?: string;
}

export function YearOverviewPanel({
  year,
  onBack,
  onSelect,
  onPickMonth,
  onYearChange,
  className,
}: YearOverviewPanelProps) {
  const goPrevYear = () => {
    if (year > MIN_YEAR) onYearChange(year - 1);
  };
  const goNextYear = () => {
    if (year < MAX_YEAR) onYearChange(year + 1);
  };

  return (
    <div className={cn("flex h-full min-h-0 flex-col", className)}>
      {/* 头部：大年份（点击返回月视图）+ 干支/图例 + 切年（与月历头部同节奏） */}
      <div className="mb-1 flex items-center gap-2">
        <span
          className="text-3xl font-extrabold leading-none tracking-tight"
          role="button"
          tabIndex={0}
          onClick={onBack}
          onKeyDown={(e) => {
            if (e.key === "Enter") onBack();
          }}
          title="点击返回月视图"
        >
          {year}
        </span>
        <span className="flex flex-col gap-1 text-[11px] leading-none text-muted-foreground">
          <span>{lunarYearLabel(year)}</span>
          <span className="flex items-center gap-2.5">
            <span className="flex items-center gap-1">
              <span className="inline-block h-0.5 w-3 rounded bg-rose-500" />
              春节
            </span>
            <span className="flex items-center gap-1">
              <span className="inline-block h-0.5 w-3 rounded bg-sky-500" />
              初一
            </span>
          </span>
        </span>
        <div className="ml-auto flex items-center gap-1">
          <Button
            variant="ghost"
            size="icon"
            className="size-8"
            onClick={goPrevYear}
            disabled={year <= MIN_YEAR}
            aria-label="上一年"
          >
            <ChevronLeft className="size-4" />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="size-8"
            onClick={goNextYear}
            disabled={year >= MAX_YEAR}
            aria-label="下一年"
          >
            <ChevronRight className="size-4" />
          </Button>
        </div>
      </div>

      {/* 12 个迷你月：固定 3 列 × 4 行，行高等分容器剩余高度 */}
      <div className="grid min-h-0 flex-1 auto-rows-fr grid-cols-3 gap-x-6 gap-y-3">
        {Array.from({ length: 12 }, (_, m) => (
          <MiniMonth
            key={m}
            year={year}
            month={m}
            onPick={(day) => onSelect(new Date(year, m, day))}
            onPickMonth={onPickMonth ? () => onPickMonth(m) : undefined}
          />
        ))}
      </div>
    </div>
  );
}

/** 迷你月历（仅本月日期，无前后月补位；行高随容器自适应） */
function MiniMonth({
  year,
  month,
  onPick,
  onPickMonth,
}: {
  year: number;
  month: number;
  onPick: (day: number) => void;
  onPickMonth?: () => void;
}) {
  const todayYmd = formatYmd(new Date());

  const weeks = useMemo(() => {
    const first = new Date(year, month, 1);
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const offset = (first.getDay() + 6) % 7; // 周一=0
    const cells: (number | null)[] = [
      ...Array.from({ length: offset }, () => null),
      ...Array.from({ length: daysInMonth }, (_, i) => i + 1),
    ];
    while (cells.length % 7 !== 0) cells.push(null);
    const rows: (number | null)[][] = [];
    for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7));
    return rows;
  }, [year, month]);

  /** 农历标记：春节红杠 / 初一蓝杠 */
  const lunarMark = (day: number): "spring" | "newmoon" | null => {
    const lunar = solarToLunar(new Date(year, month, day));
    if (lunar == null || lunar.isLeap) return null;
    if (lunar.day !== 1) return null;
    return lunar.month === 1 ? "spring" : "newmoon";
  };

  return (
    <div className="flex min-h-0 flex-col">
      <button
        type="button"
        onClick={onPickMonth ?? (() => onPick(1))}
        className="mb-0.5 shrink-0 text-left text-xs font-bold hover:text-primary"
      >
        {month + 1}月
      </button>
      <div className="grid min-h-0 flex-1 grid-cols-7 grid-rows-[auto_repeat(6,minmax(0,1fr))] gap-x-0.5">
        {WEEKDAY_LABELS.map((label) => (
          <span
            key={label}
            className="text-center text-[10px] leading-none text-muted-foreground"
          >
            {label}
          </span>
        ))}
        {weeks.flat().map((day, i) => {
          if (day == null) return <span key={i} />;
          const date = new Date(year, month, day);
          const isWeekend = date.getDay() === 0 || date.getDay() === 6;
          const isToday = formatYmd(date) === todayYmd;
          const mark = lunarMark(day);
          return (
            <button
              key={i}
              type="button"
              onClick={() => onPick(day)}
              className={cn(
                "flex items-center justify-center rounded text-[11px] leading-none tabular-nums transition-colors hover:bg-primary/15 hover:text-primary dark:hover:bg-primary/25",
                isToday && "font-bold",
                !isToday && isWeekend && "text-sky-600 dark:text-sky-400",
              )}
              title={`${month + 1}月${day}日`}
            >
              <span className="relative">
                <span
                  className="rounded-full px-1.5"
                  style={
                    isToday ? { backgroundColor: TODAY_BG, color: "#fff" } : undefined
                  }
                >
                  {day}
                </span>
                {mark != null && (
                  <span
                    className={cn(
                      "absolute -bottom-0.5 left-1/2 h-[2px] w-3 -translate-x-1/2 rounded",
                      mark === "spring" ? "bg-rose-500" : "bg-sky-500",
                    )}
                  />
                )}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
