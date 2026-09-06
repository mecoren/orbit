/**
 * CalendarView — 日历视图（07 报告 §五-P2#14：月/议程两档起步）
 *
 * 月档：7×6 周格。有 due_date 的任务按本地日落到格内；未完成逾期任务红字标注。
 *   格内任务条列表支持纵向滚动（格内容量超可视高度时滑看全部；滚到底显示
 *   「共 N 条」尾巴，桌面鼠标滚轮/触控板滑动直达），点击任务条打开详情抽屉。
 *   日期格右上角节假日徽标（放假「休」/调休补班「班」，联网数据）。
 * 议程档：本月有截止的任务按日期分组的滚动列表，空态引导去列表视图。
 * 两档共用工具栏：今天按钮 + 上/下月翻页（12 月/1 月正确跨年）+ 当天定位
 *   议程列表自动滚动到今天所在组 + 节假日手动更新（显示上次更新时间）。
 * 范围遵循 04 §四 内存筛选语义：由 list-page 注入已筛选的 visibleTasks。
 */
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { addMonths, format, isSameDay, isSameMonth, startOfMonth } from "date-fns";
import { zhCN } from "date-fns/locale";
import { CalendarClock, CalendarDays, ChevronLeft, ChevronRight, Inbox, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useTodoStore } from "@/features/todo/store";
import { EmptyState } from "@/components/business/empty-state";
import { holidaysList, holidaysUpdate, holidayMeta, type HolidayInfo } from "@/lib/tauri";
import { OVERDUE_COLOR_CLASS, PRIORITY_COLOR } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { TaskContextMenu } from "./task-context-menu";
import type { TodoLabel, TodoProject, TodoTask } from "@/lib/tauri";

export type CalendarSubMode = "month" | "agenda";

interface CalendarViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  labelsByTask: Map<number, TodoLabel[]>;
  /** 空「新建任务」动作回调（议程空态引导，由 list-page 注入打开表单） */
  onCreateClick?: () => void;
}

const WEEKDAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"];

