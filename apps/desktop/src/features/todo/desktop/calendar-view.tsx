/**
 * CalendarView — 日历视图（wait-home 重要日期风格重构）
 *
 * 左右分栏（参考 wait-home important-date/calendar-view）：
 * - 左半区：月历（Days Matter 风格：内缩色块 + 休/班徽标 + 农历副标签 + 任务圆点）
 *   或周条（G1：7 列周一起始 + 同款格子视觉）/ 年视图（12 个迷你月历）
 * - 右半区：当前范围的任务列表（月/周模式按日分组、选中日高亮并滚动定位；
 *   年模式按月分节）；点击任务行打开详情抽屉
 * - 议程档保留（#24）：整月按日分组的滚动列表 + 右键菜单，与分栏布局互斥切换
 *
 * 交互：
 * - 左键日格 = 选中该日（右栏滚动定位）；右键日格 = 直接打开新增表单并预填该日
 * - 任务在格内只渲染优先级色圆点（≤4 个 + "+N"），标题移入右侧列表防撑高
 * - 今天按钮回位（月档切回月模式；周档留在周档看本周）；节假日手动更新（显示
 *   上次更新时间，每月一次守护自动更新 + 跨月后首轮补更，数据层在 orbit-core holiday_api）
 *
 * 范围遵循 04 §四 内存筛选语义：由 list-page 注入已筛选的 visibleTasks。
 *
 * 日期口径：格子与右栏可按「截止日期」（历史默认）或「开始日期」分桶，工具栏
 * 分段切换并 localStorage 持久化；口径缺失的任务不回落另一字段（两种语义不混排）。
 * 时间轴档按块起点渲染，不提供该开关。
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
  Calendar,
  CalendarClock,
  CalendarDays,
  CalendarRange,
  CalendarX,
  Columns3,
  Hourglass,
  Inbox,
  FileText,
  LocateFixed,
  RefreshCw,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, memo } from "react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
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
import {
  calendarDateFieldLabel,
  calendarTaskDateMs,
  parseCalendarDateField,
  rescheduleStartDate,
  type CalendarDateField,
} from "../shared/calendar-date-field";
import { addDays, dayKey, dayLabel, formatYmd, relativeLabel, startOfDay, startOfWeek, weekRangeLabel } from "@/lib/date-utils";
import { rescheduleDue } from "../shared/reschedule-due";
import { useHolidayMarks } from "../shared/use-holiday-marks";
import { useTaskDescriptionIds } from "../shared/use-task-existence-flags";
import {
  holidaysUpdate,
  holidayMeta,
  todoTaskPage,
  todoTaskUpdate,
  type ListFilter,
} from "@/lib/tauri";
import {
  LS_CALENDAR_DATE_FIELD,
  OVERDUE_COLOR_CLASS,
  PRIORITY_COLOR,
  TODO_ACCENT,
} from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type DisplayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import {
  holidayAutoLabel,
  holidayFailureSuffix,
  holidayMetaLines,
} from "../shared/holiday-meta";
import { TaskContextMenu } from "./task-context-menu";
import { TimelinePanel } from "./timeline-panel";
import { YearOverviewPanel, MAX_YEAR, MIN_YEAR } from "./year-overview";
import { useWheelStepRef, shiftYearMonth } from "../shared/wheel-nav";
import type { ProjectedTaskLabel, TodoProject, TodoTaskListItem } from "@/lib/tauri";

export type CalendarSubMode = "month" | "week" | "timeline" | "year" | "agenda";

/**
 * 时间轴档的跨度档（对标 TickTick 日 / 三日 / 周视图，另加两周）。
 * 一维表达「多日 + 多周」：1 天聚焦当日排程，3 天看短周期，7 天全周，
 * 14 天跨两周看长周期——列均为 24h 网格，逻辑同一条（TimelinePanel 只吃
 * `dayCount`）。
 */
const TIMELINE_SPANS = [1, 3, 7, 14] as const;
type TimelineSpan = (typeof TIMELINE_SPANS)[number];
const TIMELINE_SPAN_LABEL: Record<TimelineSpan, string> = {
  1: "日",
  3: "三日",
  7: "周",
  14: "两周",
};

interface CalendarViewProps {
  tasks: TodoTaskListItem[];
  projects: TodoProject[];
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，行内渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 空「新建任务」动作回调（议程空态引导，由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  /** 右击某天：以该日为当前日历口径日期快捷新增（由壳层注入打开表单并预填） */
  onAddOnDate?: (date: string, field: CalendarDateField) => void;
  /** 加载态（H3）：查询进行中右栏不闪空态 */
  loading?: boolean;
  /**
   * P1 窗口化：按可见范围取数（月/周/议程/时间轴取前后各一月，年视图取整年）。
   * 给了 filter 且 rangeEnabled=true 时，组件自己发范围查询，props.tasks 只作兜底。
   */
  filter?: ListFilter;
  rangeEnabled?: boolean;
}

/** 日历窗口上限：年视图整年、月视图三个月，超出时提示截断（不静默少显示） */
const CALENDAR_RANGE_LIMIT = 5000;

/** 左右分栏：窄窗口退化为上下堆叠（参考 wait-home SPLIT_LAYOUT）。
 *  右/下留白在 CalendarView 根层统一补（三档共用），左半区只保留左侧内距 */
const SPLIT_LAYOUT = "flex h-full min-h-0 flex-col gap-3 xl:flex-row";
const LEFT_PANE = "flex min-h-0 flex-1 flex-col pl-4 xl:flex-none xl:basis-1/2 xl:pl-5";
/** overflow-hidden：滚动行贴到圆角边框时不溢出面板裁切 */
const RIGHT_PANE = "flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl border bg-card/40";
/** 左半区内容宽度约束：flex-1 占满高度（fillHeight 月历需要确定高度容器），
 *  max-w-3xl + mx-auto 水平居中——月历 lg 尺寸 7 列 + 年视图 3 列的最佳宽度 */
const LEFT_CONTENT = "mx-auto min-h-0 w-full max-w-3xl flex-1";

/** 右栏按日分组（月/周模式 / 年模式节内） */
interface DayGroup {
  key: string;
  date: Date;
  tasks: TodoTaskListItem[];
}

/** 右栏按月分节（年模式） */
interface YearSection {
  key: string;
  month: number;
  groups: DayGroup[];
}

