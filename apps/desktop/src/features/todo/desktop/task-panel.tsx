/**
 * 任务面板 —— /todo 主面板（04 文档 §二 中栏）
 *
 * 壳层（todo-shell）提供侧栏/选中态/查询数据/抽屉表单；本面板只管：
 * 工具栏（标题/搜索/筛选/视图切换）+ 内容区（列表/看板/日历）+ 快加栏。
 * 选中态经 useTodoShell 取用——从回收站面板切回来时筛选原样保留。
 */
import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, BookmarkPlus, CalendarDays, CopyPlus, EyeOff, LayoutGrid, ListTodo, Search, Table2, Tag } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useTodoStore } from "@/features/todo/store";
import { useAppStore } from "@/stores/app-store";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { type TodoTask } from "@/lib/tauri";
import { LS_HIDE_DONE, LS_VIEW_MODE, QUICK_VIEWS, TASK_LIST_PAGE_SIZE } from "../shared/constants";
import { useTaskLabels } from "../shared/use-task-labels";
import { useTaskReminders } from "../shared/use-task-reminders";
import { useQuery } from "@tanstack/react-query";
import { filterTasks, sortTasks, type TaskSortKey } from "../shared/task-filters";
import { applySavedFilter } from "../shared/saved-filter";
import { savedFiltersList, todoTaskList } from "@/lib/tauri";
import { useTodoShell } from "./todo-shell";
import { TaskListView } from "./task-list-view";
import { LogbookView } from "./logbook-view";
import { QuickAddBar } from "./quick-add-bar";
import { toolbarToForm, buildConditions } from "../shared/saved-filter-builder";
import { useDebouncedValue } from "../shared/use-debounced-value";
import { KanbanView, type KanbanGroupBy } from "./kanban-view";
import { CalendarView } from "./calendar-view";
import TaskTableView from "./task-table-view";

type StatusFilter = "all" | "undone" | "pending" | "doing" | "done";
type PriorityFilter = "all" | "0" | "1" | "2" | "3" | "4" | "5";
type ViewMode = "list" | "kanban" | "calendar" | "table";

/** 视图切换状态持久化（04 §二；07-P2#14 增 calendar 档） */
function loadViewMode(): ViewMode {
  const saved = localStorage.getItem(LS_VIEW_MODE);
  return saved === "kanban" || saved === "calendar" || saved === "table" ? saved : "list";
}

/** 排序档位持久化键（#26：默认 manual = 拖拽顺序） */
const LS_SORT_KEY = "todo_sort_key";

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

