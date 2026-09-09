/**
 * 待办壳层 —— 三栏骨架的左右持久层（04 文档 §二）
 *
 * 路由结构（07 报告 #3 回收站落地起）：
 * ```text
 * /todo          → TodoShell（本文件：侧栏 + 选中态 + 抽屉/表单/撤销 Provider）
 *    ├ index    → TaskPanel（任务面板：工具栏 + 列表/看板/日历 + 快加栏）
 *    └ trash    → TrashPanel（回收站面板）
 * ```
 * 壳层职责：跨面板持久的状态（quickView/projectId/ungrouped 选中三选一、
 * 详情抽屉、新建/编辑表单、撤销 Provider、标签管理器）与数据查询
 * （项目/任务全量，两端面板共用）；面板只管自己的中间区内容。
 * 选中态放壳层 → 从任务面板进回收站再返回，筛选状态原样保留。
 * 选中入口（快捷视图/项目/未分组）点击只改壳层 state，仅 TaskPanel 消费；
 * 停在 trash/stats 子面板时点击须先导航回 /todo（selectInPanel 兜底，
 * 2026-09-08 修复：此前 state 静默变化、界面无反应）。
 */
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Outlet, useLocation, useNavigate } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import { UndoableDeleteProvider } from "@/hooks/use-undoable-delete";
import { useAppStore } from "@/stores/app-store";
import {
  savedFilterCreate,
  savedFilterDelete,
  savedFiltersList,
  todoProjectList,
  todoTaskList,
  type TodoProject,
  type TodoTask,
} from "@/lib/tauri";
import { type QuickViewKey } from "../shared/constants";
import { needsTodoIndexNav, TODO_INDEX_PATH } from "../shared/sidebar-nav";
import { ProjectSidebar } from "./project-sidebar";
import { TaskDetailDrawer } from "./task-detail-drawer";
import { TaskFormSheet } from "./task-form-sheet";
import { LabelManager } from "./label-manager";

/**
 * 壳层上下文：任务面板与回收站面板共享的选中态与查询数据。
 * （面板间通信面很小，Context 比提全局 store 轻量；TodoShell 内单 Provider。）
 */
interface TodoShellContextValue {
  // ---- 选中态四选一互斥（04 §二；跨面板保留；#35 增筛选器）----
  quickView: QuickViewKey;
  projectId: number | null;
  ungrouped: boolean;
  /** 保存的筛选器选中 id（#35；null = 未选中筛选器） */
  savedFilterId: number | null;
  onSelectQuickView: (key: QuickViewKey) => void;
  onSelectProject: (id: number) => void;
  onSelectUngrouped: () => void;
  onSelectSavedFilter: (id: number) => void;
  /** 选中项目 id（表单默认项目用；null = 无选中/未分组） */
  activeProjectId: number | null;

  // ---- 共享查询数据 ----
  projects: TodoProject[];
  tasks: TodoTask[];
  /** 任务全量查询加载中（面板空态/骨架用） */
  tasksLoading: boolean;
  /** 任务全量查询错误文案（仅无任何数据时的整块失败才非 null） */
  tasksError: string | null;

  // ---- 表单/标签管理（壳层挂载的弹层，面板只触发）----
  formOpen: boolean;
  setFormOpen: (open: boolean) => void;
  editingTask: TodoTask | null;
  setEditingTask: (t: TodoTask | null) => void;
  openCreateForm: () => void;
  /** 以指定截止日期打开新增表单（日历视图右键日格快捷新增） */
  openCreateFormOnDate: (dueDate: string) => void;
  labelManagerOpen: boolean;
  setLabelManagerOpen: (open: boolean) => void;
}

const TodoShellContext = createContext<TodoShellContextValue | null>(null);

/** 面板取壳层上下文（任务面板/回收站面板共用） */
export function useTodoShell() {
  const ctx = useContext(TodoShellContext);
  if (!ctx) throw new Error("useTodoShell must be used within TodoShell");
  return ctx;
}

