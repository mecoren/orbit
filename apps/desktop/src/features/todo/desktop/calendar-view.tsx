/**
 * CalendarView — 日历视图（wait-home 重要日期风格重构）
 *
 * 左右分栏（参考 wait-home important-date/calendar-view）：
 * - 左半区：月历（Days Matter 风格：内缩色块 + 休/班徽标 + 农历副标签 + 任务圆点）
 *   或年视图（点击月份标题切换；12 个迷你月历 + 干支生肖 + 春节/初一下划线）
 * - 右半区：当前范围的任务列表（月模式按日分组、选中日高亮并滚动定位；
 *   年模式按月分节）；点击任务行打开详情抽屉
 * - 议程档保留（#24）：整月按日分组的滚动列表 + 右键菜单，与分栏布局互斥切换
 *
 * 交互：
 * - 左键日格 = 选中该日（右栏滚动定位）；右键日格 = 直接打开新增表单并预填该日
 * - 任务在格内只渲染优先级色圆点（≤4 个 + "+N"），标题移入右侧列表防撑高
 * - 今天按钮回位（含切回月模式）；节假日手动更新（显示上次更新时间，
 *   每日 8 点守护自动更新 + 錯过补更，数据层在 orbit-core holiday_api）
 *
 * 范围遵循 04 §四 内存筛选语义：由 list-page 注入已筛选的 visibleTasks。
 */
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { format, isSameDay } from "date-fns";
import { zhCN } from "date-fns/locale";
import {
  DndContext,
  PointerSensor,
  pointerWithin,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import {
  CalendarClock,
  CalendarDays,
  CalendarRange,
  CalendarX,
  Inbox,
  LocateFixed,
  Loader2,
  RefreshCw,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, memo } from "react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useTodoStore } from "@/features/todo/store";
import { EmptyState } from "@/components/business/empty-state";
import {
  MonthCalendar,
  type HolidayMark,
} from "@/components/business/month-calendar";
import { daySubLabel } from "../shared/almanac";
import { formatYmd } from "../shared/lunar";
import { rescheduleDue } from "../shared/reschedule-due";
import { holidaysList, holidaysUpdate, holidayMeta, todoTaskUpdate, type HolidayInfo } from "@/lib/tauri";
import { OVERDUE_COLOR_CLASS, PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type DisplayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import { TaskContextMenu } from "./task-context-menu";
import { YearOverviewPanel } from "./year-overview";
import type { TodoLabel, TodoProject, TodoTask } from "@/lib/tauri";

export type CalendarSubMode = "month" | "year" | "agenda";

interface CalendarViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  labelsByTask: Map<number, TodoLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，行内渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 空「新建任务」动作回调（议程空态引导，由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  /** 右击某天：以该日为截止日期快捷新增（由壳层注入打开表单并预填） */
  onAddOnDate?: (date: string) => void;
}

/** 左右分栏：窄窗口退化为上下堆叠（参考 wait-home SPLIT_LAYOUT）
 *  左半区加 px-5 与右栏卡片对齐节奏；月历/年视图内容 max-w-3xl 水平居中，
 *  大窗口下不贴左缘、不无限拉宽（6 列日格约 700px 为最佳可读宽度） */
const SPLIT_LAYOUT = "flex h-full min-h-0 flex-col gap-3 xl:flex-row";
const LEFT_PANE = "flex min-h-0 flex-1 flex-col px-4 xl:flex-none xl:basis-1/2 xl:px-5";
const RIGHT_PANE = "flex min-h-0 flex-1 flex-col rounded-xl border bg-card/40";
/** 左半区内容宽度约束：flex-1 占满高度（fillHeight 月历需要确定高度容器），
 *  max-w-3xl + mx-auto 水平居中——月历 lg 尺寸 7 列 + 年视图 3 列的最佳宽度 */
const LEFT_CONTENT = "mx-auto min-h-0 w-full max-w-3xl flex-1";

/** due_date（本地毫秒）→ 本地 YYYY-MM-DD，口径同 quick-add/表单日期链 */
function dayKey(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/** 选中日距今天的口语化天数 */
function relativeLabel(date: Date): string {
  const diff = Math.round(
    (startOfDay(date).getTime() - startOfDay(new Date()).getTime()) / 86400000,
  );
  if (diff === 0) return "今天";
  return diff > 0 ? `${diff}天后` : `${-diff}天前`;
}

/** 范围内某天的中文日期标签（如 "9月6日"） */
function dayLabel(date: Date): string {
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

/** 右栏按日分组（月模式 / 年模式节内） */
interface DayGroup {
  key: string;
  date: Date;
  tasks: TodoTask[];
}

/** 右栏按月分节（年模式） */
interface YearSection {
  key: string;
  month: number;
  groups: DayGroup[];
}

export function CalendarView({
  tasks,
  projects,
  labelsByTask,
  remindersByTask,
  onCreateClick,
  onAddOnDate,
}: CalendarViewProps) {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const [subMode, setSubMode] = useState<CalendarSubMode>("month");
  const [viewYear, setViewYear] = useState(() => new Date().getFullYear());
  const [viewMonth, setViewMonth] = useState(() => new Date().getMonth());
  /** 进入视图默认选中今天（右栏即当天的任务列表） */
  const [selected, setSelected] = useState<Date>(() => startOfDay(new Date()));
  /** 年模式下独立管理的年份（切回月历时同步为 viewYear） */
  const [yearPaneYear, setYearPaneYear] = useState(() => new Date().getFullYear());
  // 月模式某日全部任务的弹层（点圆点行「展开」按钮打开）
  const [expandedDay, setExpandedDay] = useState<Date | null>(null);
  const [updatingHolidays, setUpdatingHolidays] = useState(false);
  const queryClient = useQueryClient();

  // ---- 月格拖拽改期（Todoist/Things 标配交互）：圆点为拖拽源，日格为落点 ----
  // PointerSensor distance:5（04 §3.3 同看板：位移 5px 内不算拖拽，保证点击）
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
  );
  const [draggingTaskId, setDraggingTaskId] = useState<number | null>(null);

  const handleDragStart = (e: DragStartEvent) => {
    // 拖拽源 id 形如 "dot:<taskId>"
    const raw = String(e.active.id);
    setDraggingTaskId(raw.startsWith("dot:") ? Number(raw.slice(4)) : null);
  };

  const handleDragEnd = async (e: DragEndEvent) => {
    setDraggingTaskId(null);
    const { active, over } = e;
    if (!over) return;
    const raw = String(active.id);
    if (!raw.startsWith("dot:")) return;
    const taskId = Number(raw.slice(4));
    const task = tasks.find((t) => t.id === taskId);
    if (!task) return;
    const overRaw = String(over.id);
    if (!overRaw.startsWith("day:")) return;
    const target = new Date(Number(overRaw.slice(4)));
    if (Number.isNaN(target.getTime())) return;

    const nextDue = rescheduleDue(task.due_date, target);
    if (nextDue == null) return; // 同日落回原处，无变化
    try {
      await todoTaskUpdate(taskId, { due_date: nextDue });
      void queryClient.invalidateQueries({ queryKey: ["todo_tasks"] });
      void queryClient.invalidateQueries({ queryKey: ["todo-task-detail"] });
      void queryClient.invalidateQueries({ queryKey: ["count"] });
      void queryClient.invalidateQueries({ queryKey: ["nav-data"] });
      toast.success(
        `「${task.title.slice(0, 20)}」已改期至 ${formatYmd(target)}`,
        { description: task.due_date != null ? "原截止时刻已保留" : undefined },
      );
    } catch (err) {
      toast.error(`改期失败：${err instanceof Error ? err.message : String(err)}`);
    }
  };

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
  const holidayMarks = useMemo(() => {
    const record: Record<string, HolidayMark> = {};
    for (const [date, h] of holidayByDate) {
      record[date] = { isOffDay: h.is_holiday, name: h.name };
    }
    return record;
  }, [holidaysQuery.data]);

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

  /** due_date → 本地日聚合（一次遍历，三档共用） */
  const byDay = useMemo(() => {
    const map = new Map<string, TodoTask[]>();
    for (const t of tasks) {
      if (t.due_date == null) continue;
      const key = dayKey(t.due_date);
      const list = map.get(key);
      if (list) list.push(t);
      else map.set(key, [t]);
    }
    // 组内保留父层传入序（task-panel 已按工具栏档位 sortTasks）——
    // 此处若再按 position 重排，截止/优先级/标题/创建档在日历全部失效
    return map;
  }, [tasks]);

  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  // memo 友好：打开详情回调恒定引用，日期头/任务行 props 只随业务数据变化
  const openDetail = useCallback(
    (id: number) => setSelectedTaskId(id),
    [setSelectedTaskId],
  );

  // ---- 右栏列表数据：月模式 = 当前月按日分组；年模式 = 当年按月分节 ----
  const listGroups = useMemo<DayGroup[] | YearSection[]>(() => {
    const buildDayGroups = (year: number, month: number): DayGroup[] => {
      const prefix = `${year}-${String(month + 1).padStart(2, "0")}`;
      return [...byDay.entries()]
        .filter(([key]) => key.startsWith(prefix))
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, list]) => ({
          key,
          tasks: list,
          date: new Date(`${key}T00:00:00`),
        }));
    };

    if (subMode !== "year") {
      return buildDayGroups(viewYear, viewMonth);
    }
    const sections: YearSection[] = [];
    for (let m = 0; m < 12; m++) {
      const groups = buildDayGroups(yearPaneYear, m);
      if (groups.length > 0) sections.push({ key: `m-${m}`, month: m, groups });
    }
    return sections;
  }, [subMode, byDay, viewYear, viewMonth, yearPaneYear]);

  /** 右栏条目总数 */
  const listTotal = useMemo(() => {
    if (subMode !== "year") {
      return (listGroups as DayGroup[]).reduce((sum, g) => sum + g.tasks.length, 0);
    }
    return (listGroups as YearSection[]).reduce(
      (sum, s) => sum + s.groups.reduce((g, d) => g + d.tasks.length, 0),
      0,
    );
  }, [listGroups, subMode]);

  /** 选中日定位（月模式）已下沉到 VirtualGroupedList.scrollToKey：
   *  虚拟化下目标组可能不在渲染窗内，DOM scrollIntoView 会失效 */

  const goToday = () => {
    const now = startOfDay(new Date());
    setViewYear(now.getFullYear());
    setViewMonth(now.getMonth());
    setSelected(now);
    setSubMode("month");
  };

  /** 头部动作：回到今天 + 刷新节假日（月/年模式共用，参考 wait-home headerActions） */
  const headerActions = (
    <>
      <Button
        variant="ghost"
        size="icon"
        className="size-8 text-muted-foreground"
        onClick={goToday}
        aria-label="回到今天"
        title="回到今天"
      >
        <LocateFixed className="size-4" />
      </Button>
      <Button
        variant="ghost"
        size="icon"
        className="size-8 text-muted-foreground"
        onClick={refreshHolidays}
        disabled={updatingHolidays}
        aria-label="更新节假日数据"
        title={
          holidayMetaQuery.data && holidayMetaQuery.data.last_update_ms > 0
            ? `上次更新：${format(new Date(holidayMetaQuery.data.last_update_ms), "M月d日 HH:mm")}（每天自动更新一次，也可手动更新）`
            : "每天自动更新一次，也可手动更新"
        }
      >
        {updatingHolidays ? (
          <Loader2 className="size-4 animate-spin" />
        ) : (
          <RefreshCw className="size-4" />
        )}
      </Button>
    </>
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      {/* 工具栏：月/年/议程三档切换 + 节假日手动更新（议程档） */}
      <div className="flex items-center justify-between gap-3 px-4 py-2">
        <h2 className="text-lg font-semibold">
          {subMode === "year"
            ? `${yearPaneYear}年`
            : format(new Date(viewYear, viewMonth), "yyyy年M月", { locale: zhCN })}
        </h2>
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
              aria-pressed={subMode === "year"}
              onClick={() => {
                setYearPaneYear(viewYear);
                setSubMode("year");
              }}
            >
              <CalendarRange size={14} />
              年
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
          {subMode === "agenda" && (
            <>
              <Button variant="outline" size="sm" className="h-8" onClick={goToday}>
                今天
              </Button>
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
            </>
          )}
        </div>
      </div>

      {subMode === "month" ? (
        <div className={SPLIT_LAYOUT}>
          {/* ===== 左半区：月历（拖拽改期 DndContext 只包月历——右栏行拖拽无目标语义） ===== */}
          <div className={LEFT_PANE}>
            <div className={LEFT_CONTENT}>
              <DndContext
                sensors={sensors}
                collisionDetection={pointerWithin}
                onDragStart={handleDragStart}
                onDragEnd={(e) => void handleDragEnd(e)}
              >
              <MonthCalendar
                size="lg"
                fillHeight
                year={viewYear}
                month={viewMonth}
                onMonthChange={(y, m) => {
                  setViewYear(y);
                  setViewMonth(m);
                }}
                selected={selected}
                onDayClick={setSelected}
                onDayContextMenu={(e, date) => {
                  e.preventDefault();
                  e.stopPropagation();
                  onAddOnDate?.(formatYmd(date));
                }}
                onTitleClick={() => {
                  setYearPaneYear(viewYear);
                  setSubMode("year");
                }}
              headerSubtitle={
                <span className="mt-2 text-xs text-muted-foreground">
                  {relativeLabel(selected)}
                </span>
              }
              headerActions={headerActions}
              holidays={holidayMarks}
              subLabel={(date) => daySubLabel(date)}
              dayChips={(date) => (
                <DayDotsDropZone
                  date={date}
                  dayTasks={byDay.get(formatYmd(date)) ?? []}
                  draggingId={draggingTaskId}
                />
              )}
              />
              </DndContext>
            </div>
          </div>

          {/* ===== 右半区：当前月的任务列表（按日分组，选中日高亮定位） ===== */}
          <div className={RIGHT_PANE}>
            <div className="flex shrink-0 items-center gap-2 border-b px-4 py-3">
              <h3 className="text-sm font-semibold">
                {viewYear}年{viewMonth + 1}月的任务
              </h3>
              <Badge variant="secondary">{listTotal} 条</Badge>
              {listTotal > 0 && (
                <span className="text-xs text-muted-foreground">点击日历日期可定位</span>
              )}
            </div>
            {listTotal === 0 ? (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
                <span className="flex size-12 items-center justify-center rounded-full bg-muted">
                  <CalendarX className="size-6 text-muted-foreground" />
                </span>
                <p className="text-sm font-medium">本月没有带截止日期的任务</p>
                <p className="text-xs text-muted-foreground">
                  切换月份，或右键日历日期快速新增
                </p>
              </div>
            ) : (
              <VirtualGroupedList
                groups={listGroups as DayGroup[]}
                today={today}
                selectedDay={selected}
                scrollToKey={formatYmd(selected)}
                projects={projects}
                projectById={projectById}
                labelsByTask={labelsByTask}
                remindersByTask={remindersByTask}
                onOpenDetail={openDetail}
              />
            )}
          </div>
        </div>
      ) : subMode === "year" ? (
        <div className={SPLIT_LAYOUT}>
          {/* ===== 左半区：年视图（12 个迷你月历） ===== */}
          <div className={LEFT_PANE}>
            <div className={LEFT_CONTENT}>
              <YearOverviewPanel
                year={yearPaneYear}
                onBack={() => setSubMode("month")}
                onSelect={(date) => {
                  // 点击年视图某天：回到月历并定位该日
                  setViewYear(date.getFullYear());
                  setViewMonth(date.getMonth());
                  setSelected(startOfDay(date));
                  setSubMode("month");
                }}
                onPickMonth={(m) => {
                  setViewYear(yearPaneYear);
                  setViewMonth(m);
                  setSelected(new Date(yearPaneYear, m, 1));
                  setSubMode("month");
                }}
                onYearChange={(y) => {
                  setYearPaneYear(y);
                  setViewYear(y);
                }}
              />
            </div>
          </div>

          {/* ===== 右半区：当年的任务列表（按月分节） ===== */}
          <div className={RIGHT_PANE}>
            <div className="flex shrink-0 items-center gap-2 border-b px-4 py-3">
              <h3 className="text-sm font-semibold">{yearPaneYear}年的任务</h3>
              <Badge variant="secondary">{listTotal} 条</Badge>
            </div>
            {listTotal === 0 ? (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
                <span className="flex size-12 items-center justify-center rounded-full bg-muted">
                  <CalendarX className="size-6 text-muted-foreground" />
                </span>
                <p className="text-sm font-medium">本年没有带截止日期的任务</p>
                <p className="text-xs text-muted-foreground">切换年份，或右键日历日期快速新增</p>
              </div>
            ) : (
              <VirtualGroupedList
                sections={listGroups as YearSection[]}
                today={today}
                projects={projects}
                projectById={projectById}
                labelsByTask={labelsByTask}
                remindersByTask={remindersByTask}
                onOpenDetail={openDetail}
              />
            )}
          </div>
        </div>
      ) : listTotal === 0 ? (
        // 议程档空态（原 AgendaList 空态口径）
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
      ) : (
        <VirtualGroupedList
          groups={listGroups as DayGroup[]}
          today={today}
          scrollToToday
          holidayByDate={holidayByDate}
          projects={projects}
          projectById={projectById}
          labelsByTask={labelsByTask}
          remindersByTask={remindersByTask}
          onOpenDetail={openDetail}
        />
      )}

      {/* 月模式弹层：该日全部任务（与列表行同构的简化行，右键菜单可用）。
          入口：任务圆点行尾部「展开」按钮（滚动不便时的键盘/精确定位替代） */}
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
                    project={t.project_id != null ? projectById.get(t.project_id) : undefined}
                    reminder={displayReminder(remindersByTask.get(t.id) ?? [], Date.now(), !!t.done)}
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

// ---------------- 月格拖拽改期（圆点 draggable + 日格 droppable） ----------------

/** 单个任务圆点（拖拽源）。拖拽中本体半透明，视觉反馈靠 cursor 即可——
 *  圆点仅 6px 无 DragOverlay 必要，dnd-kit 默认 transform 跟随指针。 */
function DraggableDot({
  task,
  isToday,
  dimmed,
}: {
  task: TodoTask;
  isToday: boolean;
  dimmed: boolean;
}) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `dot:${task.id}`,
  });
  return (
    <span
      ref={setNodeRef}
      {...attributes}
      {...listeners}
      className="size-1.5 shrink-0 cursor-grab rounded-full active:cursor-grabbing"
      style={{
        backgroundColor: PRIORITY_COLOR[task.priority],
        ...(isToday && { boxShadow: "0 0 0 1px rgba(255,255,255,0.45)" }),
        ...(dimmed && { opacity: 0.35 }),
        ...(isDragging && { opacity: 0.6, scale: "1.4" }),
      }}
      title={`拖到其他日期可改期：${task.title}`}
    />
  );
}

