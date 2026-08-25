/**
 * 待办列表页 —— 三栏骨架（04 文档 §二 复刻，M2 起步版）
 *
 * 左栏 ProjectSidebar / 中栏 工具栏+内容区+QuickAddBar；
 * 右侧详情抽屉与看板视图在 M2 后续任务接入（selectedTaskId 已就位）。
 * 筛选/排序/搜索语义照抄 04 §四：全量拉取 + 前端内存筛选，
 * 排序固定 position 升序 → created_at 降序。
 */
import { useEffect, useMemo, useState } from "react";
import { LayoutGrid, ListTodo, Plus, Search, Tag } from "lucide-react";
import { useQuery } from "@tanstack/react-query";

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
import { todoProjectList, todoTaskList, type TodoTask } from "@/lib/tauri";
import { LS_VIEW_MODE, QUICK_VIEWS, type QuickViewKey } from "../shared/constants";
import { filterTasks, sortTasks } from "../shared/task-filters";
import { ProjectSidebar } from "./project-sidebar";
import { TaskListView } from "./task-list-view";
import { QuickAddBar } from "./quick-add-bar";
import { TaskDetailDrawer } from "./task-detail-drawer";
import { KanbanView, type KanbanGroupBy } from "./kanban-view";
import { TaskFormSheet } from "./task-form-sheet";
import { LabelManager } from "./label-manager";

type StatusFilter = "all" | "undone" | "pending" | "doing" | "done";
type PriorityFilter = "all" | "0" | "1" | "2" | "3" | "4" | "5";

/** 视图切换状态持久化（04 §二） */
function loadViewMode(): "list" | "kanban" {
  return localStorage.getItem(LS_VIEW_MODE) === "kanban" ? "kanban" : "list";
}

export default function TodoListPage() {
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const setCommandOpen = useAppStore((s) => s.setCommandOpen);

  // ---- 选中态三选一互斥（04 §二）----
  const [quickView, setQuickView] = useState<QuickViewKey>("all");
  const [projectId, setProjectId] = useState<number | null>(null);
  const [ungrouped, setUngrouped] = useState(false);

  // ---- 工具栏状态 ----
  const [keyword, setKeyword] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [priorityFilter, setPriorityFilter] = useState<PriorityFilter>("all");
  const [viewMode, setViewMode] = useState<"list" | "kanban">(loadViewMode);
  const [kanbanGroupBy, setKanbanGroupBy] = useState<KanbanGroupBy>("project");

  // ---- 表单/标签管理状态 ----
  const [formOpen, setFormOpen] = useState(false);
  const [editingTask, setEditingTask] = useState<TodoTask | null>(null);
  const [labelManagerOpen, setLabelManagerOpen] = useState(false);

  useEffect(() => {
    localStorage.setItem(LS_VIEW_MODE, viewMode);
  }, [viewMode]);

  // ---- 数据查询（db-change 事件自动失效刷新）----
  const projectsQuery = useQuery({
    queryKey: ["todo-project", "list"],
    queryFn: () => todoProjectList({ page: 1, page_size: 1000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const tasksQuery = useQuery({
    queryKey: ["todo_tasks", keyword],
    queryFn: () => todoTaskList({ keyword, page: 1, page_size: 10000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const projects = projectsQuery.data ?? [];
  const tasks = tasksQuery.data ?? [];

  // ---- 项目未完成计数聚合（侧栏删除保护判定）----
  const undoneCounts = useMemo(() => {
    const map: Record<number, number> = {};
    for (const t of tasks as TodoTask[]) {
      if (!t.done && t.project_id != null) {
        map[t.project_id] = (map[t.project_id] ?? 0) + 1;
      }
    }
    return map;
  }, [tasks]);

  // ---- 内存筛选 + 固定排序（共享模块，语义同 04 §四）----
  // keyword 走后端查询（tasksQuery），不在此处内存过滤
  const visibleTasks = useMemo(
    () =>
      sortTasks(
        filterTasks(tasks, {
          quickView,
          projectId,
          ungrouped,
          statusFilter,
          priorityFilter: priorityFilter === "all" ? null : Number(priorityFilter),
        }),
      ),
    [tasks, quickView, projectId, ungrouped, statusFilter, priorityFilter],
  );

  // ---- 标题映射（04 §二）----
  const activeQuickDef = QUICK_VIEWS.find((v) => v.key === quickView);
  const title = ungrouped
    ? "未分组"
    : projectId != null
      ? (projects.find((p) => p.id === projectId)?.title ?? "项目")
      : (activeQuickDef?.label ?? "全部任务");

  return (
    <div className="flex h-full overflow-hidden">
      {/* 左栏 */}
      <ProjectSidebar
        projects={projects}
        undoneCounts={undoneCounts}
        activeQuickView={projectId == null && !ungrouped ? quickView : null}
        activeProjectId={projectId}
        ungroupedActive={ungrouped}
        onSelectQuickView={(key) => {
          setUngrouped(false);
          setProjectId(null);
          setQuickView(key);
        }}
        onSelectProject={(id) => {
          setUngrouped(false);
          setQuickView("all");
          setProjectId(id);
        }}
        onSelectUngrouped={() => {
          setUngrouped(true);
          setProjectId(null);
          setQuickView("all");
        }}
      />

      {/* 中栏 */}
      <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
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

            {/* 视图切换双联钮 */}
            <div className="flex items-center overflow-hidden rounded-md border">
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
            <Button
              variant="outline"
              size="icon"
              className="h-8 w-8"
              aria-label="标签管理"
              onClick={() => setLabelManagerOpen(true)}
            >
              <Tag size={14} />
            </Button>

            {/* 新增按钮 */}
            <Button
              size="sm"
              className="h-8"
              onClick={() => {
                setEditingTask(null);
                setFormOpen(true);
              }}
            >
              <Plus size={14} className="mr-1" />
              新增
            </Button>
          </div>
        </div>

        {/* 内容区（flex-1 撑满，QuickAddBar 无论有无数据都固定在底部） */}
        <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
          {viewMode === "kanban" ? (
            <KanbanView tasks={visibleTasks} projects={projects} groupBy={kanbanGroupBy} />
          ) : (
            <TaskListView
              tasks={visibleTasks}
              projects={projects}
              loading={tasksQuery.isLoading}
              error={
                tasksQuery.error instanceof Error
                  ? tasksQuery.error.message
                  : tasksQuery.error
                    ? String(tasksQuery.error)
                    : null
              }
              onCreateClick={() => {
                setEditingTask(null);
                setFormOpen(true);
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

      {/* 右侧详情抽屉（store 驱动，§7-③） */}
      <TaskDetailDrawer projects={projects} />

      {/* 新增/编辑九字段表单（04 §3.6） */}
      <TaskFormSheet
        open={formOpen}
        onOpenChange={setFormOpen}
        task={editingTask}
        projects={projects}
        defaultProjectId={projectId != null && !ungrouped ? projectId : null}
      />

      {/* 标签管理器十色板（04 §3.8） */}
      <LabelManager open={labelManagerOpen} onOpenChange={setLabelManagerOpen} />
    </div>
  );
}