export function CalendarView({
  tasks: fallbackTasks,
  projects,
  labelsByTask,
  remindersByTask,
  onCreateClick,
  onAddOnDate,
  loading,
  filter,
  rangeEnabled = false,
}: CalendarViewProps) {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  // 列表通道裁剪 description：行内「有描述」图标只取有无一位（#107，与移动端同投影）
  const descriptionIds = useTaskDescriptionIds();
  const [subMode, setSubMode] = useState<CalendarSubMode>("month");
  /**
   * 日历日期口径（截止 / 开始）：格子与右栏统一按它分桶，跨会话持久化。
   * 只在有日分组语义的档位（月/周/年/议程）生效；时间轴档按块起点渲染，
   * 有自己的排程语义，不提供该开关。
   */
  const [dateField, setDateField] = useState<CalendarDateField>(() =>
    parseCalendarDateField(localStorage.getItem(LS_CALENDAR_DATE_FIELD)),
  );
  useEffect(() => {
    localStorage.setItem(LS_CALENDAR_DATE_FIELD, dateField);
  }, [dateField]);
  /** 视图年月合并为单一 state：两键需原子变更，函数式更新规避连滑时的过期闭包 */
  const [viewTime, setViewTime] = useState(() => ({
    year: new Date().getFullYear(),
    month: new Date().getMonth(),
  }));
  const { year: viewYear, month: viewMonth } = viewTime;
  /** 进入视图默认选中今天（右栏即当天的任务列表） */
  const [selected, setSelected] = useState<Date>(() => startOfDay(new Date()));
  /** 年模式下独立管理的年份（切回月历时同步为 viewYear） */
  const [yearPaneYear, setYearPaneYear] = useState(() => new Date().getFullYear());

  // ---- P1 窗口化：按可见范围取数（月/周/议程/时间轴取前后各一月，年视图取整年）----
  // 范围有界，不做无限滚动；queryKey 用数值边界，翻月即换 key 自然重查
  const calendarRange = useMemo(() => {
    if (subMode === "year") {
      return {
        from: new Date(yearPaneYear, 0, 1).getTime(),
        to: new Date(yearPaneYear + 1, 0, 1).getTime(),
      };
    }
    return {
      from: new Date(viewYear, viewMonth - 1, 1).getTime(),
      to: new Date(viewYear, viewMonth + 2, 1).getTime(),
    };
  }, [subMode, yearPaneYear, viewYear, viewMonth]);
  const rangeQuery = useQuery({
    queryKey: [
      "todo_tasks",
      "calendar",
      dateField,
      calendarRange.from,
      calendarRange.to,
      filter,
    ],
    queryFn: () =>
      todoTaskPage(
        {
          ...(filter ?? { page: 1, page_size: 0 }),
          page: 1,
          page_size: CALENDAR_RANGE_LIMIT,
          // 按开始日期看时，可见范围必须由 start_date 圈定：只按 due 取会漏掉
          // 「start 在范围内、due 在范围外/为空」的排期任务。同时清掉截止语义
          // 的区间（快捷视图「今天/近7天」注入的 due_to）——两套区间 AND 会把
          // 「今天开始、明天截止」的任务挡在窗口外，与当前口径自相矛盾。
          ...(dateField === "start"
            ? {
                due_from: null,
                due_to: null,
                start_from: calendarRange.from,
                start_to: calendarRange.to,
              }
            : {
                start_from: null,
                start_to: null,
                due_from: calendarRange.from,
                due_to: calendarRange.to,
              }),
        },
        null,
        CALENDAR_RANGE_LIMIT,
      ),
    enabled: rangeEnabled && filter != null,
    staleTime: 2 * 60 * 1000,
  });
  // 遮蔽 props.tasks：下游所有分日/分月构建都读这一份
  const tasks = rangeEnabled ? (rangeQuery.data?.items ?? []) : fallbackTasks;
  // 范围查询首屏也算加载态，否则翻月瞬间右栏会闪「当天无任务」空态
  const isLoading = loading || (rangeEnabled && rangeQuery.isLoading);

  // ---- 滚轮步进翻页（桌面 mouse/trackpad 手势） ----
  // 回调经 useWheelStepRef 转存最新闭包；批量步数一次归一，
  // 快速连滑合并为一次渲染（前沿立即 + 后沿补齐，零丢步）。
  const stepViewMonth = (n: number) =>
    setViewTime((prev) => shiftYearMonth(prev.year, prev.month, n));
  const stepViewYear = (n: number) => setViewTime((prev) => ({ ...prev, year: prev.year + n }));
  const stepYearPaneYear = (n: number) =>
    setYearPaneYear(Math.min(MAX_YEAR, Math.max(MIN_YEAR, yearPaneYear + n)));
  const viewYearWheelRef = useWheelStepRef(stepViewYear);
  const viewMonthWheelRef = useWheelStepRef(stepViewMonth);
  const yearPaneWheelRef = useWheelStepRef(stepYearPaneYear);

  // ---- 周档锚点（G1）：选中日所在周，翻周 = selected ±7 天 ----
  // 与月档「右栏跟随视图月、选中日高亮定位」同一心智模型：档位切换不丢
  // 选中日，右栏范围恒围绕它——故周档不额外引入 viewTime，直接派生。
  const weekStart = useMemo(() => startOfWeek(selected), [selected]);
  const weekEnd = useMemo(() => addDays(weekStart, 6), [weekStart]);
  const stepViewWeek = (n: number) => setSelected((prev) => addDays(prev, n * 7));
  const viewWeekWheelRef = useWheelStepRef(stepViewWeek);

  /** 时间轴档跨度（1/3/7/14 天）：局部态，切档保留；翻页步长随跨度走 */
  const [timelineSpan, setTimelineSpan] = useState<TimelineSpan>(7);

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

    // 改的是当前口径对应的字段：按开始日期看时不能偷偷改截止（反之亦然），
    // 否则拖拽后任务会从当前格消失却出现在用户没预期的语义里。
    const nextDate =
      dateField === "start"
        ? rescheduleStartDate(task.start_date, target)
        : rescheduleDue(task.due_date, target);
    if (nextDate == null) return; // 同日落回原处，无变化
    const fieldLabel = calendarDateFieldLabel(dateField);
    const originalMs = dateField === "start" ? task.start_date : task.due_date;
    try {
      await todoTaskUpdate(
        taskId,
        dateField === "start" ? { start_date: nextDate } : { due_date: nextDate },
      );
      void queryClient.invalidateQueries({ queryKey: ["todo_tasks"] });
      void queryClient.invalidateQueries({ queryKey: ["todo-task-detail"] });
      toast.success(
        `「${task.title.slice(0, 20)}」已改${fieldLabel}至 ${formatYmd(target)}`,
        { description: originalMs != null ? "原时刻已保留" : undefined },
      );
    } catch (err) {
      toast.error(`改期失败：${err instanceof Error ? err.message : String(err)}`);
    }
  };

  // 节假日数据（联网更新；空库时 Rust 侧回落预置 2026 表，冷启动即有徽标）
  // marks 与日期选择器共用同一份缓存（shared/use-holiday-marks）
  const holidayMarks = useHolidayMarks();
  const holidayMetaQuery = useQuery({
    queryKey: ["holidays", "meta"],
    queryFn: holidayMeta,
    staleTime: 5 * 60_000,
  });
  // 节假日记账文案：口径短句 / 上次成功更新 / 失败后缀全部走单一出口
  // （shared/holiday-meta），与设置页概览、移动端缓存页同源同措辞
  const holidayMetaData = holidayMetaQuery.data;
  const holidayAutoText = holidayAutoLabel(holidayMetaData?.auto_enabled !== false);
  const holidayLines = holidayMetaLines(holidayMetaData);
  const holidayFailText = holidayFailureSuffix(holidayMetaData);

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

  /** 当前口径日期（due/start）→ 本地日聚合（一次遍历，三档共用） */
  const byDay = useMemo(() => {
    const map = new Map<string, TodoTaskListItem[]>();
    for (const t of tasks) {
      const ms = calendarTaskDateMs(t, dateField);
      // 该口径缺失即不参与分桶（不回落另一字段，避免两种日期语义混排）
      if (ms == null) continue;
      const key = dayKey(ms);
      const list = map.get(key);
      if (list) list.push(t);
      else map.set(key, [t]);
    }
    // 组内保留父层传入序（task-panel 已按工具栏档位 sortTasks）——
    // 此处若再按 position 重排，截止/优先级/标题/创建档在日历全部失效
    return map;
  }, [tasks, dateField]);

  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  // memo 友好：打开详情回调恒定引用，日期头/任务行 props 只随业务数据变化
  const openDetail = useCallback(
    (id: number) => setSelectedTaskId(id),
    [setSelectedTaskId],
  );

  // ---- 右栏列表数据：月模式 = 当前月按日分组；周模式 = 本周按日分组；
  //      年模式 = 当年按月分节 ----
  const listGroups = useMemo<DayGroup[] | YearSection[]>(() => {
    const toGroups = (entries: [string, TodoTaskListItem[]][]): DayGroup[] =>
      entries
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, list]) => ({
          key,
          tasks: list,
          date: new Date(`${key}T00:00:00`),
        }));

    const buildDayGroups = (year: number, month: number): DayGroup[] => {
      const prefix = `${year}-${String(month + 1).padStart(2, "0")}`;
      return toGroups([...byDay.entries()].filter(([key]) => key.startsWith(prefix)));
    };

    // 周档：闭区间过滤。ymd 为定宽零填充串，字典序即时间序——无需解析成
    // 时间戳逐个比较（weekStart/weekEnd 均已零点对齐）
    const buildWeekGroups = (): DayGroup[] => {
      const from = formatYmd(weekStart);
      const to = formatYmd(weekEnd);
      return toGroups(
        [...byDay.entries()].filter(([key]) => key >= from && key <= to),
      );
    };

    if (subMode === "week") {
      return buildWeekGroups();
    }
    if (subMode !== "year") {
      return buildDayGroups(viewYear, viewMonth);
    }
    const sections: YearSection[] = [];
    for (let m = 0; m < 12; m++) {
      const groups = buildDayGroups(yearPaneYear, m);
      if (groups.length > 0) sections.push({ key: `m-${m}`, month: m, groups });
    }
    return sections;
  }, [subMode, byDay, viewYear, viewMonth, yearPaneYear, weekStart, weekEnd]);

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

  /**
   * 回到今天：年月同步 + 选中日落回今天
   *
   * keepMode = true 时不切档位——周档的「回到今天」语义是「回到本周」，
   * 若顺手切回月档会丢掉用户正在看的周粒度；月档/议程档沿用既有口径
   * （回今天并把视图拉回月档）。
   */
  const goToday = (keepMode = false) => {
    const now = startOfDay(new Date());
    setViewTime({ year: now.getFullYear(), month: now.getMonth() });
    setSelected(now);
    if (!keepMode) setSubMode("month");
  };

  /** 头部动作：回到今天 + 刷新节假日（月/周模式共用，参考 wait-home headerActions） */
  const renderHeaderActions = (keepMode: boolean) => (
    <>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            variant="ghost"
            size="icon"
            className="size-8 text-muted-foreground"
            onClick={() => goToday(keepMode)}
            aria-label="回到今天"
          >
            <LocateFixed className="size-4" />
          </Button>
        </TooltipTrigger>
        <TooltipContent>回到今天</TooltipContent>
      </Tooltip>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            variant="ghost"
            size="icon"
            className="size-8 text-muted-foreground"
            onClick={refreshHolidays}
            disabled={updatingHolidays}
            aria-label="更新节假日数据"
          >
            {updatingHolidays ? <Spinner className="size-4" /> : <RefreshCw className="size-4" />}
          </Button>
        </TooltipTrigger>
        <TooltipContent>
          {`${holidayLines.lastUpdate}（${holidayAutoText}，也可手动更新）${holidayFailText}`}
        </TooltipContent>
      </Tooltip>
    </>
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      {/* 三档共用的右/下留白容器：议程档无 SPLIT_LAYOUT 的 pr/pb——
          在此层统一补齐，月/年分栏与议程列表右/下边距同口径（外层 Outlet 无 padding） */}
      <div className="flex min-h-0 flex-1 flex-col pr-4 pb-3 xl:pr-5">
      {/* 工具栏：月/周/年/议程四档切换 + 节假日手动更新（议程档） */}
      <div className="flex shrink-0 items-center justify-between gap-3 px-4 py-2">
        <h2 className="text-lg font-semibold">
          {subMode === "year" ? (
            <Tooltip>
              <TooltipTrigger asChild>
                <span ref={yearPaneWheelRef} className="cursor-default" data-testid="calendar-year-pane-title">
                  {yearPaneYear}年
                </span>
              </TooltipTrigger>
              <TooltipContent>滚轮切换年份</TooltipContent>
            </Tooltip>
          ) : subMode === "timeline" ? (
            <>
              <span>{weekStart.getFullYear()}年</span>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span ref={viewWeekWheelRef} className="cursor-default" data-testid="calendar-timeline-title">
                    {weekRangeLabel(weekStart, addDays(weekStart, timelineSpan - 1))}
                  </span>
                </TooltipTrigger>
                <TooltipContent>滚轮切换</TooltipContent>
              </Tooltip>
            </>
          ) : subMode === "week" ? (
            <>
              <span>{weekStart.getFullYear()}年</span>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span ref={viewWeekWheelRef} className="cursor-default" data-testid="calendar-week-title">
                    {weekRangeLabel(weekStart, weekEnd)}
                  </span>
                </TooltipTrigger>
                <TooltipContent>滚轮切换周</TooltipContent>
              </Tooltip>
            </>
          ) : (
            <>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span ref={viewYearWheelRef} className="cursor-default" data-testid="calendar-year-title">
                    {viewYear}年
                  </span>
                </TooltipTrigger>
                <TooltipContent>滚轮切换年份</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span ref={viewMonthWheelRef} className="cursor-default" data-testid="calendar-month-title">
                    {viewMonth + 1}月
                  </span>
                </TooltipTrigger>
                <TooltipContent>滚轮切换月份</TooltipContent>
              </Tooltip>
            </>
          )}
        </h2>
        <div className="flex items-center gap-2">
          {/* 日期口径：格子与右栏按开始/截止日期排布。时间轴档按块起点渲染，
              自带排程语义，显示本开关反而误导，故隐藏。 */}
          {subMode !== "timeline" && (
            <Tooltip>
              <TooltipTrigger asChild>
                <div
                  className="flex items-center overflow-hidden rounded-md border"
                  role="group"
                  aria-label="日历日期口径"
                >
                  {(["start", "due"] as const).map((field) => (
                    <Button
                      key={field}
                      variant="ghost"
                      size="sm"
                      className="h-8 rounded-none px-2.5 text-xs aria-pressed:bg-accent aria-pressed:text-accent-foreground"
                      aria-pressed={dateField === field}
                      onClick={() => setDateField(field)}
                    >
                      {field === "start" ? "开始" : "截止"}
                    </Button>
                  ))}
                </div>
              </TooltipTrigger>
              <TooltipContent>
                日历按「开始日期」或「截止日期」排布任务
              </TooltipContent>
            </Tooltip>
          )}
          <div className="flex items-center overflow-hidden rounded-md border">
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none aria-pressed:bg-accent aria-pressed:text-accent-foreground"
              aria-pressed={subMode === "month"}
              onClick={() => setSubMode("month")}
            >
              <CalendarDays size={14} />
              月
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none aria-pressed:bg-accent aria-pressed:text-accent-foreground"
              aria-pressed={subMode === "week"}
              onClick={() => setSubMode("week")}
            >
              <Columns3 size={14} />
              周
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none aria-pressed:bg-accent aria-pressed:text-accent-foreground"
              aria-pressed={subMode === "timeline"}
              onClick={() => setSubMode("timeline")}
            >
              <Hourglass size={14} />
              时间
            </Button>
            {/* 跨度档（仅时间档可见）：日 / 三日 / 周 / 两周 */}
            {subMode === "timeline" && (
              <div className="flex items-center overflow-hidden rounded-md border">
                {TIMELINE_SPANS.map((n) => (
                  <Button
                    key={n}
                    variant="ghost"
                    size="sm"
                    className="h-8 rounded-none px-2 text-xs aria-pressed:bg-accent aria-pressed:text-accent-foreground"
                    aria-pressed={timelineSpan === n}
                    onClick={() => setTimelineSpan(n)}
                  >
                    {TIMELINE_SPAN_LABEL[n]}
                  </Button>
                ))}
              </div>
            )}
            <Button
              variant="ghost"
              size="sm"
              className="h-8 gap-1.5 rounded-none aria-pressed:bg-accent aria-pressed:text-accent-foreground"
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
              className="h-8 gap-1.5 rounded-none aria-pressed:bg-accent aria-pressed:text-accent-foreground"
              aria-pressed={subMode === "agenda"}
              onClick={() => setSubMode("agenda")}
            >
              <CalendarClock size={14} />
              议程
            </Button>
          </div>
          {(subMode === "agenda" || subMode === "timeline") && (
            <>
              {/* 议程档沿用既有口径（回今天并切回月档）；时间轴档回到本周不切档
                  ——与周档 goToday(keepMode) 同一语义 */}
              <Button
                variant="outline"
                size="sm"
                className="h-8"
                onClick={() => goToday(subMode === "timeline")}
              >
                今天
              </Button>
              {subMode === "agenda" && (
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-8 gap-1.5"
                    disabled={updatingHolidays}
                    onClick={refreshHolidays}
                  >
                    {updatingHolidays ? <Spinner size={13} /> : <RefreshCw size={13} />}
                    节假日
                  </Button>
                </TooltipTrigger>
                <TooltipContent>
                  {`${holidayLines.lastUpdate}（${holidayAutoText}，也可手动更新）${holidayFailText}`}
                </TooltipContent>
              </Tooltip>
              )}
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
                onDragEnd={(e: DragEndEvent) => void handleDragEnd(e)}
                // Esc 取消拖拽只触发 cancel 分支：不复位会让源圆点恒半透明、落点高亮残留
                onDragCancel={() => setDraggingTaskId(null)}
              >
              <MonthCalendar
                size="lg"
                fillHeight
                year={viewYear}
                month={viewMonth}
                onMonthChange={(y, m) => {
                  setViewTime({ year: y, month: m });
                }}
                // 日历整体滚轮翻月（含日格区；左栏无独立滚动，接管不影响右栏列表）
                wheelStep={stepViewMonth}
                selected={selected}
                onDayClick={setSelected}
                onDayContextMenu={(e, date) => {
                  e.preventDefault();
                  e.stopPropagation();
                  onAddOnDate?.(formatYmd(date), dateField);
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
              headerActions={renderHeaderActions(false)}
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
            <div className="flex shrink-0 items-center gap-2 border-b px-3 py-2.5">
              <h3 className="truncate text-sm font-semibold">
                {viewYear}年{viewMonth + 1}月的任务
              </h3>
              <Badge variant="secondary" className="h-5 px-1.5 text-[11px] tabular-nums">
                {listTotal} 条
              </Badge>
              {listTotal > 0 && (
                <span className="ml-auto shrink-0 text-[11px] text-muted-foreground/80">
                  点击日期定位
                </span>
              )}
            </div>
            {isLoading && listTotal === 0 ? (
              // 加载态与列表视图同口径（H3）：查询进行中不闪「本月没有…」空态
              <div aria-busy className="flex min-h-0 flex-1 flex-col gap-2 p-4" data-testid="calendar-loading">
                {Array.from({ length: 6 }, (_, i) => (
                  <div key={i} className="h-12 animate-pulse rounded bg-accent" />
                ))}
              </div>
            ) : listTotal === 0 ? (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
                <span className="flex size-12 items-center justify-center rounded-full bg-muted">
                  <CalendarX className="size-6 text-muted-foreground" />
                </span>
                <p className="text-sm font-medium">
                  本月没有带{calendarDateFieldLabel(dateField)}的任务
                </p>
                <p className="text-xs text-muted-foreground">
                  切换月份，或右键日历日期快速新增
                </p>
              </div>
            ) : (
              <VirtualGroupedList
                groups={listGroups as DayGroup[]}
                today={today}
                dateField={dateField}
                selectedDay={selected}
                scrollToKey={formatYmd(selected)}
                projects={projects}
                projectById={projectById}
                labelsByTask={labelsByTask}
                remindersByTask={remindersByTask}
                descriptionIds={descriptionIds}
                onOpenDetail={openDetail}
              />
            )}
          </div>
        </div>
      ) : subMode === "week" ? (
        <div className={SPLIT_LAYOUT}>
          {/* ===== 左半区：周条（G1，7 列周一起始；与月档同款格子视觉 + 拖拽改期） ===== */}
          <div className={LEFT_PANE}>
            <div className={LEFT_CONTENT}>
              <DndContext
                sensors={sensors}
                collisionDetection={pointerWithin}
                onDragStart={handleDragStart}
                onDragEnd={(e: DragEndEvent) => void handleDragEnd(e)}
                // Esc 取消拖拽只触发 cancel 分支：不复位会让源圆点恒半透明、落点高亮残留
                onDragCancel={() => setDraggingTaskId(null)}
              >
              <MonthCalendar
                size="lg"
                mode="week"
                fillHeight
                // 周档锚点 = 选中日（组件内派生所在周）；year/month 不参与渲染
                selected={selected}
                // 周条整体滚轮翻周（±7 天，与头部前后按钮同一回调）
                wheelStep={stepViewWeek}
                onWeekChange={stepViewWeek}
                onDayClick={setSelected}
                onDayContextMenu={(e, date) => {
                  e.preventDefault();
                  e.stopPropagation();
                  onAddOnDate?.(formatYmd(date), dateField);
                }}
              headerSubtitle={
                <span className="mt-2 text-xs text-muted-foreground">
                  {relativeLabel(selected)}
                </span>
              }
              headerActions={renderHeaderActions(true)}
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

          {/* ===== 右半区：本周任务（按日分组，选中日高亮定位） ===== */}
          <div className={RIGHT_PANE}>
            <div className="flex shrink-0 items-center gap-2 border-b px-3 py-2.5">
              <h3 className="truncate text-sm font-semibold">本周任务</h3>
              <Badge variant="secondary" className="h-5 px-1.5 text-[11px] tabular-nums">
                {listTotal} 条
              </Badge>
              {listTotal > 0 && (
                <span className="ml-auto shrink-0 text-[11px] text-muted-foreground/80">
                  点击日期定位
                </span>
              )}
            </div>
            {isLoading && listTotal === 0 ? (
              // 加载态与月/年档同口径（H3）：查询进行中不闪空态
              <div aria-busy className="flex min-h-0 flex-1 flex-col gap-2 p-4" data-testid="calendar-loading">
                {Array.from({ length: 6 }, (_, i) => (
                  <div key={i} className="h-12 animate-pulse rounded bg-accent" />
                ))}
              </div>
            ) : listTotal === 0 ? (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
                <span className="flex size-12 items-center justify-center rounded-full bg-muted">
                  <CalendarX className="size-6 text-muted-foreground" />
                </span>
                <p className="text-sm font-medium">
                  本周没有带{calendarDateFieldLabel(dateField)}的任务
                </p>
                <p className="text-xs text-muted-foreground">
                  切换周次，或右键日历日期快速新增
                </p>
              </div>
            ) : (
              <VirtualGroupedList
                groups={listGroups as DayGroup[]}
                today={today}
                dateField={dateField}
                selectedDay={selected}
                scrollToKey={formatYmd(selected)}
                projects={projects}
                projectById={projectById}
                labelsByTask={labelsByTask}
                remindersByTask={remindersByTask}
                descriptionIds={descriptionIds}
                onOpenDetail={openDetail}
              />
            )}
          </div>
        </div>
      ) : subMode === "timeline" ? (
        /* ===== 时间轴档（M9 阶段二）：整幅 dayCount 列 × 24h 网格，不用左右分栏 ===== */
        <div className="min-h-0 flex-1 rounded-xl border bg-card/40 p-1">
          <TimelinePanel
            tasks={tasks}
            anchor={weekStart}
            dayCount={timelineSpan}
            projects={projects}
            onOpenDetail={openDetail}
            onReschedule={async (taskId, patch) => {
              try {
                await todoTaskUpdate(taskId, patch);
                void queryClient.invalidateQueries({ queryKey: ["todo_tasks"] });
                void queryClient.invalidateQueries({ queryKey: ["todo-task-detail"] });
                toast.success(
                  "时段已调整",
                  {
                    description:
                      patch.due_date != null ? "原为截止倒推块，已改截止时刻" : "开始时刻与时长已更新",
                  },
                );
              } catch (err) {
                toast.error(`调整失败：${err instanceof Error ? err.message : String(err)}`);
              }
            }}
          />
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
                  setViewTime({ year: date.getFullYear(), month: date.getMonth() });
                  setSelected(startOfDay(date));
                  setSubMode("month");
                }}
                onPickMonth={(m) => {
                  setViewTime({ year: yearPaneYear, month: m });
                  setSelected(new Date(yearPaneYear, m, 1));
                  setSubMode("month");
                }}
                onYearChange={(y) => {
                  setYearPaneYear(y);
                  setViewTime((prev) => ({ ...prev, year: y }));
                }}
              />
            </div>
          </div>

          {/* ===== 右半区：当年的任务列表（按月分节） ===== */}
          <div className={RIGHT_PANE}>
            <div className="flex shrink-0 items-center gap-2 border-b px-3 py-2.5">
              <h3 className="truncate text-sm font-semibold">{yearPaneYear}年的任务</h3>
              <Badge variant="secondary" className="h-5 px-1.5 text-[11px] tabular-nums">
                {listTotal} 条
              </Badge>
            </div>
            {isLoading && listTotal === 0 ? (
              // 同月模式（H3）：年模式右栏加载骨架
              <div aria-busy className="flex min-h-0 flex-1 flex-col gap-2 p-4" data-testid="calendar-loading">
                {Array.from({ length: 6 }, (_, i) => (
                  <div key={i} className="h-12 animate-pulse rounded bg-accent" />
                ))}
              </div>
            ) : listTotal === 0 ? (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
                <span className="flex size-12 items-center justify-center rounded-full bg-muted">
                  <CalendarX className="size-6 text-muted-foreground" />
                </span>
                <p className="text-sm font-medium">
                  本年没有带{calendarDateFieldLabel(dateField)}的任务
                </p>
                <p className="text-xs text-muted-foreground">切换年份，或右键日历日期快速新增</p>
              </div>
            ) : (
              <VirtualGroupedList
                sections={listGroups as YearSection[]}
                today={today}
                dateField={dateField}
                projects={projects}
                projectById={projectById}
                labelsByTask={labelsByTask}
                remindersByTask={remindersByTask}
                descriptionIds={descriptionIds}
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
            title={`本月没有带${calendarDateFieldLabel(dateField)}的任务`}
            hint={`给任务设置${calendarDateFieldLabel(dateField)}后，会按天排列在这里`}
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
          dateField={dateField}
          scrollToToday
          holidayMarks={holidayMarks}
          projects={projects}
          projectById={projectById}
          labelsByTask={labelsByTask}
          remindersByTask={remindersByTask}
          descriptionIds={descriptionIds}
          onOpenDetail={openDetail}
        />
      )}
      </div>

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
                    dateField={dateField}
                    // 弹层与右栏同一逾期口径（与分桶口径无关）
                    overdue={!t.done && t.due_date != null && t.due_date < today.getTime()}
                    hasDescription={descriptionIds.has(t.id)}
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
  task: TodoTaskListItem;
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
      aria-label={`${task.title}：拖到其他日期可改期`}
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
  dayTasks: TodoTaskListItem[];
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
            // 主色底内容用主题前景 token（自定义浅色 accent 下硬编码
            // 白字对比度不足——性能报告 M6 修复）
            isToday ? "text-primary-foreground/90" : "text-muted-foreground",
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
function HolidayBadge({ holiday }: { holiday: HolidayMark | undefined }) {
  if (!holiday) return null;
  return (
    <span
      aria-label={`${holiday.name}${holiday.isOffDay ? "（放假）" : "（补班）"}`}
      className={cn(
        "rounded px-1 text-[10px] font-medium leading-4 tabular-nums",
        holiday.isOffDay ? "bg-success/15 text-success" : "bg-warning/15 text-warning",
      )}
    >
      {holiday.isOffDay ? "休" : "班"}
    </span>
  );
}

// ---------------- 右栏/议程统一虚拟化分组列表 ----------------

/** 打平后的虚拟条目：三种块型共用一个滚动序列。
 *  注意任务行是**独立条目**（行级虚拟化）——按「天」成块交给虚拟器时，单日
 *  数百条任务仍会一次性渲染成数千 DOM（2026-10-29 单日 560 条滑动卡顿根因）。 */
type FlatItem =
  | { kind: "day"; key: string; group: DayGroup }
  | { kind: "month"; key: string; month: number }
  | { kind: "task"; key: string; task: TodoTaskListItem };

/** 任务行固定尺寸：CalendarTaskRow 恒 h-11（44），行间分隔由行内下边框承担
 *  （不再额外留 pb 间距，避免「行距 + 分隔线」双份留白）。
 *  固定高度让滚动时无需逐行 getBoundingClientRect（头行文案不定仍动态测量） */
const TASK_ROW_SIZE = 44;
/** 日期头/月节头首帧估算值（真实高度由 measureElement 校正） */
const DAY_HEADER_ESTIMATE = 40;
const MONTH_HEADER_ESTIMATE = 30;

/** 缺省空集/空表：避免调用方每次渲染新建引用破坏行 memo */
const NO_DESCRIPTION_IDS: ReadonlySet<number> = new Set();
const NO_LABELS: ProjectedTaskLabel[] = [];
const NO_REMINDERS: TaskReminderMeta[] = [];

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
  /** 议程档日期头是否带节假日徽标（与月历共用同一份 marks） */
  holidayMarks?: Record<string, HolidayMark>;
  /** 当前日期口径：行尾时刻与逾期判定都按它取字段 */
  dateField: CalendarDateField;
  projects: TodoProject[];
  projectById: Map<number, TodoProject>;
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  /** 任务→提醒映射（行内提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 有描述的任务 id 集（列表通道裁剪 description，行内只取有无） */
  descriptionIds?: ReadonlySet<number>;
  onOpenDetail: (id: number) => void;
}

/**
 * 右栏（月/年模式）与议程档统一的虚拟化分组列表（P0 #5 日历补齐）。
 *
 * 三个消费位原先各自裸 map 全量渲染 + ScrollArea：千条任务即万级 DOM，
 * 与列表/看板虚拟化后形成口径差。此处打平为「月节头 / 日期头 / 任务行」
 * 三种**行级**条目交给 useVirtualizer，只渲染可视窗 ± overscan。
 * 任务行固定 52px 不测量；头行随徽标/文案浮动走 measureElement。
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
  holidayMarks,
  dateField,
  projects,
  projectById,
  labelsByTask,
  remindersByTask,
  descriptionIds = NO_DESCRIPTION_IDS,
  onOpenDetail,
}: VirtualGroupedListProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  /** 打平：年模式 [月头 + 日头 + 任务行…]；其余 [日头 + 任务行…]（逐行条目） */
  const flat = useMemo<FlatItem[]>(() => {
    const out: FlatItem[] = [];
    const pushGroup = (group: DayGroup) => {
      out.push({ kind: "day", key: `d-${group.key}`, group });
      for (const task of group.tasks) {
        // 带组前缀的 key：任务 id 全局唯一，前缀只防同日跨节（年档）拼错
        out.push({ kind: "task", key: `t-${group.key}-${task.id}`, task });
      }
    };
    if (sections) {
      for (const section of sections) {
        out.push({ kind: "month", key: `m-${section.key}`, month: section.month });
        for (const group of section.groups) pushGroup(group);
      }
    } else if (groups) {
      for (const group of groups) pushGroup(group);
    }
    return out;
  }, [groups, sections]);

  const virtualizer = useVirtualizer({
    count: flat.length,
    getScrollElement: () => scrollRef.current,
    // 任务行固定 52px（h-12 + 4 间距），不挂 measureElement；头行高度随
    // 文案/徽标浮动，仍动态测量
    estimateSize: (i) => {
      const it = flat[i];
      if (it.kind === "month") return MONTH_HEADER_ESTIMATE;
      if (it.kind === "day") return DAY_HEADER_ESTIMATE;
      return TASK_ROW_SIZE;
    },
    overscan: 12,
    getItemKey: (i) => flat[i].key,
  });

  // 月模式选中日定位：scrollToIndex 而非 scrollIntoView——虚拟化下目标
  // 组节点常不在渲染窗内（ref 缺失），索引定位由 virtualizer 算偏移量
  useEffect(() => {
    if (!scrollToKey) return;
    const idx = flat.findIndex(
      (it) => it.kind === "day" && it.group.key === scrollToKey,
    );
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
    const idx = flat.findIndex(
      (it) => it.kind === "day" && it.group.key === target.key,
    );
    if (idx >= 0) {
      virtualizer.scrollToIndex(idx, { align: "start" });
      scrolled.current = true;
    }
    // 仅挂载时执行一次；flat/virtualizer 引用变化不重触发
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollToToday]);

  return (
    <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-1.5 py-1">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}>
        {virtualizer.getVirtualItems().map((vi) => {
          const item = flat[vi.index];
          return (
            <div
              key={item.key}
              data-index={vi.index}
              // 固定高度的任务行不测量（省掉每帧逐行 rect）；头行动态测量
              ref={item.kind === "task" ? undefined : virtualizer.measureElement}
              // 行间距统一用 padding-bottom：absolute 定位下 flex gap 失效，
              // 且 padding 计入 measureElement 高度。任务行不再留间隙——
              // 行间视觉分隔交给行内下边框，列表更紧凑
              className={item.kind === "task" ? undefined : "pb-1"}
              style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
            >
              {item.kind === "month" ? (
                <div className="flex items-center gap-2 px-2 py-1.5">
                  <span className="text-xs font-bold text-primary">
                    {item.month + 1}月
                  </span>
                  <span className="h-px flex-1 bg-border" />
                </div>
              ) : item.kind === "day" ? (
                <DayHeaderRow
                  group={item.group}
                  today={today}
                  isSelectedDay={selectedDay != null && isSameDay(item.group.date, selectedDay)}
                  showHolidayBadge={holidayMarks != null}
                  holiday={holidayMarks?.[item.group.key]}
                />
              ) : (
                <CalendarTaskRowItem
                  task={item.task}
                  todayMs={today.getTime()}
                  dateField={dateField}
                  labels={labelsByTask.get(item.task.id) ?? NO_LABELS}
                  project={
                    item.task.project_id != null
                      ? projectById.get(item.task.project_id)
                      : undefined
                  }
                  reminderMetas={remindersByTask.get(item.task.id) ?? NO_REMINDERS}
                  hasDescription={descriptionIds.has(item.task.id)}
                  projects={projects}
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

/** 按日分组的日期头（行级虚拟化后独立成条目，任务行不再跟它同块）。
 *  agenda 风格（议程档）：日期头带节假日徽标 + 条数 + 分隔线；月/年右栏带选中日高亮 */
function DayHeaderRow({
  group,
  today,
  isSelectedDay,
  showHolidayBadge,
  holiday,
}: {
  group: DayGroup;
  today: Date;
  isSelectedDay: boolean;
  /** true = 议程档日期头样式（带徽标/条数分隔线） */
  showHolidayBadge: boolean;
  holiday?: HolidayMark;
}) {
  const isToday = isSameDay(group.date, today);

  if (showHolidayBadge) {
    // 议程档日期头（原 AgendaList 样式口径）
    return (
      <div className="flex items-center gap-2 px-1 py-1.5">
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
    );
  }

  // 月/年右栏日期头：日期 + 星期 + 相对日（弱化）+ 右侧当日条数。
  // 选中日不用整行淡底（任务密集时太抢视觉），改左侧主色竖条 + 极淡底色
  return (
    <div
      className={cn(
        "relative flex items-center gap-2 rounded-md px-3 py-1.5",
        isSelectedDay && "bg-primary/[0.06]",
      )}
    >
      {isSelectedDay && (
        <span
          aria-hidden
          className="absolute inset-y-1.5 left-0 w-[3px] rounded-full bg-primary"
        />
      )}
      <span className={cn("text-sm font-semibold", isToday && "text-primary")}>
        {dayLabel(group.date)}
      </span>
      <span className="text-xs text-muted-foreground">
        {format(group.date, "EEEE", { locale: zhCN })}
      </span>
      {/* 今天由下方徽标表达，此处的「今天」相对标签是重复信息 */}
      {!isToday && (
        <span className="text-[11px] text-muted-foreground/60">
          {relativeLabel(group.date)}
        </span>
      )}
      {isToday && (
        <Badge variant="outline" className="h-5 text-[10px] text-primary">
          今天
        </Badge>
      )}
      <span className="ml-auto text-[11px] tabular-nums text-muted-foreground/70">
        {group.tasks.length} 条
      </span>
    </div>
  );
}

/** 单条任务行（含右键菜单）：memo 到行级，props 全部取稳定引用
 *  （task 对象 / map 取值 / NO_* 常量 / 稳定回调）——滚动时只有进出窗口的行
 *  才 reconcile，可视窗内的行与右键菜单整体跳过。 */
const CalendarTaskRowItem = memo(function CalendarTaskRowItem({
  task,
  todayMs,
  dateField,
  labels,
  project,
  reminderMetas,
  hasDescription,
  projects,
  onOpenDetail,
}: {
  task: TodoTaskListItem;
  /** 今天 00:00（逾期判定基准） */
  todayMs: number;
  dateField: CalendarDateField;
  labels: ProjectedTaskLabel[];
  project?: TodoProject;
  reminderMetas: TaskReminderMeta[];
  hasDescription: boolean;
  projects: TodoProject[];
  onOpenDetail: (id: number) => void;
}) {
  const onActivate = useCallback(() => onOpenDetail(task.id), [onOpenDetail, task.id]);
  return (
    <TaskContextMenu task={task} projects={projects} onOpenDetail={onActivate}>
      <CalendarTaskRow
        task={task}
        labels={labels}
        project={project}
        onActivate={onActivate}
        dateField={dateField}
        // 逾期是截止语义，与当前分桶口径无关：按开始日期看时同样标红
        //（判定始终取 due_date，不会把 start_date 当逾期基准）
        overdue={!task.done && task.due_date != null && task.due_date < todayMs}
        reminder={displayReminder(reminderMetas, Date.now(), !!task.done)}
        hasDescription={hasDescription}
      />
    </TaskContextMenu>
  );
});

// ---------------- 共用行 ----------------

interface CalendarTaskRowProps {
  task: TodoTaskListItem;
  labels: ProjectedTaskLabel[];
  project?: TodoProject;
  onActivate: () => void;
  /** 逾期（截止早于今天零点且未完成；与当前分桶口径无关） */
  overdue?: boolean;
  /** 日期口径：行尾时刻取该字段（缺省 = 截止日期，Logbook 沿用）；
   *  逾期红标恒取 due_date，不受此口径影响 */
  dateField?: CalendarDateField;
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder?: DisplayReminder | null;
  /** 有描述（列表通道裁剪 description，行内只取有无） */
  hasDescription?: boolean;
}

/** 右栏/议程/弹层任务行：优先级左色条 + 标题 + 标签/项目元信息 + 行尾时刻
 *  （逾期时换成红色「日历图标 + 截止 MM-dd」标，悬浮给完整截止时间）。
 *  memo：勾选其他任务（todo_tasks 数组换引用）时未变行跳过 reconcile。
 *  行高固定 h-11（44）：有无标签/项目名的行等高——元信息有内容才渲染 +
 *  内容垂直居中，外层 flex 恒高，分组内不参差。
 *  行版式为列表式（下边框分隔 + hover 底色），不用卡片外框——日历右栏
 *  一屏二三十行，逐行描边会退化成一堆碎块，分隔线更利于纵向扫读 */
export const CalendarTaskRow = memo(function CalendarTaskRow({
  task: t,
  labels,
  project,
  onActivate,
  overdue = false,
  dateField = "due",
  reminder = null,
  hasDescription = false,
}: CalendarTaskRowProps) {
  const hasMeta = labels.length > 0 || project != null || reminder != null || hasDescription;
  // 行尾时刻跟随当前口径：按开始日期看时显示开始时刻（截止时刻仍可在详情里看）
  const timeMs = dateField === "start" ? t.start_date : t.due_date;
  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className="group relative flex h-11 cursor-default items-center gap-2 border-b border-border/30 px-3 transition-colors hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
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
        className="absolute inset-y-2 left-0 w-[3px] rounded-full"
        style={{ background: PRIORITY_COLOR[t.priority] }}
      />
      <div className="flex min-w-0 flex-1 flex-col justify-center">
        <div
          className={cn(
            "truncate text-[13px] leading-[18px]",
            t.done ? "text-muted-foreground line-through" : "text-foreground",
          )}
        >
          {t.title}
        </div>
        {hasMeta && (
          <div className="flex min-w-0 items-center gap-1.5 text-[11px] leading-4 text-muted-foreground">
            <LabelChips labels={labels} max={2} />
            {/* 项目名与标签之间加分隔点：两者都是彩色文本 + 小色点，
                紧挨着会被读成一串同类标签 */}
            {project && labels.length > 0 && (
              <span aria-hidden className="shrink-0 text-muted-foreground/40">
                ·
              </span>
            )}
            {project && (
              <span className="truncate" style={{ color: project.hex_color || TODO_ACCENT }}>
                {project.title}
              </span>
            )}
            <ReminderChip reminder={reminder} />
            {hasDescription ? (
              <Tooltip>
                <TooltipTrigger asChild>
                  <span className="inline-flex shrink-0 items-center">
                    <FileText className="size-3" aria-label="有描述" />
                  </span>
                </TooltipTrigger>
                <TooltipContent>有描述</TooltipContent>
              </Tooltip>
            ) : null}
          </div>
        )}
      </div>
      {/* 行尾：逾期改渲染红标（与看板卡同形制：日历图标 + MM-dd）。
          红标固定取**截止日期**——逾期是截止语义：按开始日期看时
          start_date 只决定分组，不参与逾期判定，红标仍显示截止日；
          普通行只显示当前口径的时刻。分组头滚动后会移出视野，
          行内保留日期可继续辨认这条属于哪一天；完整截止时刻进悬浮提示 */}
      {overdue && t.due_date != null ? (
        <Tooltip>
          <TooltipTrigger asChild>
            <span
              className={cn(
                "inline-flex shrink-0 items-center gap-1 rounded bg-destructive/10 px-1.5 py-0.5 text-[11px] font-medium tabular-nums",
                OVERDUE_COLOR_CLASS,
              )}
            >
              <Calendar size={11} aria-hidden />
              {format(new Date(t.due_date), "MM-dd")}
            </span>
          </TooltipTrigger>
          <TooltipContent>
            已逾期 · 截止 {format(new Date(t.due_date), "M月d日 HH:mm", { locale: zhCN })}
          </TooltipContent>
        </Tooltip>
      ) : (
        <span className="w-9 shrink-0 text-right text-[11px] text-muted-foreground tabular-nums">
          {timeMs != null ? format(new Date(timeMs), "HH:mm", { locale: zhCN }) : ""}
        </span>
      )}
    </div>
  );
});
