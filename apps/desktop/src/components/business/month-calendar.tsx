/**
 * 月历组件（Days Matter / 系统日历风格）
 *
 * 移植自 wait-home apps/desktop/src/components/business/month-calendar.tsx，
 * 适配 orbit 待办日历场景：
 * - lg 尺寸 + fillHeight：左右分栏布局下任意窗口高度 6 行日期全可见
 * - 今天/休息日/调休补班/选中日用内缩圆角色块（inset-0.5，参考系统日历）
 * - 休/班圆角徽标（右上角：休=蓝 #4C7DF0，班=橙红 #FF7043）
 * - 农历/节日/节气副标签（shared/almanac daySubLabel 由调用方注入）
 * - 任务强调色圆点行（dayChips：≤4 圆点 + "+N"，标题移入右侧列表防撑高）
 * - 右键日格回调（onDayContextMenu：日历视图右击快捷新增）
 * - 头部：可点击月份标题（跳年视图）+ 副标题 + 前后翻月 + 动作插槽
 * - 受控/非受控：传 year/month 受控，否则内部自管
 */
import { useMemo, useState, type ReactNode } from "react";
import type { MouseEvent } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

export type MonthCalendarSize = "lg" | "md" | "sm";

/** 周末数字着色（Google 蓝，与参考设计一致，深浅主题通用） */
export const CALENDAR_WEEKEND_COLOR = "#4C7DF0";
/** 休息日整格浅蓝底（深浅主题通用） */
export const CALENDAR_OFF_DAY_BG = "rgba(76, 125, 240, 0.10)";

const WEEKDAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"];

export interface MonthCalendarDayContext {
  date: Date;
  day: number;
  inMonth: boolean;
  isToday: boolean;
  isSelected: boolean;
  isWeekend: boolean;
  ymd: string;
  /** 网格中前/后一格的日期（越界为 null），供连续区间端点判定 */
  prevDate: Date | null;
  nextDate: Date | null;
  /** 是否位于本周行首/行尾（胶囊区间跨行断开） */
  isRowStart: boolean;
  isRowEnd: boolean;
}

export interface HolidayMark {
  /** true = 放假「休」；false = 调休补班「班」 */
  isOffDay: boolean;
  /** 假日名（徽标 title 提示，如「国庆节」「春节后调休上班」） */
  name?: string;
}

export interface MonthCalendarProps {
  size?: MonthCalendarSize;
  /** 受控年份/月份（month 0-based）；不传则内部自管 */
  year?: number;
  month?: number;
  defaultYear?: number;
  defaultMonth?: number;
  selected?: Date;
  onDayClick?: (date: Date) => void;
  /** 日格右键（日历视图：右击某天快捷新增任务并预填日期） */
  onDayContextMenu?: (e: MouseEvent, date: Date) => void;
  onMonthChange?: (year: number, month: number) => void;
  /** 头部显示（sm 迷你选择器也可隐藏） */
  showHeader?: boolean;
  /** 点击月份标题（如跳年视图）；不传则标题不可点 */
  onTitleClick?: () => void;
  headerSubtitle?: ReactNode;
  headerActions?: ReactNode;
  /** 休/班徽标与底色（sm 不渲染） */
  holidays?: Record<string, HolidayMark>;
  /** 农历等副标签（lg/md） */
  subLabel?: (date: Date) => ReactNode | null;
  /** 任务圆点行（仅 lg；固定 h-4 占位防跳动） */
  dayChips?: (date: Date) => ReactNode;
  /** 完全接管日格内容（自定义视觉时用） */
  dayRender?: (ctx: MonthCalendarDayContext) => ReactNode;
  /** 撑满父容器高度：日格改为 flex-1 等分（需 lg 尺寸 + 父级有确定高度） */
  fillHeight?: boolean;
  className?: string;
}

interface SizeSpec {
  cell: string;
  number: string;
  weekday: string;
  sub: string;
  navBtn: string;
  title: string;
  grid: string;
  badge: string;
}