/** 日格圆点行（拖拽目标）。原实现无任务日返回 null；拖改期需要空格也能接，
 *  故恒返回 droppable 容器行（原视觉：≤4 点 + "+N"，今日格白字）。 */
function DayDotsDropZone({
  date,
  dayTasks,
  draggingId,
}: {
  date: Date;
  dayTasks: TodoTask[];
  draggingId: number | null;
}) {
  const ymd = formatYmd(date);
  const { setNodeRef, isOver } = useDroppable({ id: `day:${date.getTime()}` });
  const isToday = ymd === formatYmd(startOfDay(new Date()));
  const visibleDots = dayTasks.slice(0, 4);
  const overflow = dayTasks.length - visibleDots.length;
  // 拖拽悬停高亮：主色描边环提示可落点（MonthCalendar 日格是 button，
  // 无法透传 className，落点反馈渲染在本行上）
  return (
    <span
      ref={setNodeRef}
      className={cn(
        "flex h-4 w-full flex-wrap items-center justify-center gap-1 rounded px-0.5 transition-shadow",
        isOver && "ring-2 ring-primary/70 ring-offset-1",
      )}
    >
      {visibleDots.map((t) => (
        <DraggableDot
          key={t.id}
          task={t}
          isToday={isToday}
          dimmed={draggingId != null && draggingId === t.id}
        />
      ))}
      {overflow > 0 && (
        <span
          className={cn(
            "text-[10px] leading-none",
            isToday ? "text-white/90" : "text-muted-foreground",
          )}
        >
          +{overflow}
        </span>
      )}
    </span>
  );
}