export default function TodoShell() {
  const taskFormIntent = useAppStore((s) => s.taskFormIntent);
  const consumeTaskFormIntent = useAppStore((s) => s.consumeTaskFormIntent);
  const navigate = useNavigate();
  const { pathname } = useLocation();

  // ---- 选中态三选一互斥（04 §二）----
  const [quickView, setQuickView] = useState<QuickViewKey>("all");
  const [projectId, setProjectId] = useState<number | null>(null);
  const [ungrouped, setUngrouped] = useState(false);
  // #35：保存的筛选器选中态（与三选一互斥）
  const [savedFilterId, setSavedFilterId] = useState<number | null>(null);

  // ---- 表单/标签管理状态（壳层持久，面板触发）----
  const [formOpen, setFormOpen] = useState(false);
  const [editingTask, setEditingTask] = useState<TodoTask | null>(null);
  // 新增表单预填的截止日期（日历右键日格注入；空 = 不预填）
  const [presetDueDate, setPresetDueDate] = useState<string | null>(null);
  const [labelManagerOpen, setLabelManagerOpen] = useState(false);

  // 壳层命令面板的动作意图（07 §五-P1#8）：消费即归零（评审 C1）——
  // 防止历史意图在页面重挂载时被重放；0 视为无待处理意图
  useEffect(() => {
    if (taskFormIntent === 0) return;
    setEditingTask(null);
    setFormOpen(true);
    consumeTaskFormIntent();
  }, [taskFormIntent, consumeTaskFormIntent]);

  // ---- 数据查询（db-change 事件自动失效刷新；面板共用）----
  const projectsQuery = useQuery({
    queryKey: ["todo-project", "list"],
    queryFn: () => todoProjectList({ page: 1, page_size: 1000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const tasksQuery = useQuery({
    queryKey: ["todo_tasks", ""],
    queryFn: () => todoTaskList({ keyword: "", page: 1, page_size: 10000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const projects = projectsQuery.data ?? [];
  const tasks = tasksQuery.data ?? [];

  // #35 保存的筛选器（db-change 自动失效；侧栏分组 + 面板过滤共用）
  const savedFiltersQuery = useQuery({
    queryKey: ["saved-filters", "list"],
    queryFn: () => savedFiltersList(),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const savedFilters = savedFiltersQuery.data ?? [];
  const queryClient = useQueryClient();
  const invalidateFilters = () =>
    queryClient.invalidateQueries({ queryKey: ["saved-filters"] });
  // 新建入口由面板触发（把当前工具栏筛选存为命名视图——面板传条件 JSON）：
  // 壳层挂载弹层与提交，条件经 appStore 意图通道传递过重，这里走简单回调注册
  const [savedFilterDraft, setSavedFilterDraft] = useState<{
    name: string;
    conditions: string;
  } | null>(null);
  const handleCreateSavedFilter = async () => {
    if (!savedFilterDraft) return;
    try {
      await savedFilterCreate({
        name: savedFilterDraft.name,
        conditions: savedFilterDraft.conditions,
      });
      invalidateFilters();
    } finally {
      setSavedFilterDraft(null);
    }
  };
  const handleDeleteSavedFilter = async (id: number) => {
    await savedFilterDelete(id);
    if (savedFilterId === id) setSavedFilterId(null);
    invalidateFilters();
  };
  // 仅"无任何数据"的失败才整块替换；后台 refetch 失败时保留旧数据展示
  // （placeholderData 语义），避免瞬时 IPC 失败清掉可见列表
  const tasksError =
    tasksQuery.isError && tasks.length === 0
      ? tasksQuery.error instanceof Error
        ? tasksQuery.error.message
        : String(tasksQuery.error)
      : null;

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

  // 选中入口点击改的是壳层 state，只有 TaskPanel（/todo index）消费它；
  // 停在 trash/stats 子面板时须先导航回 /todo，否则点击静默无反应
  // （2026-09-08 用户报告：回收站/统计下点侧边栏菜单失灵）
  const selectInPanel = () => {
    if (needsTodoIndexNav(pathname)) navigate(TODO_INDEX_PATH);
  };
  const ctx: TodoShellContextValue = {
    quickView,
    projectId,
    ungrouped,
    savedFilterId,
    onSelectQuickView: (key) => {
      selectInPanel();
      setUngrouped(false);
      setProjectId(null);
      setSavedFilterId(null);
      setQuickView(key);
    },
    onSelectSavedFilter: (id) => {
      selectInPanel();
      setUngrouped(false);
      setProjectId(null);
      setSavedFilterId(id);
    },
    onSelectProject: (id) => {
      setSavedFilterId(null);
      selectInPanel();
      setUngrouped(false);
      setQuickView("all");
      setProjectId(id);
    },
    onSelectUngrouped: () => {
      setSavedFilterId(null);
      selectInPanel();
      setUngrouped(true);
      setProjectId(null);
      setQuickView("all");
    },
    activeProjectId: projectId != null && !ungrouped ? projectId : null,
    projects,
    tasks,
    tasksLoading: tasksQuery.isLoading,
    tasksError,
    formOpen,
    setFormOpen,
    editingTask,
    setEditingTask,
    openCreateForm: () => {
      setEditingTask(null);
      setPresetDueDate(null);
      setFormOpen(true);
    },
    openCreateFormOnDate: (dueDate: string) => {
      setEditingTask(null);
      setPresetDueDate(dueDate);
      setFormOpen(true);
    },
    labelManagerOpen,
    setLabelManagerOpen,
  };

  return (
    <TodoShellContext.Provider value={ctx}>
      <UndoableDeleteProvider>
        <div className="flex h-full overflow-hidden">
          {/* 左栏（跨面板常驻） */}
          <ProjectSidebar
            projects={projects}
            undoneCounts={undoneCounts}
            activeQuickView={projectId == null && !ungrouped && savedFilterId == null ? quickView : null}
            activeProjectId={projectId}
            ungroupedActive={ungrouped}
            savedFilters={savedFilters}
            activeSavedFilterId={savedFilterId}
            onSelectQuickView={ctx.onSelectQuickView}
            onSelectProject={ctx.onSelectProject}
            onSelectUngrouped={ctx.onSelectUngrouped}
            onSelectSavedFilter={ctx.onSelectSavedFilter}
            onCreateSavedFilter={() => setSavedFilterDraft({ name: "", conditions: "{}" })}
            onDeleteSavedFilter={handleDeleteSavedFilter}
          />

          {/* 中间区：路由出口（任务面板 / 回收站面板） */}
          <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
            <Outlet />
          </div>

          {/* 右侧详情抽屉（store 驱动，§7-③；跨面板常驻） */}
          <TaskDetailDrawer projects={projects} />

          {/* 新增/编辑九字段表单（04 §3.6）；presetDueDate = 日历右键预填截止日期；
              quickView = 当前选中快捷视图（#39 视图内新建自动带标记；仅创建分支消费） */}
          <TaskFormSheet
            open={formOpen}
            onOpenChange={setFormOpen}
            task={editingTask}
            projects={projects}
            defaultProjectId={ctx.activeProjectId}
            presetDueDate={editingTask ? null : presetDueDate}
            quickView={
              projectId == null && !ungrouped && savedFilterId == null ? quickView : null
            }
          />

          {/* #35 新建筛选器弹层（名称 + 条件 JSON） */}
          <Dialog
            open={savedFilterDraft != null}
            onOpenChange={(o) => !o && setSavedFilterDraft(null)}
          >
            <DialogContent className="max-w-sm">
              <DialogHeader>
                <DialogTitle>保存筛选器</DialogTitle>
              </DialogHeader>
              <Input
                autoFocus
                placeholder="筛选器名称（如：本周 P0）"
                value={savedFilterDraft?.name ?? ""}
                onChange={(e) =>
                  setSavedFilterDraft((d) => (d ? { ...d, name: e.target.value } : d))
                }
              />
              <Input
                placeholder='条件 JSON（如 {"priority_min":4,"due_within_days":7}）'
                className="font-mono text-xs"
                value={savedFilterDraft?.conditions ?? "{}"}
                onChange={(e) =>
                  setSavedFilterDraft((d) => (d ? { ...d, conditions: e.target.value } : d))
                }
              />
              <DialogFooter>
                <Button variant="ghost" onClick={() => setSavedFilterDraft(null)}>
                  取消
                </Button>
                <Button
                  disabled={!savedFilterDraft?.name.trim()}
                  onClick={() => void handleCreateSavedFilter()}
                >
                  保存
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>

          {/* 标签管理器十色板（04 §3.8） */}
          <LabelManager open={labelManagerOpen} onOpenChange={setLabelManagerOpen} />
        </div>
      </UndoableDeleteProvider>
    </TodoShellContext.Provider>
  );
}
