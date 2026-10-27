/**
 * 任务面板 —— /todo 主面板（04 文档 §二 中栏）
 *
 * 壳层（todo-shell）提供侧栏/选中态/查询数据/抽屉表单；本面板只管：
 * 工具栏（标题/搜索/筛选/视图切换）+ 内容区（列表/看板/日历）+ 快加栏。
 * 选中态经 useTodoShell 取用——从回收站面板切回来时筛选原样保留。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, CopyPlus, ListTodo, Search } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useTodoStore } from "@/features/todo/store";
import { useAppStore } from "@/stores/app-store";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  LS_HIDE_DONE,
  LS_VIEW_MODE,
  OVERDUE_PAGE_LIMIT,
  QUICK_VIEWS,
  TASK_LIST_PAGE_SIZE,
  TASK_PAGE_WINDOW,
} from "../shared/constants";
import { useTaskDependencies } from "../shared/use-task-dependencies";
import { useTaskAttachmentIds, useTaskOpenSubtaskIds } from "../shared/use-task-existence-flags";
import { useTaskLabels } from "../shared/use-task-labels";
import { useTaskReminders } from "../shared/use-task-reminders";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import {
  filterTasks,
  sortTasks,
  BASE_SORT_DIR,
  buildPagedFilter,
  type PagedSortKey,
  type TaskSortDir,
  type TaskSortKey,
} from "../shared/task-filters";
import { applySavedFilter } from "../shared/saved-filter";
import {
  savedFiltersList,
  todoTaskBoard,
  todoTaskList,
  todoTaskPage,
  type BoardGroupBy,
  type ListCursor,
  type ListFilter,
} from "@/lib/tauri";
import { startOfDay } from "@/lib/date-utils";
import { useTodoShell } from "./todo-shell";
import { TaskListView } from "./task-list-view";
import { LogbookView } from "./logbook-view";
import { QuickAddBar } from "./quick-add-bar";
import { toolbarToForm, buildConditions } from "../shared/saved-filter-builder";
import { useDebouncedValue } from "../shared/use-debounced-value";
import { SortMenuButton, MoreMenuButton } from "./toolbar-menus";
import { KanbanView, type KanbanGroupBy } from "./kanban-view";
import { CalendarView } from "./calendar-view";
import TaskTableView from "./task-table-view";
import { MatrixView } from "./matrix-view";
import { TodayStrip } from "./today-strip";
import { WeeklyReviewDialog } from "./weekly-review-dialog";
import { TriageDialog } from "./triage-dialog";
import { PlanDayDialog } from "./plan-day-dialog";

type StatusFilter = "all" | "undone" | "pending" | "doing" | "done";
type PriorityFilter = "all" | "0" | "1" | "2" | "3" | "4" | "5";
/** 五档视图（矩阵 = 四象限 Eisenhower Matrix，TickTick 同款；2026-09-25 与移动端对齐） */
export type ViewMode = "list" | "kanban" | "calendar" | "table" | "matrix";

/** 看板/矩阵每列首屏条数（列内「还有 N 条」由组总数给，不再拉全量） */
const BOARD_PAGE_LIMIT = 60;
export type { StatusFilter, PriorityFilter };

/** 视图切换状态持久化（04 §二；07-P2#14 增 calendar 档；2026-09-25 增 matrix 档） */
function loadViewMode(): ViewMode {
  const saved = localStorage.getItem(LS_VIEW_MODE);
  return saved === "kanban" || saved === "calendar" || saved === "table" || saved === "matrix"
    ? saved
    : "list";
}

/** 排序档位持久化键（#26：默认 manual = 拖拽顺序） */
const LS_SORT_KEY = "todo_sort_key";
/** 排序方向持久化（工具栏「↑↓→顺序」档；未存过 = null = 各档位现状默认方向） */
const LS_SORT_DIR = "todo_sort_dir";

/** 隐藏已完成开关持久化读取：未存过 = 默认开（Logbook 治理新默认，
 *  存量用户首次升级后完成行不再平铺在默认列表——明确入口在侧栏「已完成」） */
function loadHideDone(): boolean {
  const saved = localStorage.getItem(LS_HIDE_DONE);
  return saved !== "0";
}

function loadSortKey(): TaskSortKey {
  const saved = localStorage.getItem(LS_SORT_KEY);
  return saved === "due" || saved === "priority" || saved === "title" || saved === "created"
    ? saved
    : "manual";
}

/** 方向档读取：未存过/脏值 = null（跟随 BASE_SORT_DIR 现状默认） */
function loadSortDir(): TaskSortDir | null {
  const saved = localStorage.getItem(LS_SORT_DIR);
  return saved === "asc" || saved === "desc" ? saved : null;
}

