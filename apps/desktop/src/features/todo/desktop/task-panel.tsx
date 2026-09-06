/**
 * 任务面板 —— /todo 主面板（04 文档 §二 中栏）
 *
 * 壳层（todo-shell）提供侧栏/选中态/查询数据/抽屉表单；本面板只管：
 * 工具栏（标题/搜索/筛选/视图切换）+ 内容区（列表/看板/日历）+ 快加栏。
 * 选中态经 useTodoShell 取用——从回收站面板切回来时筛选原样保留。
 */
import { useEffect, useMemo, useState } from "react";
import { CalendarDays, LayoutGrid, ListTodo, Search, Tag } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
import { LS_VIEW_MODE, QUICK_VIEWS } from "../shared/constants";
import { useTaskLabels } from "../shared/use-task-labels";
import { filterTasks, sortTasks } from "../shared/task-filters";
import { useTodoShell } from "./todo-shell";
import { TaskListView } from "./task-list-view";
import { QuickAddBar } from "./quick-add-bar";
import { KanbanView, type KanbanGroupBy } from "./kanban-view";
import { CalendarView } from "./calendar-view";

type StatusFilter = "all" | "undone" | "pending" | "doing" | "done";
type PriorityFilter = "all" | "0" | "1" | "2" | "3" | "4" | "5";
type ViewMode = "list" | "kanban" | "calendar";

/** 视图切换状态持久化（04 §二；07-P2#14 增 calendar 档） */
function loadViewMode(): ViewMode {
  const saved = localStorage.getItem(LS_VIEW_MODE);
  return saved === "kanban" || saved === "calendar" ? saved : "list";
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
    projects,
    tasks,
    tasksLoading,
    tasksError,
    openCreateForm,
    setLabelManagerOpen,
  } = useTodoShell();

  // ---- 工具栏状态（面板私有，不跨面板保留）----
  const [keyword, setKeyword] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [priorityFilter, setPriorityFilter] = useState<PriorityFilter>("all");
  const [viewMode, setViewMode] = useState<ViewMode>(loadViewMode);
  const [kanbanGroupBy, setKanbanGroupBy] = useState<KanbanGroupBy>("project");

  useEffect(() => {
    localStorage.setItem(LS_VIEW_MODE, viewMode);
  }, [viewMode]);

  useEffect(() => {
    if (viewToggleIntent === 0) return;
    setViewMode((m) => (m === "list" ? "kanban" : m === "kanban" ? "calendar" : "list"));
    consumeViewToggleIntent();
  }, [viewToggleIntent, consumeViewToggleIntent]);

  // 任务→标签映射（列表行/看板卡标签 chips 共用）
  const taskLabels = useTaskLabels();

  // ---- 内存筛选 + 固定排序（共享模块，语义同 04 §四）----
  // keyword 在面板内客户端过滤（全量数据由壳层提供）
  const visibleTasks = useMemo(
    () =>
      sortTasks(
        filterTasks(
          (tasks as TodoTask[]).filter((t) =>
            keyword
              ? t.title.toLowerCase().includes(keyword.toLowerCase()) ||
                (t.description ?? "").toLowerCase().includes(keyword.toLowerCase())
              : true,
          ),
          {
            quickView,
            projectId,
            ungrouped,
            statusFilter,
            priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
          },
        ),
      ),
    [tasks, keyword, quickView, projectId, ungrouped, statusFilter, priorityFilter],
  );

  // ---- 标题映射（04 §二）----
  const activeQuickDef = QUICK_VIEWS.find((v) => v.key === quickView);
  const title = ungrouped
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
          <span className="text-sm text-muted-foreground">{visibleTasks.length}</span>
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

          {/* 视图切换三联钮（列表/看板/日历） */}
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
        </div>
      </div>

      {/* 内容区（flex-1 撑满，QuickAddBar 无论有无数据都固定在底部） */}
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        {viewMode === "kanban" ? (
          <KanbanView
            tasks={visibleTasks}
            projects={projects}
            groupBy={kanbanGroupBy}
            labelsByTask={taskLabels}
          />
        ) : viewMode === "calendar" ? (
          <CalendarView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            onCreateClick={() => {
              openCreateForm();
            }}
          />
        ) : (
          <TaskListView
            tasks={visibleTasks}
            projects={projects}
            labelsByTask={taskLabels}
            loading={tasksLoading}
            error={tasksError}
            onCreateClick={() => {
              openCreateForm();
            }}
            onOpenDetail={(id) => setSelectedTaskId(id)}
          />
        )}
      </div>

      {/* 底部快速输入栏 */}
      <QuickAddBar
        projects={projects}
        defaultProjectId={projectId != null && !ungrouped ? projectId : null}
      />
    </div>
  );
}