// ---------------- 节假日徽标（议程档沿用旧样式口径） ----------------

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

// ---------------- 右栏/议程统一虚拟化分组列表 ----------------

/** 打平后的虚拟条目：三种块型共用一个滚动序列 */
type FlatItem =
  | { kind: "day"; key: string; group: DayGroup }
  | { kind: "month"; key: string; month: number };

interface VirtualGroupedListProps {
  /** 月/议程档：按日分组（可含月外溢出日）；与 sections 二选一 */
  groups?: DayGroup[];
  /** 年模式：按月分节；与 groups 二选一 */
  sections?: YearSection[];
  today: Date;
  /** 月模式选中日（整行高亮）；年/议程档不传 */
  selectedDay?: Date;
  /** 月模式选中日变化时滚动定位到该组（key=YYYY-MM-DD；虚拟化下节点可能
   *  未挂载，须用 scrollToIndex 而非 DOM scrollIntoView） */
  scrollToKey?: string;
  /** 议程档自动滚到今天：true 时挂载后滚到今天/最近未来组（一次性） */
  scrollToToday?: boolean;
  /** 议程档日期头是否带节假日徽标 */
  holidayByDate?: Map<string, HolidayInfo>;
  projects: TodoProject[];
  projectById: Map<number, TodoProject>;
  labelsByTask: Map<number, TodoLabel[]>;
  /** 任务→提醒映射（行内提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  onOpenDetail: (id: number) => void;
}

/**
 * 右栏（月/年模式）与议程档统一的虚拟化分组列表（P0 #5 日历补齐）。
 *
 * 三个消费位原先各自裸 map 全量渲染 + ScrollArea：千条任务即万级 DOM，
 * 与列表/看板虚拟化后形成口径差。此处打平为 day/month 两种头 + 任务行
 * 的线性序列交给 useVirtualizer（动态 measureElement，行高随标签/项目行
 * 有无浮动），只渲染可视窗 ± overscan。
 *
 * 虚拟化行绝对定位后 sticky 日期头不再可用——日期头改为普通块随内容
 * 滚动（选中日/今天仍高亮定位，体验降级点仅「滚动时日期头不吸附」）。
 */
function VirtualGroupedList({
  groups,
  sections,
  today,
  selectedDay,
  scrollToKey,
  scrollToToday,
  holidayByDate,
  projects,
  projectById,
  labelsByTask,
  remindersByTask,
  onOpenDetail,
}: VirtualGroupedListProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  /** 打平：年模式 [月头 + 日头 + 任务行]；其余 [日头 + 任务行] */
  const flat = useMemo<FlatItem[]>(() => {
    const out: FlatItem[] = [];
    if (sections) {
      for (const section of sections) {
        out.push({ kind: "month", key: section.key, month: section.month });
        for (const group of section.groups) {
          out.push({ kind: "day", key: group.key, group });
        }
      }
    } else if (groups) {
      for (const group of groups) {
        out.push({ kind: "day", key: group.key, group });
      }
    }
    return out;
  }, [groups, sections]);

  const virtualizer = useVirtualizer({
    count: flat.length,
    getScrollElement: () => scrollRef.current,
    // 初值仅影响首帧测量前的高度估计（行高 48 + 行间 gap 4 + 日期头 ~36）
    estimateSize: (i) => (flat[i].kind === "day" ? 92 : 30),
    overscan: 10,
    getItemKey: (i) => flat[i].key,
  });

  // 月模式选中日定位：scrollToIndex 而非 scrollIntoView——虚拟化下目标
  // 组节点常不在渲染窗内（ref 缺失），索引定位由 virtualizer 算偏移量
  useEffect(() => {
    if (!scrollToKey) return;
    const idx = flat.findIndex((it) => it.kind === "day" && it.key === scrollToKey);
    if (idx >= 0) virtualizer.scrollToIndex(idx, { align: "start" });
    // selected 变化即定位；flat 结构变化时也会带 scrollToKey 重跑
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollToKey]);

  // 议程档「自动滚到今天（或最近未来日）」：一次性定位（用户主动滚动后不再干预）。
  // 虚拟化下目标行可能未挂载：先按已测量尺寸 scrollToOffset 估算定位即可，
  // overscan 窗口外的精确校正不做二次补偿（千条内误差可接受）
  const scrolled = useRef(false);
  useEffect(() => {
    if (!scrollToToday || scrolled.current) return;
    const list = groups ?? [];
    const target =
      list.find((g) => g.date >= today) ?? list[list.length - 1];
    if (!target) return;
    const idx = flat.findIndex((it) => it.kind === "day" && it.key === target.key);
    if (idx >= 0) {
      virtualizer.scrollToIndex(idx, { align: "start" });
      scrolled.current = true;
    }
    // 仅挂载时执行一次；flat/virtualizer 引用变化不重触发
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollToToday]);

  return (
    <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto p-2">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}>
        {virtualizer.getVirtualItems().map((vi) => {
          const item = flat[vi.index];
          return (
            <div
              key={item.key}
              data-index={vi.index}
              ref={virtualizer.measureElement}
              style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
            >
              {item.kind === "month" ? (
                <div className="mb-1 flex items-center gap-2 px-2 py-1.5">
                  <span className="text-xs font-bold text-primary">
                    {item.month + 1}月
                  </span>
                  <span className="h-px flex-1 bg-border" />
                </div>
              ) : (
                <DayGroupBlock
                  group={item.group}
                  today={today}
                  isSelectedDay={selectedDay != null && isSameDay(item.group.date, selectedDay)}
                  showHolidayBadge={holidayByDate != null}
                  holiday={holidayByDate?.get(item.group.key)}
                  projects={projects}
                  projectById={projectById}
                  labelsByTask={labelsByTask}
                  remindersByTask={remindersByTask}
                  onOpenDetail={onOpenDetail}
                />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** 右栏单个按日分组块（日期头 + 任务行；选中日整行高亮）。
 *  agenda 风格（议程档）：日期头带节假日徽标 + 条数 + 分隔线 */
function DayGroupBlock({
  group,
  today,
  isSelectedDay,
  showHolidayBadge,
  holiday,
  projects,
  projectById,
  labelsByTask,
  remindersByTask,
  onOpenDetail,
}: {
  group: DayGroup;
  today: Date;
  isSelectedDay: boolean;
  /** true = 议程档日期头样式（带徽标/条数分隔线） */
  showHolidayBadge: boolean;
  holiday?: HolidayInfo;
  projects: TodoProject[];
  projectById: Map<number, TodoProject>;
  labelsByTask: Map<number, TodoLabel[]>;
  /** 任务→提醒映射（行内提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  onOpenDetail: (id: number) => void;
}) {
  const isToday = isSameDay(group.date, today);

  return (
    <div>
      {showHolidayBadge ? (
        // 议程档日期头（原 AgendaList 样式口径）
        <div className="mt-4 flex items-center gap-2 px-1 py-1.5 first:mt-0">
          <span
            className={cn(
              "rounded px-1.5 py-0.5 text-xs font-medium",
              isToday ? "bg-primary text-primary-foreground" : "text-muted-foreground",
            )}
          >
            {format(group.date, "M月d日 EEEE", { locale: zhCN })}
          </span>
          <HolidayBadge holiday={holiday} />
          <span className="text-xs text-muted-foreground/70 tabular-nums">
            {group.tasks.length} 条
          </span>
          <span className="h-px flex-1 bg-border/40" />
        </div>
      ) : (
        // 月/年右栏日期头
        <div
          className={cn(
            "flex items-center gap-2 rounded-lg px-3 py-1.5",
            isSelectedDay && "bg-primary/10",
          )}
        >
          <span className={cn("text-sm font-semibold", isToday && "text-primary")}>
            {dayLabel(group.date)}
          </span>
          <span className="text-xs text-muted-foreground">
            {format(group.date, "EEEE", { locale: zhCN })}
          </span>
          <span className="text-xs text-muted-foreground">{relativeLabel(group.date)}</span>
          {isToday && (
            <Badge variant="outline" className="h-5 text-[10px] text-primary">
              今天
            </Badge>
          )}
        </div>
      )}
      <div className="mt-1 flex flex-col gap-1">
        {group.tasks.map((t) => (
          <TaskContextMenu
            key={t.id}
            task={t}
            projects={projects}
            onOpenDetail={() => onOpenDetail(t.id)}
          >
            <CalendarTaskRow
              task={t}
              labels={labelsByTask.get(t.id) ?? []}
              project={t.project_id != null ? projectById.get(t.project_id) : undefined}
              onActivate={() => onOpenDetail(t.id)}
              overdue={!t.done && t.due_date! < today.getTime()}
              reminder={displayReminder(remindersByTask.get(t.id) ?? [], Date.now(), !!t.done)}
            />
          </TaskContextMenu>
        ))}
      </div>
    </div>
  );
}

// ---------------- 共用行 ----------------

interface CalendarTaskRowProps {
  task: TodoTask;
  labels: TodoLabel[];
  project?: TodoProject;
  onActivate: () => void;
  overdue?: boolean;
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder?: DisplayReminder | null;
}

/** 右栏/议程/弹层任务行：优先级左色条 + 标题 + 标签/项目元信息 + 截止时刻（逾期红）。
 *  memo：勾选其他任务（todo_tasks 数组换引用）时未变行跳过 reconcile。
 *  行高固定 h-12：有无标签/项目名的行等高——原实现元信息行无条件渲染
 *  （空 div 也占 mt-0.5+text-xs 一行），无元信息行矮一截、分组内参差；
 *  现改为元信息有内容才渲染 + 内容垂直居中，外层 flex 恒高 48px */
const CalendarTaskRow = memo(function CalendarTaskRow({
  task: t,
  labels,
  project,
  onActivate,
  overdue = false,
  reminder = null,
}: CalendarTaskRowProps) {
  const hasMeta = labels.length > 0 || project != null || reminder != null;
  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className="group relative flex h-12 cursor-default items-center gap-2.5 rounded-md border border-border/40 px-3 hover:bg-accent/30 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return;
        if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) {
          e.preventDefault();
          onActivate();
        }
      }}
    >
      {/* 优先级左缘竖条：六档全显（含 P0「无」浅灰），与列表行/看板卡口径统一 */}
      <span
        aria-hidden
        className="absolute inset-y-1 left-0 w-1 rounded-full"
        style={{ background: PRIORITY_COLOR[t.priority] }}
      />
      <div className="flex min-w-0 flex-1 flex-col justify-center">
        <div
          className={cn(
            "truncate text-sm leading-5",
            t.done ? "text-muted-foreground line-through" : "text-foreground",
          )}
        >
          {t.title}
        </div>
        {hasMeta && (
          <div className="flex items-center gap-1.5 text-xs leading-4 text-muted-foreground">
            <LabelChips labels={labels} />
            {project && (
              <span className="truncate" style={{ color: project.hex_color || TODO_ACCENT }}>
                {project.title}
              </span>
            )}
            <ReminderChip reminder={reminder} />
          </div>
        )}
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
});