/** due_date（本地毫秒）→ 本地 YYYY-MM-DD，口径同 quick-add/表单日期链 */
function dayKey(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 月档 7×6 网格：以周一为首（zhCN + weekStartsOn 既有口径）铺满当月视图 */
function buildMonthGrid(month: Date): Date[][] {
  const first = startOfMonth(month);
  // 周一为一周起点：offset = (weekday+6)%7（周日=0 → 6）
  const offset = (first.getDay() + 6) % 7;
  const gridStart = new Date(first);
  gridStart.setDate(first.getDate() - offset);
  return Array.from({ length: 6 }, (_, w) =>
    Array.from({ length: 7 }, (_, d) => {
      const day = new Date(gridStart);
      day.setDate(gridStart.getDate() + w * 7 + d);
      return day;
    }),
  );
}

export function CalendarView({ tasks, projects, labelsByTask, onCreateClick }: CalendarViewProps) {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const [subMode, setSubMode] = useState<CalendarSubMode>("month");
  const [month, setMonth] = useState(() => startOfMonth(new Date()));
  // 月档某日全部任务的弹层（点任务条自带「展开全部」时打开）
  const [expandedDay, setExpandedDay] = useState<Date | null>(null);
  const [updatingHolidays, setUpdatingHolidays] = useState(false);
  const queryClient = useQueryClient();

  // 节假日数据（联网更新；空库时 Rust 侧回落预置 2026 表，冷启动即有徽标）
  const holidaysQuery = useQuery({
    queryKey: ["holidays", "list"],
    queryFn: holidaysList,
    staleTime: 5 * 60_000,
  });
  const holidayMetaQuery = useQuery({
    queryKey: ["holidays", "meta"],
    queryFn: holidayMeta,
    staleTime: 5 * 60_000,
  });
  const holidayByDate = new Map(
    (holidaysQuery.data ?? []).map((h) => [h.date, h] as const),
  );

  const refreshHolidays = async () => {
    setUpdatingHolidays(true);
    try {
      await holidaysUpdate();
      await queryClient.invalidateQueries({ queryKey: ["holidays"] });
      toast.success("节假日数据已更新");
    } catch (err) {
      toast.error(`节假日更新失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setUpdatingHolidays(false);
    }
  };

  // 逾期判定以「今天 00:00」为界：截止在今天内的任务不算逾期（与 task-list-view 当日口径一致）
  const today = useMemo(() => {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    return d;
  }, []);

  /** due_date → 本地日聚合（一次遍历，两档共用） */
  const byDay = useMemo(() => {
    const map = new Map<string, TodoTask[]>();
    for (const t of tasks) {
      if (t.due_date == null) continue;
      const key = dayKey(t.due_date);
      const list = map.get(key);
      if (list) list.push(t);
      else map.set(key, [t]);
    }
    for (const list of map.values()) {
      list.sort((a, b) => a.position - b.position || b.created_at - a.created_at);
    }
    return map;
  }, [tasks]);

  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  const openDetail = (id: number) => setSelectedTaskId(id);

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      {/* 工具栏：月/议程两档切换 + 翻月 + 今天回位 + 节假日手动更新 */}
      <div className="flex items-center justify-between gap-3 px-4 py-2">
        <h2 className="text-lg font-semibold">{format(month, "yyyy年M月", { locale: zhCN })}</h2>
        <div className="flex items-center gap-2">
          <div className="flex items-center overflow-hidden rounded-md border">
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none"
              aria-pressed={subMode === "month"}
              onClick={() => setSubMode("month")}
            >
              <CalendarDays size={14} />
              月
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none"
              aria-pressed={subMode === "agenda"}
              onClick={() => setSubMode("agenda")}
            >
              <CalendarClock size={14} />
              议程
            </Button>
          </div>
          <Button
            variant="outline"
            size="sm"
            className="h-8"
            onClick={() => setMonth(startOfMonth(new Date()))}
          >
            今天
          </Button>
          <Button
            variant="outline"
            size="icon"
            className="h-8 w-8"
            aria-label="上个月"
            onClick={() => setMonth((m) => addMonths(m, -1))}
          >
            <ChevronLeft size={14} />
          </Button>
          <Button
            variant="outline"
            size="icon"
            className="h-8 w-8"
            aria-label="下个月"
            onClick={() => setMonth((m) => addMonths(m, 1))}
          >
            <ChevronRight size={14} />
          </Button>
          {/* 手动更新节假日：显示上次成功时间；每日 8 点守护自动更新（错过的下次启动补更） */}
          <Button
            variant="outline"
            size="sm"
            className="h-8 gap-1.5"
            title={
              holidayMetaQuery.data && holidayMetaQuery.data.last_update_ms > 0
                ? `上次更新：${format(new Date(holidayMetaQuery.data.last_update_ms), "M月d日 HH:mm")}（每天自动更新一次）`
                : "每天自动更新一次，也可手动更新"
            }
            disabled={updatingHolidays}
            onClick={refreshHolidays}
          >
            <RefreshCw size={13} className={cn(updatingHolidays && "animate-spin")} />
            节假日
          </Button>
        </div>
      </div>

      {subMode === "month" ? (
        <MonthGrid
          month={month}
          today={today}
          byDay={byDay}
          holidayByDate={holidayByDate}
          onOpenDetail={openDetail}
          onExpandDay={(day) => setExpandedDay(day)}
        />
      ) : (
        <AgendaList
          month={month}
          today={today}
          byDay={byDay}
          holidayByDate={holidayByDate}
          projectById={projectById}
          labelsByTask={labelsByTask}
          projects={projects}
          onOpenDetail={openDetail}
          onCreateClick={onCreateClick}
        />
      )}

      {/* 月格弹层：该日全部任务（与列表行同构的简化行，右键菜单可用）。
          入口：任务条尾部「展开」按钮（滚动不便时的键盘/精确定位替代） */}
      <Dialog open={expandedDay != null} onOpenChange={(o) => !o && setExpandedDay(null)}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {expandedDay ? format(expandedDay, "M月d日 EEEE", { locale: zhCN }) : ""}
            </DialogTitle>
          </DialogHeader>
          <div className="flex flex-col gap-1">
            {expandedDay &&
              (byDay.get(dayKey(expandedDay.getTime())) ?? []).map((t) => (
                <TaskContextMenu
                  key={t.id}
                  task={t}
                  projects={projects}
                  onOpenDetail={() => openDetail(t.id)}
                >
                  <CalendarTaskRow
                    task={t}
                    labels={labelsByTask.get(t.id) ?? []}
                    projectName={t.project_id != null ? projectById.get(t.project_id)?.title : undefined}
                    onActivate={() => openDetail(t.id)}
                  />
                </TaskContextMenu>
              ))}
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

// ---------------- 节假日徽标 ----------------

/** 放假「休」（绿）/ 调休补班「班」（橙）小徽标；普通日不渲染 */
function HolidayBadge({ holiday }: { holiday: HolidayInfo | undefined }) {
  if (!holiday) return null;
  return (
    <span
      title={holiday.name}
      className={cn(
        "rounded px-1 text-[10px] font-medium leading-4 tabular-nums",
        holiday.is_holiday
          ? "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
          : "bg-orange-500/15 text-orange-600 dark:text-orange-400",
      )}
    >
      {holiday.is_holiday ? "休" : "班"}
    </span>
  );
}

// ---------------- 月档 ----------------

interface MonthGridProps {
  month: Date;
  today: Date;
  byDay: Map<string, TodoTask[]>;
  holidayByDate: Map<string, HolidayInfo>;
  onOpenDetail: (id: number) => void;
  onExpandDay: (day: Date) => void;
}

function MonthGrid({ month, today, byDay, holidayByDate, onOpenDetail, onExpandDay }: MonthGridProps) {
  const weeks = useMemo(() => buildMonthGrid(month), [month]);

  return (
    <div className="flex min-h-0 flex-1 flex-col px-4 pb-3">
      {/* 星期表头（周一始） */}
      <div className="grid grid-cols-7 border-b">
        {WEEKDAY_LABELS.map((w, i) => (
          <div
            key={w}
            className={cn(
              "py-1.5 text-center text-xs text-muted-foreground",
              i >= 5 && "text-muted-foreground/80",
            )}
          >
            {w}
          </div>
        ))}
      </div>
      <div className="grid min-h-0 flex-1 grid-cols-7 grid-rows-6 border-b border-l">
        {weeks.flat().map((day) => {
          const inMonth = isSameMonth(day, month);
          const isToday = isSameDay(day, today);
          const dayTasks = byDay.get(dayKey(day.getTime())) ?? [];
          const holiday = holidayByDate.get(format(day, "yyyy-MM-dd"));
          return (
            <div
              key={day.getTime()}
              className={cn(
                "flex min-h-0 flex-col gap-0.5 overflow-hidden border-r border-t p-1",
                !inMonth && "bg-accent/20 text-muted-foreground",
              )}
            >
              <div
                className={cn(
                  "flex items-center justify-between gap-1 text-[11px] leading-4",
                  !inMonth && "opacity-60",
                )}
              >
                <span
                  className={cn(
                    "min-w-5 rounded px-1 tabular-nums",
                    isToday &&
                      "bg-primary font-semibold text-primary-foreground",
                  )}
                >
                  {format(day, "d")}
                </span>
                <span className="flex items-center gap-1">
                  <HolidayBadge holiday={holiday} />
                  {dayTasks.length > 0 && (
                    <span className="text-[10px] text-muted-foreground/70 tabular-nums">
                      {dayTasks.length}
                    </span>
                  )}
                </span>
              </div>
              {/* 可滚动任务条列表：任务多于可视高度时纵向滑动查看全部
                  （overflow-y-auto；滚到底部还有「共 N 条」尾巴兜底提示） */}
              <MonthCellTaskList
                day={day}
                dayTasks={dayTasks}
                today={today}
                muted={!inMonth}
                onOpenDetail={onOpenDetail}
                onExpandDay={onExpandDay}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}

interface MonthCellTaskListProps {
  day: Date;
  dayTasks: TodoTask[];
  today: Date;
  muted: boolean;
  onOpenDetail: (id: number) => void;
  onExpandDay: (day: Date) => void;
}

/** 月格任务条滚动列表（用户需求：超出可滑动查看当日全部内容） */
function MonthCellTaskList({
  day,
  dayTasks,
  today,
  muted,
  onOpenDetail,
  onExpandDay,
}: MonthCellTaskListProps) {
  return (
    <div className="scroll-smooth flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto">
      {dayTasks.map((t) => (
        <MonthCellTask
          key={t.id}
          task={t}
          muted={muted}
          overdue={!t.done && t.due_date! < today.getTime()}
          onExpand={dayTasks.length > 1 ? () => onExpandDay(day) : undefined}
          onClick={() => onOpenDetail(t.id)}
        />
      ))}
    </div>
  );
}

interface MonthCellTaskProps {
  task: TodoTask;
  /** 非本月格降透明度 */
  muted: boolean;
  overdue: boolean;
  onClick: () => void;
  /** 尾部「展开全部」按钮回调（弹层精确定位；滚动之外的键盘可达路径） */
  onExpand?: () => void;
}

/** 月格任务条：优先级左色点 + 截止时间 + 截断标题；点击打开详情抽屉 */
function MonthCellTask({ task: t, muted, overdue, onClick, onExpand }: MonthCellTaskProps) {
  return (
    <div
      className={cn(
        "group/bar flex w-full items-center gap-1 overflow-hidden rounded px-1 text-left text-[11px] leading-4 hover:bg-accent",
        muted && "opacity-60",
        t.done ? "text-muted-foreground/80" : "text-foreground/90",
      )}
    >
      <button
        type="button"
        aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
        className="flex min-w-0 flex-1 items-center gap-1"
        onClick={onClick}
      >
        <span
          aria-hidden
          className="size-1.5 shrink-0 rounded-full"
          style={{ background: PRIORITY_COLOR[t.priority] || PRIORITY_COLOR[1] }}
        />
        <span
          className={cn("shrink-0 tabular-nums text-muted-foreground", overdue && OVERDUE_COLOR_CLASS)}
        >
          {t.due_date != null ? format(new Date(t.due_date), "HH:mm") : ""}
        </span>
        <span className={cn("truncate", t.done && "line-through", overdue && OVERDUE_COLOR_CLASS)}>
          {t.title}
        </span>
      </button>
      {onExpand && (
        <button
          type="button"
          aria-label="展开该日全部任务"
          className="hidden shrink-0 rounded px-0.5 text-muted-foreground/70 hover:bg-accent hover:text-accent-foreground group-hover/bar:block"
          onClick={onExpand}
        >
          ⋯
        </button>
      )}
    </div>
  );
}

// ---------------- 议程档 ----------------

interface AgendaListProps {
  month: Date;
  today: Date;
  byDay: Map<string, TodoTask[]>;
  holidayByDate: Map<string, HolidayInfo>;
  projectById: Map<number, TodoProject>;
  projects: TodoProject[];
  labelsByTask: Map<number, TodoLabel[]>;
  onOpenDetail: (id: number) => void;
  onCreateClick?: () => void;
}

function AgendaList({
  month,
  today,
  byDay,
  holidayByDate,
  projectById,
  projects,
  labelsByTask,
  onOpenDetail,
  onCreateClick,
}: AgendaListProps) {
  // 本月有任务的日期升序分组
  const groups = useMemo(() => {
    const prefix = format(month, "yyyy-MM");
    return [...byDay.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, list]) => ({ key, list, day: new Date(`${key}T00:00:00`) }));
  }, [byDay, month]);

  // 今天（或今天之后第一个有任务的日期）所在组的 DOM 注册表，
  // 挂载后一次性滚动到该组（用户主动滚动后不再干预）
  const groupRefs = useRef(new Map<string, HTMLDivElement>());
  const scrolled = useRef(false);
  useEffect(() => {
    if (scrolled.current) return;
    const target =
      groups.find((g) => g.day >= today) ?? groups[groups.length - 1];
    if (!target) return;
    groupRefs.current.get(target.key)?.scrollIntoView({ block: "start" });
    scrolled.current = true;
  }, [groups, today]);

  if (groups.length === 0) {
    return (
      <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="本月没有带截止日期的任务"
          hint="给任务设置截止日期后，会按天排列在这里"
          action={
            onCreateClick ? (
              <Button size="sm" variant="outline" onClick={onCreateClick}>
                新建任务
              </Button>
            ) : undefined
          }
        />
      </div>
    );
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
      {groups.map(({ key, list, day }) => (
        <div key={key} ref={(el) => {
          if (el) groupRefs.current.set(key, el);
          else groupRefs.current.delete(key);
        }}>
          <div className="sticky top-0 z-10 -mx-1 mt-4 flex items-center gap-2 bg-background/95 px-1 py-1.5 backdrop-blur first:mt-0">
            <span
              className={cn(
                "rounded px-1.5 py-0.5 text-xs font-medium",
                isSameDay(day, today)
                  ? "bg-primary text-primary-foreground"
                  : "text-muted-foreground",
              )}
            >
              {format(day, "M月d日 EEEE", { locale: zhCN })}
            </span>
            <HolidayBadge holiday={holidayByDate.get(key)} />
            <span className="text-xs text-muted-foreground/70 tabular-nums">{list.length} 条</span>
            <span className="h-px flex-1 bg-border/40" />
          </div>
          <div className="mt-1 flex flex-col gap-1">
            {list.map((t) => (
              <TaskContextMenu
                key={t.id}
                task={t}
                projects={projects}
                onOpenDetail={() => onOpenDetail(t.id)}
              >
                <CalendarTaskRow
                  task={t}
                  labels={labelsByTask.get(t.id) ?? []}
                  projectName={t.project_id != null ? projectById.get(t.project_id)?.title : undefined}
                  onActivate={() => onOpenDetail(t.id)}
                  overdue={!t.done && t.due_date! < today.getTime()}
                />
              </TaskContextMenu>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

// ---------------- 共用行 ----------------

interface CalendarTaskRowProps {
  task: TodoTask;
  labels: TodoLabel[];
  projectName?: string;
  onActivate: () => void;
  overdue?: boolean;
}

/** 议程/弹层任务行：优先级左色条 + 标题 + 标签/项目元信息 + 截止时刻（逾期红） */
function CalendarTaskRow({
  task: t,
  labels,
  projectName,
  onActivate,
  overdue = false,
}: CalendarTaskRowProps) {
  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className="group relative flex cursor-default items-center gap-2.5 rounded-md border border-border/40 px-3 py-2 hover:bg-accent/30 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return;
        if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) {
          e.preventDefault();
          onActivate();
        }
      }}
    >
      <span
        aria-hidden
        className="absolute inset-y-1 left-0 w-1 rounded-full"
        style={{ background: PRIORITY_COLOR[t.priority] || PRIORITY_COLOR[1] }}
      />
      <div className="min-w-0 flex-1">
        <div
          className={cn(
            "truncate text-sm leading-5",
            t.done ? "text-muted-foreground line-through" : "text-foreground",
          )}
        >
          {t.title}
        </div>
        <div className="mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground">
          <LabelChips labels={labels} />
          {projectName && <span>{projectName}</span>}
        </div>
      </div>
      <span
        className={cn(
          "shrink-0 text-xs text-muted-foreground tabular-nums",
          overdue && OVERDUE_COLOR_CLASS,
        )}
      >
        {t.due_date != null ? format(new Date(t.due_date), "HH:mm", { locale: zhCN }) : ""}
      </span>
    </div>
  );
}