export default function TaskPanel() {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const setCommandOpen = useAppStore((s) => s.setCommandOpen);
  const viewToggleIntent = useAppStore((s) => s.viewToggleIntent);
  const consumeViewToggleIntent = useAppStore((s) => s.consumeViewToggleIntent);

  const {
    quickView,
    projectId,
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
  const [kanbanGroupBy, setKanbanGroupBy] = useState<KanbanGroupBy>("project");
  const [hideDone, setHideDone] = useState<boolean>(loadHideDone);

  useEffect(() => {
    localStorage.setItem(LS_VIEW_MODE, viewMode);
  }, [viewMode]);

  useEffect(() => {
    localStorage.setItem(LS_SORT_KEY, sortKey);
  }, [sortKey]);

  useEffect(() => {
    localStorage.setItem(LS_HIDE_DONE, hideDone ? "1" : "0");
  }, [hideDone]);

  useEffect(() => {
    if (viewToggleIntent === 0) return;
    setViewMode((m) => (m === "list" ? "kanban" : m === "kanban" ? "calendar" : "list"));
    consumeViewToggleIntent();
  }, [viewToggleIntent, consumeViewToggleIntent]);

  // 任务→标签映射（列表行/看板卡标签 chips 共用）
  const taskLabels = useTaskLabels();
  // 任务→提醒映射（列表行/看板卡/日历行提醒徽标共用；db-change 失效同口径）
  const taskReminders = useTaskReminders();

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
      return sortTasks(filtered, sortKey);
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
          ungrouped,
          statusFilter,
          priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
          hideDone,
        },
      ),
      sortKey,
    );
  }, [
    sourceTasks,
    debouncedKeyword,
    quickView,
    projectId,
    ungrouped,
    statusFilter,
    priorityFilter,
    sortKey,
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
      {/* 工具栏 */}
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
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

          <Select value={statusFilter} onValueChange={(v) => setStatusFilter(v as StatusFilter)}>
            <SelectTrigger className="h-8 w-28">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">全部状态</SelectItem>
              <SelectItem value="undone">未完成</SelectItem>
              <SelectItem value="pending">待办</SelectItem>
              <SelectItem value="doing">进行中</SelectItem>
              <SelectItem value="done">已完成</SelectItem>
            </SelectContent>
          </Select>

          {/* 隐藏已完成开关（Logbook 治理）：done 视图/已完成状态筛选下置灰
              （要看完成集的明确入口，开关无意义）；完成历史看侧栏「已完成」 */}
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={hideDone ? "secondary" : "ghost"}
                size="icon"
                className="h-8 w-8"
                aria-label={hideDone ? "显示已完成任务" : "隐藏已完成任务"}
                aria-pressed={hideDone}
                disabled={isLogbook || statusFilter === "done"}
                onClick={() => setHideDone((v) => !v)}
              >
                <EyeOff size={14} className={cn(!hideDone && "opacity-40")} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {hideDone ? "已完成已隐藏，点击显示" : "点击隐藏已完成任务"}
            </TooltipContent>
          </Tooltip>

          {/* 存为视图（F3）：把当前工具栏筛选一键固化为保存筛选器；
              undone 档无白名单键（构建器内自动丢弃），其余档位原样预填 */}
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8"
                aria-label="存为视图"
                onClick={() =>
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
              >
                <BookmarkPlus size={14} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>把当前筛选存为视图</TooltipContent>
          </Tooltip>

          <Select
            value={priorityFilter}
            onValueChange={(v) => setPriorityFilter(v as PriorityFilter)}
          >
            <SelectTrigger className="h-8 w-32">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">全部优先级</SelectItem>
              <SelectItem value="0">无优先级</SelectItem>
              <SelectItem value="1">低</SelectItem>
              <SelectItem value="2">中</SelectItem>
              <SelectItem value="3">高</SelectItem>
              <SelectItem value="4">紧急</SelectItem>
              <SelectItem value="5">立即处理</SelectItem>
            </SelectContent>
          </Select>

          {/* 排序档位（#26；manual = 拖拽顺序，仅该档显示拖拽把手） */}
          <Select value={sortKey} onValueChange={(v) => setSortKey(v as TaskSortKey)}>
            <SelectTrigger className="h-8 w-28" aria-label="排序方式">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="manual">拖拽顺序</SelectItem>
              <SelectItem value="due">截止时间</SelectItem>
              <SelectItem value="priority">优先级</SelectItem>
              <SelectItem value="title">标题</SelectItem>
              <SelectItem value="created">创建时间</SelectItem>
            </SelectContent>
          </Select>

          {/* 视图切换四联钮（列表/看板/日历/表格） */}
          <div className="flex items-center overflow-hidden rounded-md border">
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label="列表视图"
                  onClick={() => setViewMode("list")}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center",
                    viewMode === "list" ? "bg-primary/10 text-primary" : "hover:bg-accent",
                  )}
                >
                  <ListTodo size={14} />
                </button>
              </TooltipTrigger>
              <TooltipContent>列表视图</TooltipContent>
            </Tooltip>
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label="看板视图"
                  onClick={() => setViewMode("kanban")}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center",
                    viewMode === "kanban" ? "bg-primary/10 text-primary" : "hover:bg-accent",
                  )}
                >
                  <LayoutGrid size={14} />
                </button>
              </TooltipTrigger>
              <TooltipContent>看板视图</TooltipContent>
            </Tooltip>
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label="日历视图"
                  onClick={() => setViewMode("calendar")}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center",
                    viewMode === "calendar" ? "bg-primary/10 text-primary" : "hover:bg-accent",
                  )}
                >
                  <CalendarDays size={14} />
                </button>
              </TooltipTrigger>
              <TooltipContent>日历视图</TooltipContent>
            </Tooltip>
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label="表格视图"
                  onClick={() => setViewMode("table")}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center",
                    viewMode === "table" ? "bg-primary/10 text-primary" : "hover:bg-accent",
                  )}
                >
                  <Table2 size={14} />
                </button>
              </TooltipTrigger>
              <TooltipContent>表格视图</TooltipContent>
            </Tooltip>
          </div>

          {/* 看板模式专属：分组 Select（w-24） */}
          {viewMode === "kanban" && (
            <Select
              value={kanbanGroupBy}
              onValueChange={(v) => setKanbanGroupBy(v as KanbanGroupBy)}
            >
              <SelectTrigger className="h-8 w-24">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="project">按项目</SelectItem>
                <SelectItem value="status">按状态</SelectItem>
              </SelectContent>
            </Select>
          )}

          {/* 搜索或跳转（命令面板，Ctrl+P） */}
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="outline"
                size="icon"
                className="h-8 w-8"
                aria-label="搜索或跳转"
                onClick={() => setCommandOpen(true)}
              >
                <Search size={14} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>搜索或跳转 (Ctrl+P)</TooltipContent>
          </Tooltip>

          {/* 标签管理（h-8 w-8 Tag icon） */}
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="outline"
                size="icon"
                className="h-8 w-8"
                aria-label="标签管理"
                onClick={() => setLabelManagerOpen(true)}
              >
                <Tag size={14} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>标签管理</TooltipContent>
          </Tooltip>

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
        ) : (
          <TaskListView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            remindersByTask={taskReminders}
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
