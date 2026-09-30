/**
 * 任务面板 —— /todo 主面板（04 文档 §二 中栏）
 *
 * 壳层（todo-shell）提供侧栏/选中态/查询数据/抽屉表单；本面板只管：
 * 工具栏（标题/搜索/筛选/视图切换）+ 内容区（列表/看板/日历）+ 快加栏。
 * 选中态经 useTodoShell 取用——从回收站面板切回来时筛选原样保留。
 */
import { useEffect, useMemo, useState } from "react";
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
import { type TodoTask } from "@/lib/tauri";
import { LS_HIDE_DONE, LS_VIEW_MODE, QUICK_VIEWS, TASK_LIST_PAGE_SIZE } from "../shared/constants";
import { useTaskDependencies } from "../shared/use-task-dependencies";
import { useTaskLabels } from "../shared/use-task-labels";
import { useTaskReminders } from "../shared/use-task-reminders";
import { useQuery } from "@tanstack/react-query";
import { filterTasks, sortTasks, BASE_SORT_DIR, type TaskSortDir, type TaskSortKey } from "../shared/task-filters";
import { applySavedFilter } from "../shared/saved-filter";
import { savedFiltersList, todoTaskList } from "@/lib/tauri";
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

type StatusFilter = "all" | "undone" | "pending" | "doing" | "done";
type PriorityFilter = "all" | "0" | "1" | "2" | "3" | "4" | "5";
/** 五档视图（矩阵 = 四象限 Eisenhower Matrix，TickTick 同款；2026-09-25 与移动端对齐） */
export type ViewMode = "list" | "kanban" | "calendar" | "table" | "matrix";
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
    openCreateForm,
    openCreateFormOnDate,
    openCreateFormFromTemplate,
    templates,
    setLabelManagerOpen,
    createSavedFilterWith,
  } = useTodoShell();

  // ---- 工具栏状态（面板私有，不跨面板保留）----
  const [keyword, setKeyword] = useState("");
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

  const visibleTasks = useMemo(() => {
    // 保存筛选器选中时：优先走条件应用（快捷视图/项目/工具栏筛选不叠加——
    // 筛选器即完整视图语义，keyword 仍作为本地搜索叠加）
    if (activeSavedFilter) {
      const labelIndex: Record<number, number[]> = {};
      for (const [tid, labels] of taskLabels) {
        labelIndex[tid] = labels.map((l) => l.id);
      }
      const filtered = applySavedFilter(
        (sourceTasks as TodoTask[]).filter((t) =>
          debouncedKeyword
            ? t.title.toLowerCase().includes(debouncedKeyword.toLowerCase()) ||
              (t.description ?? "").toLowerCase().includes(debouncedKeyword.toLowerCase())
            : true,
        ),
        activeSavedFilter.conditions,
        labelIndex,
      );
      return sortTasks(filtered, sortKey, sortDir ?? undefined);
    }
    return sortTasks(
      filterTasks(
        (sourceTasks as TodoTask[]).filter((t) =>
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

  // 拉取命中上限（A5）：壳层/搜索通道单次最多取 TASK_LIST_PAGE_SIZE 条，命中
  // 即意味着还有未取到的任务。条幅按**当前取数源**判定（搜索时是服务端命中集，
  // 关键词命中上万条同样是截断），计数后缀「+」只在该视图真的显示到上限时出现
  // ——否则筛出 2 条也写「2+」反而读不通。静默少显示比显示慢更糟。
  const listTruncated = sourceTasks.length >= TASK_LIST_PAGE_SIZE;
  const countCapped = visibleTasks.length >= TASK_LIST_PAGE_SIZE;

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

      {/* 内容区（flex-1 撑满，QuickAddBar 无论有无数据都固定在底部） */}
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        {isLogbook && viewMode === "list" ? (
          <LogbookView
            tasks={visibleTasks}
            projects={projects}
            projectById={new Map(projects.map((p) => [p.id, p]))}
            labelsByTask={taskLabels}
            loading={tasksLoading}
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
            loading={tasksLoading}
          />
        ) : viewMode === "calendar" ? (
          <CalendarView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            loading={tasksLoading}
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
            loading={tasksLoading}
            error={tasksError}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        ) : viewMode === "matrix" ? (
          <MatrixView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            loading={tasksLoading}
            error={tasksError}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        ) : (
          <TaskListView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
            dependenciesByTask={taskDependencies}
            loading={tasksLoading}
            error={tasksError}
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
    </div>
  );
}
