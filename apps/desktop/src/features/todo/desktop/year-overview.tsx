/**
 * 年视图内联面板（Days Matter 风格）
 *
 * 移植自 wait-home apps/desktop/src/modules/important-date/year-overview.tsx，
 * 适配 orbit 待办日历：
 * - 12 个迷你月历铺满左半区（3 列 × 4 行），行高等分容器、任意窗口不挤压
 * - 头部：大年份（点击返回月视图）+ 干支生肖标签 + 春节/初一下划线图例 + 切年箭头
 * - 标记口径：今天 = 主色实心内缩圆角方块（与月视图 inset-0.5 rounded-lg 同形制）+ 白字；
 *   春节（正月初一）红下划线；每月初一蓝下划线（杠锚日格底边内 2px，不出格）
 * - 点击任意日期回到月视图并定位该日
 */
import { useMemo } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { useWheelStepRef } from "@/features/todo/shared/wheel-nav";
import { lunarYearLabel, solarToLunar } from "@/features/todo/shared/almanac";
import { formatYmd } from "@/features/todo/shared/lunar";

const WEEKDAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"];
const TODAY_BG = "#4C7DF0";
export const MIN_YEAR = 1901;
export const MAX_YEAR = 2100;

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

  // 面板整体滚轮切年（迷你月历区无独立滚动，接管不影响页面；边界由 goPrev/Next 钳制）
  const wheelRef = useWheelStepRef((dir) => {
    if (dir > 0) goNextYear();
    else goPrevYear();
  });

  return (
    <div ref={wheelRef} className={cn("flex h-full min-h-0 flex-col", className)}>
      {/* 头部：大年份（点击返回月视图）+ 干支/图例 + 切年（与月历头部同节奏） */}
      <div className="mb-1 flex items-center gap-2">
        <Tooltip>
          <TooltipTrigger asChild>
            <span
              className="text-3xl font-extrabold leading-none tracking-tight"
              role="button"
              tabIndex={0}
              onClick={onBack}
              onKeyDown={(e) => {
                if (e.key === "Enter") onBack();
              }}
            >
              {year}
            </span>
          </TooltipTrigger>
          <TooltipContent>点击返回月视图</TooltipContent>
        </Tooltip>
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
                "relative flex items-center justify-center rounded text-[11px] leading-none tabular-nums transition-colors hover:bg-primary/15 hover:text-primary dark:hover:bg-primary/25",
                isToday && "font-bold",
                !isToday && isWeekend && "text-sky-600 dark:text-sky-400",
              )}
              title={`${month + 1}月${day}日`}
            >
              {/* 今天 = 主色实心圆角方块（与月视图同形制：长方形非胶囊）。
                  年视图日格很扁（行高等分约 17×12），inset-0.5 会随格形
                  变长条——方块以格子高度为准（h-[85%] aspect-square），
                  宽随高走，任何窗高下都是饱满方块居中 */}
              {isToday && (
                <span
                  aria-hidden
                  className="absolute inset-y-[7.5%] left-1/2 aspect-square h-[85%] -translate-x-1/2 rounded-md"
                  style={{ backgroundColor: TODAY_BG }}
                />
              )}
              <span
                className="relative"
                style={isToday ? { color: "#fff" } : undefined}
              >
                {day}
              </span>
              {/* 农历杠（春节红/初一蓝）：锚定日格底边内 2px（bottom-0.5）。
                  年视图日格行高约 17px，数字 span flex 居中后其底边距格底
                  仅约 3px——此前锚数字底边再下沉 6px（-bottom-1.5）把杠
                  悬到格外、贴上下一行（用户反馈"离当前日太下"）；改为
                  直接锚格底内 2px，任何窗高下杠都不出格 */}
              {mark != null && (
                <span
                  className={cn(
                    "absolute bottom-0.5 left-1/2 h-[2px] w-3 -translate-x-1/2 rounded",
                    mark === "spring" ? "bg-rose-500" : "bg-sky-500",
                  )}
                />
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}