const SIZE_SPECS: Record<MonthCalendarSize, SizeSpec> = {
  lg: {
    cell: "min-h-20 gap-1 rounded-xl px-1 py-1.5",
    number: "text-lg font-bold leading-none",
    weekday: "py-1 text-sm font-medium",
    sub: "max-w-full truncate px-0.5 text-[11px] leading-none",
    navBtn: "size-8",
    title: "text-3xl font-extrabold tracking-tight",
    grid: "grid-cols-7 gap-1",
    badge: "size-4 text-[9px]",
  },
  md: {
    cell: "min-h-14 gap-0.5 rounded-lg px-0.5 pt-1.5",
    number: "text-sm font-semibold",
    weekday: "py-0.5 text-xs font-medium",
    sub: "max-w-full truncate px-0.5 text-[10px] leading-none",
    navBtn: "size-7",
    title: "text-xl font-bold tracking-tight",
    grid: "grid-cols-7 gap-1",
    // 徽标与 lg 同口径贴日格右上角（原负偏移会越出格子压到相邻日）
    badge: "right-0.5 top-0.5 size-3 text-[7px]",
  },
  sm: {
    cell: "h-8 rounded-md",
    number: "text-xs font-medium",
    weekday: "text-[10px]",
    sub: "",
    navBtn: "size-6",
    title: "text-sm font-semibold",
    grid: "grid-cols-7 gap-0.5",
    badge: "size-2.5 -right-1 -top-1 text-[6px]",
  },
};

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function formatYmd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** 构造 6×7 网格（周一起始），含前后月补位 */
function buildGrid(year: number, month: number): Date[] {
  const first = new Date(year, month, 1);
  const offset = (first.getDay() + 6) % 7;
  const start = new Date(year, month, 1 - offset);
  return Array.from({ length: 42 }, (_, i) => {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    return d;
  });
}