export default function TaskPanel() {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const setCommandOpen = useAppStore((s) => s.setCommandOpen);
  const viewToggleIntent = useAppStore((s) => s.viewToggleIntent);
  const consumeViewToggleIntent = useAppStore((s) => s.consumeViewToggleIntent);
  // 收件箱分诊（F2）：侧栏未分组行入口经意图计数器跨层传到本面板的弹窗
  const triageIntent = useAppStore((s) => s.triageIntent);
  const consumeTriageIntent = useAppStore((s) => s.consumeTriageIntent);

  const {
    quickView,
    projectId,
    activeProjectIds,
    ungrouped,
    savedFilterId,
    projects,
    tasks,
    tasksLoading,
    tasksError,
    taskPredicate,
    setNeedsFullTasks,
    overview,
    openCreateForm,
    openCreateFormOnDate,
    openCreateFormFromTemplate,
    templates,
    setLabelManagerOpen,
    createSavedFilterWith,
  } = useTodoShell();

  // ---- 工具栏状态（面板私有，不跨面板保留）----
  const [keyword, setKeyword] = useState("");
  // 周回顾向导（G5）：面板私有开关，关闭即重置向导步进
  const [reviewOpen, setReviewOpen] = useState(false);
  // 收件箱分诊（F2）：面板私有开关；侧栏未分组行的入口钮经 app-store 意图触发
  const [triageOpen, setTriageOpen] = useState(false);
  useEffect(() => {
    if (triageIntent === 0) return;
    consumeTriageIntent();
    setTriageOpen(true);
  }, [triageIntent, consumeTriageIntent]);
  // 规划今天（F3 阶段一）：只读排程预览弹窗
  const [planDayOpen, setPlanDayOpen] = useState(false);
  // 搜索防抖（200ms，与全局搜索 250ms 同族）：输入期不再每键全量
  // filterTasks 重跑（万任务下一键一遍分组+排序），停止击键才过滤
  const debouncedKeyword = useDebouncedValue(keyword.trim(), 200);
  const searching = debouncedKeyword.length > 0;
  // 关键词下沉服务端（A2 前置修复）：全量通道的 description 按批2 列裁剪以
  // `NULL AS description` 占位不传输（万级列表省 47% IPC 体积），面板内的
  // 客户端关键词过滤因此恒搜不到描述——**搜描述静默无结果**。这里对防抖后的
  // 关键词单开一路：SQL 端 LIKE 按 title+description 过滤且命中集保留全列。
  // 不复用壳层那份万行集合做键参数——侧栏未完成计数与详情导航都吃它，
  // 跟着搜索框收窄就是错的数字。
  const taskSearchQuery = useQuery({
    queryKey: ["todo_tasks", debouncedKeyword, taskPredicate],
    queryFn: () =>
      todoTaskList({
        keyword: debouncedKeyword,
        page: 1,
        page_size: TASK_LIST_PAGE_SIZE,
        ...taskPredicate,
      }),
    enabled: searching,
    staleTime: 2 * 60 * 1000,
    gcTime: 10_000,
    // 命中集是小数组（服务端已按关键词收窄），留上一档只为击键间不闪空；
    // 全量通道刻意不挂该防闪（A1）
    placeholderData: (prev) => prev,
  });
  // 取数中且从未有过命中集时，先用全量集合按标题匹配兜一帧（等价于修复前的
  // 可见行为），服务端结果落地后再换——中间态只少不多，不会出假的「无结果」
  const sourceTasks = searching ? (taskSearchQuery.data ?? tasks) : tasks;
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [priorityFilter, setPriorityFilter] = useState<PriorityFilter>("all");
  const [viewMode, setViewMode] = useState<ViewMode>(loadViewMode);
  const [sortKey, setSortKey] = useState<TaskSortKey>(loadSortKey);
  // null = 用户未显式选过方向（生效方向跟随 BASE_SORT_DIR[sortKey]，存量顺序零变化）
  const [sortDir, setSortDir] = useState<TaskSortDir | null>(loadSortDir);
  // 「↑↓→顺序」菜单显示与排序实际使用的生效方向（manual 档忽略方向，随意兜底）
  const effectiveSortDir = sortDir ?? BASE_SORT_DIR[sortKey === "manual" ? "due" : sortKey];
  const [kanbanGroupBy, setKanbanGroupBy] = useState<KanbanGroupBy>("project");
  const [hideDone, setHideDone] = useState<boolean>(loadHideDone);

  useEffect(() => {
    localStorage.setItem(LS_VIEW_MODE, viewMode);
  }, [viewMode]);

  useEffect(() => {
    localStorage.setItem(LS_SORT_KEY, sortKey);
  }, [sortKey]);

  useEffect(() => {
    // null = 回落各档位默认方向，把键清掉（下次升级口径变化时自动跟随）
    if (sortDir == null) localStorage.removeItem(LS_SORT_DIR);
    else localStorage.setItem(LS_SORT_DIR, sortDir);
  }, [sortDir]);

  useEffect(() => {
    localStorage.setItem(LS_HIDE_DONE, hideDone ? "1" : "0");
  }, [hideDone]);

  useEffect(() => {
    if (viewToggleIntent === 0) return;
    // 循环切换 list→kanban→calendar→table→matrix→list（原实现漏了 table，
    // 加 matrix 档时一并修正）
    setViewMode((m) =>
      m === "list"
        ? "kanban"
        : m === "kanban"
          ? "calendar"
          : m === "calendar"
            ? "table"
            : m === "table"
              ? "matrix"
              : "list",
    );
    consumeViewToggleIntent();
  }, [viewToggleIntent, consumeViewToggleIntent]);

  // 任务→标签映射（列表行/看板卡标签 chips 共用）
  const taskLabels = useTaskLabels();
  // 任务→提醒映射（列表行/看板卡/日历行提醒徽标共用；db-change 失效同口径）
  const taskReminders = useTaskReminders();
  // 任务→关联旗标映射（C7 列表行「有关联 / 被阻塞」徽标；关联行写事件精确失效）
  const taskDependencies = useTaskDependencies();
  // 存在旗标集（#71 筛选器存在键数据源；附件/子任务写事件精确失效）
  const attachmentTaskIds = useTaskAttachmentIds();
  const openSubtaskTaskIds = useTaskOpenSubtaskIds();

  // ---- 内存筛选 + 排序（共享模块，语义同 04 §四；排序档位 #26）----
  // keyword 的服务端命中集仍再过一遍本地关键词分支：击键间 placeholder 留着
  // 上一档命中集，不二次过滤就会闪出几条不匹配当前关键词的行
  // #35：选中的保存筛选器（db-change 自动失效）
  const savedFiltersQuery = useQuery({
    queryKey: ["saved-filters", "list"],
    queryFn: () => savedFiltersList(),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const activeSavedFilter = (savedFiltersQuery.data ?? []).find((f) => f.id === savedFilterId);

  // done 快捷视图 + 列表档 → LogbookView 接管（隐藏开关在 done 视图不剔除，
  // 下方 filterTasks 已保证）；其余视图照旧走列表/看板/日历/表格
  const isLogbook = quickView === "done" && projectId == null && !ungrouped && savedFilterId == null;

  // ===========================================================================
  // P1 窗口化：列表/表格改走键集分页
  // ===========================================================================
  //
  // 只有列表与表格两档可分页：它们按单一全局顺序渲染，SQL 排序即视觉顺序。
  // 看板（按列聚合）、日历（按日分组）、四象限（按桶计数）、Logbook（按完成日
  // 分组）都需要「全量才能算对的计数/分组」，继续走旧的全量通道——
  // docs/07 #105 已把「按列/按日独立分页」留作后续批次。
  //
  // title 排序档例外：中文拼音序依赖 localeCompare，SQL 侧复刻不了，
  // 该档也回落全量通道（否则翻页边界与视觉顺序会分叉）。
  // 窗口化基线：保存筛选器条件已下推（#107，14 键全部能表达成 core 谓词），
  // 只剩两处回退——筛选器数据尚未落地（conditions 未知，先按全量显示）与
  // title 档（中文拼音序 SQL 复刻不了）。其余视图各走自己的服务端窗口通道。
  const savedFilterReady = savedFilterId == null || activeSavedFilter != null;
  const windowedBase = savedFilterReady && sortKey !== "title";
  const pagedMode = (viewMode === "list" || viewMode === "table") && !isLogbook && windowedBase;
  // 看板/矩阵：每列前 N 条 + 组总数。标签档保留全量——分列定义来自标签投影，
  // 列数随任务标签动态变化，窗口内的标签会让空列消失
  const boardGroupBy: BoardGroupBy | null =
    windowedBase && !isLogbook
      ? viewMode === "kanban"
        ? kanbanGroupBy === "label"
          ? null
          : (kanbanGroupBy as BoardGroupBy)
        : viewMode === "matrix"
          ? "quadrant"
          : null
      : null;
  // Logbook：完成时间倒序键集分页（done_at 档）
  const logbookPagedMode = isLogbook && viewMode === "list" && !activeSavedFilter;
  // 日历：按可见月范围取数（范围有界，不需要无限滚动）
  const calendarPagedMode = viewMode === "calendar" && windowedBase;

  useEffect(() => {
    setNeedsFullTasks(
      !(pagedMode || boardGroupBy != null || logbookPagedMode || calendarPagedMode),
    );
  }, [pagedMode, boardGroupBy, logbookPagedMode, calendarPagedMode, setNeedsFullTasks]);

  // 逾期判定基准每分钟走一格：既不会每帧重建 queryKey，也不至于跨零点后一直用旧值
  const [nowTick, setNowTick] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNowTick(Date.now()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  // 逾期置顶段单独取（主列表用 exclude_due_before 把逾期行排除，避免重复渲染）
  const overdueEnabled = pagedMode && viewMode === "list";

  const pageFilter = useMemo(
    () =>
      buildPagedFilter({
        keyword: debouncedKeyword,
        predicate: taskPredicate,
        ungrouped,
        hasProjectView: activeProjectIds != null || projectId != null,
        // 快捷视图只在非项目/未分组目标下生效（与 filterTasks 分支同义）
        quickView: projectId == null && !ungrouped && savedFilterId == null ? quickView : null,
        statusFilter,
        priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
        hideDone,
        sortKey: (sortKey === "title" ? "manual" : sortKey) as PagedSortKey,
        sortDir,
        // 逾期行不在这里排除：把它写进 filter 会让 queryKey 带上时间戳，
        // 每分钟重拉首屏、滚动位置回跳。改由下方合并时按 id 去重（见 visibleTasks）
        excludeOverdueBefore: null,
        savedConditions: activeSavedFilter?.conditions ?? null,
        now: new Date(nowTick),
      }),
    [
      debouncedKeyword,
      taskPredicate,
      ungrouped,
      activeProjectIds,
      projectId,
      savedFilterId,
      activeSavedFilter?.conditions,
      quickView,
      statusFilter,
      priorityFilter,
      hideDone,
      sortKey,
      sortDir,
      viewMode,
      nowTick,
    ],
  );

  const pagedQuery = useInfiniteQuery({
    // 前缀必须挂在 ["todo_tasks"] 下：db-change 失效链是前缀匹配
    // （lib/db-invalidation.ts），换独立前缀会让写操作后列表不刷新
    queryKey: ["todo_tasks", "page", pageFilter],
    queryFn: ({ pageParam }) => todoTaskPage(pageFilter, pageParam, TASK_PAGE_WINDOW),
    initialPageParam: null as ListCursor | null,
    getNextPageParam: (last) => last.next_cursor,
    enabled: pagedMode,
    staleTime: 2 * 60 * 1000,
  });

  // 逾期置顶段：同一套筛选，只把截止上界收到「现在」并要求未完成
  const overdueFilter = useMemo(
    () =>
      buildPagedFilter({
        keyword: debouncedKeyword,
        predicate: taskPredicate,
        ungrouped,
        hasProjectView: activeProjectIds != null || projectId != null,
        quickView: projectId == null && !ungrouped && savedFilterId == null ? quickView : null,
        statusFilter,
        priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
        // 逾期段只装未完成行；完成行不可能逾期
        hideDone: true,
        sortKey: "due",
        sortDir: "asc",
        excludeOverdueBefore: null,
        savedConditions: activeSavedFilter?.conditions ?? null,
        now: new Date(nowTick),
      }),
    [
      debouncedKeyword,
      taskPredicate,
      ungrouped,
      activeProjectIds,
      projectId,
      savedFilterId,
      activeSavedFilter?.conditions,
      quickView,
      statusFilter,
      priorityFilter,
      nowTick,
    ],
  );

  const overdueQuery = useQuery({
    queryKey: ["todo_tasks", "overdue", overdueFilter, nowTick],
    queryFn: () =>
      todoTaskPage(
        // 强制未完成：逾期段不该混进已完成行（statusFilter=done 时 hideDone 不生效）。
        // 截止上界取 min——保存筛选器的 due_until 可能比 now 更窄，直接覆盖会放宽条件。
        {
          ...overdueFilter,
          done: false,
          due_to: Math.min(overdueFilter.due_to ?? nowTick, nowTick),
        },
        null,
        OVERDUE_PAGE_LIMIT,
      ).then((p) => p.items),
    enabled: overdueEnabled,
    staleTime: 60_000,
  });

  const pagedTasks = useMemo(
    () => pagedQuery.data?.pages.flatMap((p) => p.items) ?? [],
    [pagedQuery.data],
  );

  // ---- 看板/四象限窗口（每列前 BOARD_PAGE_LIMIT 条 + 组总数）----
  const dayStartMs = useMemo(() => startOfDay(new Date(nowTick)).getTime(), [nowTick]);
  const boardQuery = useQuery({
    queryKey: [
      "todo_tasks",
      "board",
      boardGroupBy,
      pageFilter,
      dayStartMs,
      // 四象限「紧急」界 = 今日 24:00；放在 key 里使跨零点自动重算
      dayStartMs + 86_400_000,
    ],
    queryFn: () =>
      todoTaskBoard(
        pageFilter,
        boardGroupBy as BoardGroupBy,
        BOARD_PAGE_LIMIT,
        dayStartMs,
        dayStartMs + 86_400_000,
      ),
    enabled: boardGroupBy != null,
    staleTime: 2 * 60 * 1000,
  });
  const boardTasks = useMemo(
    () => boardQuery.data?.groups.flatMap((g) => g.items) ?? [],
    [boardQuery.data],
  );
  /** 列键 → 组总数（看板列头「还有 N 条」与角标用） */
  const boardTotals = useMemo(() => {
    const map = new Map<string, number>();
    for (const g of boardQuery.data?.groups ?? []) map.set(g.key, g.total);
    return map;
  }, [boardQuery.data]);

  // ---- Logbook 窗口（done_at 倒序增量加载）----
  const logbookFilter = useMemo<ListFilter>(
    () => ({ ...pageFilter, done: true, sort_key: "done_at", sort_dir: "desc" }),
    [pageFilter],
  );
  const logbookQuery = useInfiniteQuery({
    queryKey: ["todo_tasks", "logbook", logbookFilter],
    queryFn: ({ pageParam }) => todoTaskPage(logbookFilter, pageParam, TASK_PAGE_WINDOW),
    initialPageParam: null as ListCursor | null,
    getNextPageParam: (last) => last.next_cursor,
    enabled: logbookPagedMode,
    staleTime: 2 * 60 * 1000,
  });
  const logbookTasks = useMemo(
    () => logbookQuery.data?.pages.flatMap((p) => p.items) ?? [],
    [logbookQuery.data],
  );

  // 分页模式下两个弹窗仍需「整份集合」：打开时才拉，关闭即不占缓存
  // （周回顾要跨全部逾期/无日期/停滞；分诊要全部未分组）
  const reviewTasksQuery = useQuery({
    queryKey: ["todo_tasks", "", taskPredicate, "review-dialog"],
    queryFn: () =>
      todoTaskList({
        keyword: "",
        page: 1,
        page_size: TASK_LIST_PAGE_SIZE,
        ...taskPredicate,
      }),
    enabled: (pagedMode || boardGroupBy != null || logbookPagedMode) && reviewOpen,
    staleTime: 2 * 60 * 1000,
  });
  const triageTasksQuery = useQuery({
    queryKey: ["todo_tasks", "", "ungrouped-triage"],
    queryFn: () =>
      todoTaskList({ keyword: "", page: 1, page_size: TASK_LIST_PAGE_SIZE, ungrouped: true }),
    enabled: (pagedMode || boardGroupBy != null || logbookPagedMode) && triageOpen,
    staleTime: 2 * 60 * 1000,
  });

  // 下一页预取：React Query 在 fetching 中重复调用会排队，这里再加一道 ref 守卫
  const loadMoreLock = useRef(false);
  useEffect(() => {
    if (!pagedQuery.isFetchingNextPage) loadMoreLock.current = false;
  }, [pagedQuery.isFetchingNextPage]);
  const loadMore = useCallback(() => {
    // Logbook 走 done_at 通道，与列表分页各自持有游标
    if (logbookPagedMode) {
      if (!logbookQuery.hasNextPage || logbookQuery.isFetchingNextPage) return;
      void logbookQuery.fetchNextPage();
      return;
    }
    if (!pagedMode || !pagedQuery.hasNextPage || pagedQuery.isFetchingNextPage) return;
    if (loadMoreLock.current) return;
    loadMoreLock.current = true;
    void pagedQuery.fetchNextPage();
  }, [pagedMode, pagedQuery, logbookPagedMode, logbookQuery]);

  const visibleTasks = useMemo(() => {
    // 看板/矩阵：列内容与列内顺序都由 board 通道给定（每组前 N 条），
    // 这里只做扁平合并供组件按同一套 kanbanColumnKey 再分列
    if (boardGroupBy) return boardTasks;
    // Logbook：done_at 倒序的窗口集，分组仍由视图内按天做
    if (logbookPagedMode) return logbookTasks;
    // 分页通道：服务端已按同一套谓词过滤并排序，这里只拼接逾期置顶段。
    // 不再跑 filterTasks/sortTasks——任何本地重排都会让「翻页边界」与
    // 「视觉顺序」分叉（新一页的行插到已看过的位置上方）。
    if (pagedMode) {
      // 逾期行已由独立查询取回并置顶；分页窗口里同一行还在原位置，
      // 必须按 id 去重，否则会渲染两份（checkbox 出现两次是灾难）
      const overdue = overdueQuery.data ?? [];
      if (overdue.length === 0) return pagedTasks;
      const pinned = new Set(overdue.map((t) => t.id));
      return [...overdue, ...pagedTasks.filter((t) => !pinned.has(t.id))];
    }
    // 保存筛选器选中时：优先走条件应用（快捷视图/项目/工具栏筛选不叠加——
    // 筛选器即完整视图语义，keyword 仍作为本地搜索叠加）
    if (activeSavedFilter) {
      const labelIndex: Record<number, number[]> = {};
      for (const [tid, labels] of taskLabels) {
        labelIndex[tid] = labels.map((l) => l.id);
      }
      const filtered = applySavedFilter(
        sourceTasks.filter((t) =>
          debouncedKeyword
            ? t.title.toLowerCase().includes(debouncedKeyword.toLowerCase()) ||
              (t.description ?? "").toLowerCase().includes(debouncedKeyword.toLowerCase())
            : true,
        ),
        activeSavedFilter.conditions,
        labelIndex,
        {
          reminderTaskIds: new Set(
            [...taskReminders]
              .filter(([, rows]) => rows.length > 0)
              .map(([taskId]) => taskId),
          ),
          attachmentTaskIds,
          openSubtaskTaskIds,
        },
      );
      // 与分页通道同语义（#107）：条件与「当前列表范围（项目/未分组/工具栏
      // 状态/优先级/hideDone）」取交集——分页路径在 buildPagedFilter 里就是
      // 这么拼的。此前这里只跑条件不过滤范围，导致同一筛选器在「手动排序」
      // 与「标题排序（回落全量）」下条数与内容不同。
      return sortTasks(
        filterTasks(filtered, {
          // 快捷视图在选中筛选器时不叠加（两侧一致：buildPagedFilter 传 null）
          quickView: null,
          projectId,
          projectIds: activeProjectIds,
          ungrouped,
          statusFilter,
          priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
          hideDone,
        }),
        sortKey,
        sortDir ?? undefined,
      );
    }
    return sortTasks(
      filterTasks(
        sourceTasks.filter((t) =>
          debouncedKeyword
            ? t.title.toLowerCase().includes(debouncedKeyword.toLowerCase()) ||
              (t.description ?? "").toLowerCase().includes(debouncedKeyword.toLowerCase())
            : true,
        ),
        {
          quickView,
          projectId,
          // 清单聚合：父清单视图含全部后代清单的直接任务（口径与壳层谓词下推同源）
          projectIds: activeProjectIds,
          ungrouped,
          statusFilter,
          priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
          hideDone,
        },
      ),
      sortKey,
      sortDir ?? undefined,
    );
  }, [
    pagedMode,
    boardGroupBy,
    boardTasks,
    logbookPagedMode,
    logbookTasks,
    overdueQuery.data,
    pagedTasks,
    sourceTasks,
    debouncedKeyword,
    quickView,
    projectId,
    activeProjectIds,
    ungrouped,
    statusFilter,
    priorityFilter,
    sortKey,
    sortDir,
    activeSavedFilter,
    taskLabels,
    hideDone,
  ]);

  const errorText = (e: unknown): string | null =>
    e == null ? null : e instanceof Error ? e.message : String(e);

  // 拉取命中上限（A5）：只有真正走全量通道的视图会命中
  const anyWindowed = pagedMode || boardGroupBy != null || logbookPagedMode || calendarPagedMode;
  const listTruncated = !anyWindowed && sourceTasks.length >= TASK_LIST_PAGE_SIZE;
  const countCapped = !anyWindowed && visibleTasks.length >= TASK_LIST_PAGE_SIZE;

  // 各通道的加载/错误（全量通道继续用壳层那一份）
  const listLoading = pagedMode
    ? pagedQuery.isLoading
    : logbookPagedMode
      ? logbookQuery.isLoading
      : tasksLoading;
  const listError = pagedMode
    ? errorText(pagedQuery.error)
    : logbookPagedMode
      ? errorText(logbookQuery.error)
      : tasksError;
  const boardLoading = boardGroupBy != null ? boardQuery.isLoading : tasksLoading;
  const boardError = boardGroupBy != null ? errorText(boardQuery.error) : tasksError;
  // 「已加载 X / 共 Y」：Y 由独立聚合给（分页接口不逐页 COUNT）；
  // Logbook 的总数不可复用 overview（它不含 done 谓词），只报已加载条数
  const pagedLoaded = pagedMode ? pagedTasks.length : logbookPagedMode ? logbookTasks.length : 0;
  const pagedTotal = pagedMode ? overview?.total : undefined;

  // 完成进度线（TickTick 列表页头语义；移动端 2026-09-25 先落地，本端对齐）：
  // 只在「既有未完成又有已完成」时出现——看板/表格随隐藏开关剔除完成行、
  // Logbook 恒为完成集，进度线在这些档位只会误导（done=0 或 =全部 → 不出线）
  const doneCount = visibleTasks.reduce((n, t) => n + (t.done ? 1 : 0), 0);
  const doneProgress =
    doneCount > 0 && doneCount < visibleTasks.length ? doneCount / visibleTasks.length : null;

  // ---- 标题映射（04 §二）----
  const activeQuickDef = QUICK_VIEWS.find((v) => v.key === quickView);
  const title = activeSavedFilter
    ? activeSavedFilter.name
    : ungrouped
      ? "未分组"
      : projectId != null
        ? (projects.find((p) => p.id === projectId)?.title ?? "项目")
        : (activeQuickDef?.label ?? "全部任务");

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      {/* 工具栏（relative：底缘挂完成进度线，与 1px 描边同宽通栏） */}
      <div className="relative flex items-center justify-between gap-3 border-b px-4 py-3">
        <div className="flex items-baseline gap-2">
          <h1 className="text-lg font-semibold">{title}</h1>
          <span className="text-sm text-muted-foreground">
            {visibleTasks.length}
            {countCapped && "+"}
          </span>
        </div>

        <div className="flex items-center gap-2">
          <div className="relative">
            <Search className="absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground/60" />
            <Input
              value={keyword}
              onChange={(e) => setKeyword(e.target.value)}
              placeholder="搜索"
              className="h-8 w-40 pl-8"
            />
          </div>

          {/* 收拢双菜单（TickTick 同款，prd/desktop-toolbar-dropdown）：
              「↑↓」= 分组/排序/顺序 + 状态/优先级筛选；「···」= 视图/显示/入口类低频项 */}
          <SortMenuButton
            viewMode={viewMode}
            sortKey={sortKey}
            onSortKeyChange={setSortKey}
            sortDir={effectiveSortDir}
            onSortDirChange={setSortDir}
            kanbanGroupBy={kanbanGroupBy}
            onKanbanGroupByChange={setKanbanGroupBy}
            statusFilter={statusFilter}
            onStatusFilterChange={setStatusFilter}
            priorityFilter={priorityFilter}
            onPriorityFilterChange={setPriorityFilter}
          />
          <MoreMenuButton
            viewMode={viewMode}
            onViewModeChange={setViewMode}
            hideDone={hideDone}
            onHideDoneChange={setHideDone}
            hideDoneDisabled={isLogbook || statusFilter === "done"}
            onSaveAsView={() =>
              createSavedFilterWith(
                buildConditions(
                  toolbarToForm({
                    statusFilter,
                    priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
                    favoriteOnly: quickView === "favorite",
                  }),
                ),
              )
            }
            onOpenCommand={() => setCommandOpen(true)}
            onOpenLabels={() => setLabelManagerOpen(true)}
            onOpenReview={() => setReviewOpen(true)}
            onTriageUngrouped={() => setTriageOpen(true)}
            onPlanDay={() => setPlanDayOpen(true)}
          />

          {/* 新增按钮 */}
          <Button
            size="sm"
            className="h-8"
            onClick={() => {
              openCreateForm();
            }}
          >
            <ListTodo size={14} className="mr-1" />
            新增
          </Button>
          {/* 从模板新建（有模板才显示；套用 = payload 预填表单） */}
          {templates.length > 0 && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-8" aria-label="从模板新建">
                  <CopyPlus size={14} className="mr-1" />
                  模板
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {templates.map((t) => (
                  <DropdownMenuItem key={t.id} onClick={() => openCreateFormFromTemplate(t.id)}>
                    {t.name}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          )}

          {/* 完成进度线：工具栏底缘 2px 主题色通栏线（宽度即完成占比，
              width 过渡补间；Tooltip 走全局统一原语口径） */}
          {doneProgress != null && (
            <Tooltip>
              <TooltipTrigger asChild>
                <div
                  aria-hidden
                  className="absolute bottom-0 left-0 h-0.5 bg-primary transition-all duration-300"
                  style={{ width: `${doneProgress * 100}%` }}
                />
              </TooltipTrigger>
              <TooltipContent>
                已完成 {doneCount} / {visibleTasks.length}
              </TooltipContent>
            </Tooltip>
          )}
        </div>
      </div>

      {/* 命中上限条幅（A5）：拉取被截断时明确告知列表不完整，收窄范围后自动消失 */}
      {listTruncated && (
        <div className="flex items-center gap-1.5 border-b bg-warning/10 px-4 py-1.5 text-xs text-warning">
          <AlertTriangle className="size-3.5 shrink-0" />
          任务数超过单次加载上限 {TASK_LIST_PAGE_SIZE.toLocaleString("zh-CN")} 条，当前列表不完整——请用搜索、项目或快捷视图收窄范围
        </div>
      )}

      {/* 分页通道的增量提示（P1）：加载完即消失；「已加载 X / 共 Y」给滚动一个终点感 */}
      {pagedMode && pagedQuery.hasNextPage && (
        <div className="flex items-center gap-1.5 border-b bg-muted/40 px-4 py-1.5 text-xs text-muted-foreground">
          {pagedQuery.isFetchingNextPage
            ? "正在加载更多…"
            : `向下滚动加载更多 · 已加载 ${pagedLoaded} 条${
                pagedTotal != null ? ` / 共 ${pagedTotal} 条` : ""
              }`}
        </div>
      )}
      {/* Logbook 通道的总数不可复用 overview（后者不含 done 谓词），只报已加载 */}
      {logbookPagedMode && logbookQuery.hasNextPage && (
        <div className="flex items-center gap-1.5 border-b bg-muted/40 px-4 py-1.5 text-xs text-muted-foreground">
          {logbookQuery.isFetchingNextPage
            ? "正在加载更多…"
            : `向下滚动加载更早的完成记录 · 已加载 ${logbookTasks.length} 条`}
        </div>
      )}

      {/* 今日上下文条（G2 正反馈 + G4 容量）：今日已达成 + 今日已排/预算。
          数据源取 shell 的任务集（内存口径，与完成进度线同源）；两项皆空时自隐藏 */}
      {/* 分页模式下只算已加载窗口（窗口外的今日完成会漏计，随滚动逼近真值）；
          旧通道仍是完整结果集 */}
      <TodayStrip tasks={anyWindowed ? visibleTasks : sourceTasks} />

      {/* 内容区（flex-1 撑满，QuickAddBar 无论有无数据都固定在底部） */}
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        {isLogbook && viewMode === "list" ? (
          <LogbookView
            tasks={visibleTasks}
            projects={projects}
            projectById={new Map(projects.map((p) => [p.id, p]))}
            labelsByTask={taskLabels}
            loading={listLoading}
            onLoadMore={loadMore}
            hasMore={logbookPagedMode && logbookQuery.hasNextPage}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        ) : viewMode === "kanban" ? (
          <KanbanView
            tasks={visibleTasks}
            projects={projects}
            groupBy={kanbanGroupBy}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            sortKey={sortKey}
            loading={boardLoading}
            groupTotals={boardGroupBy ? boardTotals : undefined}
            onOpenColumnInList={(colKey) => {
              // 列满出口：能映射到工具栏筛选的档位带上条件，其余仅切列表
              if (kanbanGroupBy === "priority" && colKey.startsWith("pri:")) {
                setPriorityFilter(String(Number(colKey.slice(4))) as PriorityFilter);
              } else if (
                kanbanGroupBy === "status" &&
                (colKey === "pending" || colKey === "doing" || colKey === "done")
              ) {
                setStatusFilter(colKey);
              }
              setViewMode("list");
            }}
          />
        ) : viewMode === "calendar" ? (
          <CalendarView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            loading={tasksLoading}
            filter={pageFilter}
            rangeEnabled={calendarPagedMode}
            onCreateClick={() => {
              openCreateForm();
            }}
            onAddOnDate={openCreateFormOnDate}
          />
        ) : viewMode === "table" ? (
          <TaskTableView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            loading={listLoading}
            error={listError}
            onLoadMore={loadMore}
            hasMore={pagedMode && pagedQuery.hasNextPage}
            sortKey={sortKey}
            sortDir={effectiveSortDir}
            onSortChange={(key, dir) => {
              setSortKey(key);
              setSortDir(dir);
            }}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        ) : viewMode === "matrix" ? (
          <MatrixView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            loading={boardLoading}
            error={boardError}
            groupTotals={boardGroupBy ? boardTotals : undefined}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        ) : (
          <TaskListView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            dependenciesByTask={taskDependencies}
            loading={listLoading}
            error={listError}
            onLoadMore={loadMore}
            hasMore={pagedMode && pagedQuery.hasNextPage}
            // #26：仅拖拽顺序档显示拖拽把手
            sortable={sortKey === "manual"}
            onCreateClick={() => {
              openCreateForm();
            }}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        )}
      </div>

      {/* 底部快速输入栏；快捷视图选中时携视图标记注入（#39） */}
      <QuickAddBar
        projects={projects}
        defaultProjectId={projectId != null && !ungrouped ? projectId : null}
        quickView={
          projectId == null && !ungrouped && savedFilterId == null ? quickView : null
        }
      />

      {/* 周回顾向导（G5）：三步引导处置逾期/无日期/停滞，写路径走既有更新通道 */}
      <WeeklyReviewDialog
        open={reviewOpen}
        onOpenChange={setReviewOpen}
        tasks={pagedMode ? (reviewTasksQuery.data ?? []) : sourceTasks}
      />

      {/* 收件箱分诊（F2）：未分组任务逐条定归属；队列用全量缓存（非搜索命中集） */}
      <TriageDialog
        open={triageOpen}
        onOpenChange={setTriageOpen}
        tasks={pagedMode ? (triageTasksQuery.data ?? []) : tasks}
        projects={projects}
      />

      {/* 规划今天（F3 阶段一）：只读排程预览，不写库 */}
      <PlanDayDialog open={planDayOpen} onOpenChange={setPlanDayOpen} />
    </div>
  );
}