export function MonthCalendar({
  size = "lg",
  year: yearProp,
  month: monthProp,
  defaultYear,
  defaultMonth,
  selected,
  onDayClick,
  onDayContextMenu,
  onMonthChange,
  showHeader = true,
  onTitleClick,
  headerSubtitle,
  headerActions,
  holidays,
  subLabel,
  dayChips,
  dayRender,
  fillHeight = false,
  className,
}: MonthCalendarProps) {
  const spec = SIZE_SPECS[size];
  const now = useMemo(() => startOfDay(new Date()), []);

  const [internal, setInternal] = useState(() => ({
    year: defaultYear ?? selected?.getFullYear() ?? now.getFullYear(),
    month: defaultMonth ?? selected?.getMonth() ?? now.getMonth(),
  }));
  const year = yearProp ?? internal.year;
  const month = monthProp ?? internal.month;

  const changeMonth = (nextYear: number, nextMonth: number) => {
    if (yearProp == null || monthProp == null) setInternal({ year: nextYear, month: nextMonth });
    onMonthChange?.(nextYear, nextMonth);
  };

  const goPrev = () => {
    if (month === 0) changeMonth(year - 1, 11);
    else changeMonth(year, month - 1);
  };
  const goNext = () => {
    if (month === 11) changeMonth(year + 1, 0);
    else changeMonth(year, month + 1);
  };

  const cells = useMemo(() => buildGrid(year, month), [year, month]);
  const todayYmd = formatYmd(now);
  const selectedYmd = selected ? formatYmd(startOfDay(selected)) : null;

  return (
    <div
      className={cn(
        "flex flex-col",
        fillHeight && "h-full justify-center",
        className,
      )}
    >
      {showHeader && (
        <div className="mb-1 flex items-center gap-2">
          <button
            type="button"
            onClick={onTitleClick}
            disabled={!onTitleClick}
            className={cn(
              "rounded-lg px-1 py-0.5 text-foreground",
              onTitleClick && "transition-colors hover:bg-accent/60",
            )}
          >
            <span className={spec.title}>{month + 1}月</span>
          </button>
          {headerSubtitle}
          <div className="ml-auto flex items-center gap-1">
            <Button
              variant="ghost"
              size="icon"
              className={cn(spec.navBtn)}
              onClick={goPrev}
              aria-label="上个月"
            >
              <ChevronLeft className="size-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className={cn(spec.navBtn)}
              onClick={goNext}
              aria-label="下个月"
            >
              <ChevronRight className="size-4" />
            </Button>
            {headerActions}
          </div>
        </div>
      )}

      {/* 星期表头 */}
      <div className={cn("grid", spec.grid, fillHeight && "shrink-0")}>
        {WEEKDAY_LABELS.map((label) => (
          <div
            key={label}
            className={cn("text-center text-muted-foreground", spec.weekday)}
          >
            {label}
          </div>
        ))}
      </div>

      {/* 日期网格：fillHeight 下行高由容器分配（6 行等分剩余高度），
          整体底边与父容器对齐 */}
      <div
        data-testid="month-calendar-grid"
        className={cn(
          "grid",
          spec.grid,
          fillHeight && "min-h-0 flex-1 auto-rows-fr",
        )}
      >
        {cells.map((date, i) => {
          const ymd = formatYmd(date);
          const inMonth = date.getMonth() === month;
          const isToday = ymd === todayYmd;
          const isSelected = selectedYmd != null && ymd === selectedYmd;
          const isWeekend = date.getDay() === 0 || date.getDay() === 6;
          const holiday = holidays?.[ymd];
          const isOffDay = holiday?.isOffDay === true;
          const isWorkday = holiday?.isOffDay === false;
          const ctx: MonthCalendarDayContext = {
            date,
            day: date.getDate(),
            inMonth,
            isToday,
            isSelected,
            isWeekend,
            ymd,
            prevDate: i > 0 ? cells[i - 1] : null,
            nextDate: i < cells.length - 1 ? cells[i + 1] : null,
            isRowStart: i % 7 === 0,
            isRowEnd: i % 7 === 6,
          };

          return (
            <button
              key={`${ymd}-${i}`}
              type="button"
              aria-label={ymd}
              onClick={() => onDayClick?.(startOfDay(date))}
              onContextMenu={
                onDayContextMenu
                  ? (e) => onDayContextMenu(e, startOfDay(date))
                  : undefined
              }
              className={cn(
                "group relative flex w-full flex-col items-center justify-center",
                spec.cell,
                fillHeight && "h-full min-h-0 justify-center",
              )}
            >
              {/* 今天/休息日/调休日/选中态：内缩圆角色块（不贴满整格，参考系统日历）；
                  普通日悬浮时也显示主色淡底块 */}
              {!dayRender && (isToday || isOffDay || isWorkday || isSelected) && (
                <span
                  aria-hidden
                  className="absolute inset-0.5 rounded-lg"
                  style={{
                    backgroundColor: isToday
                      ? "var(--primary)"
                      : isOffDay
                        ? CALENDAR_OFF_DAY_BG
                        : isWorkday
                          ? "var(--muted)"
                          : undefined,
                    border:
                      isSelected && !isToday
                        ? "1.5px solid var(--primary)"
                        : undefined,
                  }}
                />
              )}
              {!dayRender &&
                !isToday &&
                !isOffDay &&
                !isWorkday &&
                !isSelected && (
                  <span
                    aria-hidden
                    className="absolute inset-0.5 rounded-lg bg-transparent transition-colors group-hover:bg-primary/15 dark:group-hover:bg-primary/25"
                  />
                )}
              {/* 休/班徽标：色块右上角 */}
              {holiday && size !== "sm" && (
                <span
                  title={holiday.name}
                  className={cn(
                    "absolute right-0.5 top-0.5 flex items-center justify-center rounded-full font-bold leading-none text-white",
                    spec.badge,
                  )}
                  style={{
                    backgroundColor: isOffDay
                      ? CALENDAR_WEEKEND_COLOR
                      : "#FF7043",
                  }}
                >
                  {isOffDay ? "休" : "班"}
                </span>
              )}
              {dayRender ? (
                dayRender(ctx)
              ) : (
                <>
                  <span className="relative leading-none">
                    <span
                      className={cn(
                        spec.number,
                        "tabular-nums leading-none transition-colors",
                        !inMonth && "opacity-40",
                        !isToday && isWeekend
                          ? "text-sky-600 dark:text-sky-400"
                          : "text-foreground group-hover:text-primary",
                      )}
                      style={isToday ? { color: "#fff" } : undefined}
                    >
                      {ctx.day}
                    </span>
                  </span>
                  {subLabel && size !== "sm" && (
                    <span
                      className={cn(spec.sub, "relative", !inMonth && "opacity-40")}
                      style={{
                        color: isToday
                          ? "rgba(255,255,255,0.9)"
                          : "var(--muted-foreground)",
                      }}
                    >
                      {subLabel(date) ?? ""}
                    </span>
                  )}
                  {dayChips && size === "lg" && (
                    // 任务圆点行固定占位（h-4），无任务也保持等高，
                    // 避免 hover/选中时格子内容跳动
                    <span className="relative flex h-4 w-full items-center justify-center">
                      {dayChips(date)}
                    </span>
                  )}
                </>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}
