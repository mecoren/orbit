/**
 * ProjectSidebar — 项目侧栏（04 文档 §3.1 复刻）
 *
 * 结构：快捷入口区（6 视图，选中才显示语义色图标）+ 项目列表区
 * （Folder 图标按项目色染色 + 名称 + 拖拽手柄，内联新增在列表尾部，
 * 右键删除，删除保护双 AlertDialog）。
 * 未分组为虚拟项（id=-1），可拖拽参与项目排序，默认项目第一位，
 * 位置持久化为「前驱项目 id」存 localStorage（LS_UNGROUPED_AFTER）。
 *
 * 窄窗折叠（07 报告 #21 接线）：useIsNarrow（<lg=1024）驱动自动折叠，
 * 用户可手动覆盖并持久化（LS_SIDEBAR_MANUAL_COLLAPSED）；折叠态渲染
 * 图标窄条（快捷视图 + 项目 Folder 图标按项目色染色），展开恢复完整三栏。
 *
 * M8 清单文件夹分组：项目按 `parent_uuid` 构成层级树（父子序、depth 缩进、
 * 有子项者带折叠箭头），孤儿/自引用/成环一律回落顶层（shared/project-tree）。
 *
 * M8+ 拖拽跨层级：横向位移即意图——右移把项目内嵌为落点行的子项、左移提升
 * 一级、位移不足则同级重排（判定在纯函数 `planProjectDrop`）；编辑弹窗的
 * 「上级文件夹」下拉仍保留，是拖拽的等价入口 + 触屏/键盘可达路径。
 */
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocation, useNavigate } from "react-router";
import { useSortable } from "@dnd-kit/sortable";
import { closestCenter, DndContext, type DragEndEvent } from "@dnd-kit/core";
import {
  SortableContext,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { Archive, ArchiveRestore, BarChart3, ChevronDown, ChevronRight, Filter, Folder, GripVertical, Inbox, PanelLeftClose, PanelLeftOpen, Plus, Trash2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import { useIsNarrow } from "@/hooks/use-breakpoint";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  todoProjectCreate,
  todoProjectDelete,
  todoProjectListArchived,
  todoProjectUpdate,
  todoProjectUpdateSortOrder,
  type TodoProject,
} from "@/lib/tauri";
import { LS_UNGROUPED_AFTER, QUICK_VIEWS, TODO_ACCENT, type QuickViewKey, PRESET_10 } from "../shared/constants";
import {
  buildFolderPathLabels,
  buildProjectTree,
  flattenProjectTree,
  normalizeParentUuid,
  parentFolderCandidates,
  planProjectDrop,
} from "../shared/project-tree";
import {
  loadSidebarManualCollapsed,
  resolveSidebarCollapsed,
  saveSidebarManualCollapsed,
} from "../shared/sidebar-collapsed";
import { ProjectContextMenu } from "./task-context-menu";

/** 未分组虚拟 id */
export const UNGROUPED_ID = -1;

/** Select 哨兵值：Radix Select 不接受空串 value，用哨兵代表「顶层」 */
const PARENT_NONE = "__none__";


interface ProjectSidebarProps {
  projects: TodoProject[];
  /** 项目 id → 未完成任务数（由父级从任务全量数据聚合，删除保护判定用） */
  undoneCounts: Record<number, number>;
  activeQuickView: QuickViewKey | null;
  activeProjectId: number | null;
  ungroupedActive: boolean;
  /** #35：保存的筛选器（侧栏分组渲染） */
  savedFilters: { id: number; name: string }[];
  activeSavedFilterId: number | null;
  onSelectQuickView: (key: QuickViewKey) => void;
  onSelectProject: (id: number) => void;
  onSelectUngrouped: () => void;
  onSelectSavedFilter: (id: number) => void;
  /** #35：新建筛选器（把当前面板的工具栏筛选存为命名视图） */
  onCreateSavedFilter: () => void;
  onDeleteSavedFilter: (id: number) => void;
}

export function ProjectSidebar({
  projects,
  undoneCounts,
  activeQuickView,
  activeProjectId,
  ungroupedActive,
  savedFilters,
  activeSavedFilterId,
  onSelectQuickView,
  onSelectProject,
  onSelectUngrouped,
  onSelectSavedFilter,
  onCreateSavedFilter,
  onDeleteSavedFilter,
}: ProjectSidebarProps) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  const [adding, setAdding] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  // 回收站/统计面板激活态（/todo/trash、/todo/stats；激活时快捷视图/项目/未分组行全部不高亮）
  const trashActive = location.pathname === "/todo/trash";
  const statsActive = location.pathname === "/todo/stats";

  // ---- 折叠态（#21）：断点自动 + 手动覆盖（语义见 shared/sidebar-collapsed）----
  const isNarrow = useIsNarrow();
  const [manualCollapsed, setManualCollapsed] = useState<boolean | null>(() =>
    loadSidebarManualCollapsed(),
  );
  const collapsed = resolveSidebarCollapsed({ isNarrow, manual: manualCollapsed });
  const toggleCollapsed = () => {
    const next = !collapsed;
    setManualCollapsed(next);
    saveSidebarManualCollapsed(next);
  };

  // 删除保护对话框状态：null 关闭；{project, hasUndone} 决定弹哪种
  const [deleteTarget, setDeleteTarget] = useState<{
    project: TodoProject;
    hasUndone: boolean;
    undoneCount?: number;
  } | null>(null);

  // 编辑项目对话框状态（#36 重命名 + 改色）：null 关闭
  const [editTarget, setEditTarget] = useState<TodoProject | null>(null);

  // ---- 归档区（展开态项目列表尾部折叠组）----
  // 归档列表独立 queryKey：db-change 表级失效只命中 ["todo-project"] 前缀,
  // 归档切换经 refetchProjects + refetchArchived 双失效
  const [archivedOpen, setArchivedOpen] = useState(false);
  const { data: archivedProjects = [] } = useQuery({
    queryKey: ["todo-project", "archived"],
    queryFn: () => todoProjectListArchived(),
    staleTime: 2 * 60 * 1000,
  });
  const refetchArchived = () =>
    qc.invalidateQueries({ queryKey: ["todo-project", "archived"] });

  /** 归档切换：is_archived 翻转；当前视图正选中该归档项目时跳走 /todo
   * （归档项目不进默认任务聚合，视图留着会看到空列表误导） */
  const toggleArchive = async (project: TodoProject) => {
    await todoProjectUpdate(project.id, {
      is_archived: project.is_archived ? 0 : 1,
    });
    if (project.is_archived === 0 && activeProjectId === project.id) navigate("/todo");
    await refetchProjects();
    await refetchArchived();
  };

  const refetchProjects = () => qc.invalidateQueries({ queryKey: ["todo-project", "list"] });

  // 回收站/统计面板激活时清空快捷视图/项目/未分组的行高亮（三选一互斥语义的扩展态）
  const effectiveQuickView = trashActive || statsActive ? null : activeQuickView;
  const effectiveProjectId = trashActive || statsActive ? null : activeProjectId;

  // ---- M8 层级树 + 折叠（文件夹分组）----
  // 折叠集合按项目 uuid 记账（会话内状态，不持久化：层级是低频操作，折叠是临时浏览动作）
  const [collapsedFolders, setCollapsedFolders] = useState<ReadonlySet<string>>(
    () => new Set<string>(),
  );
  const tree = useMemo(() => buildProjectTree(projects), [projects]);
  const flatNodes = useMemo(
    () => flattenProjectTree(tree, (uuid) => collapsedFolders.has(uuid)),
    [tree, collapsedFolders],
  );
  const nodeById = useMemo(
    () => new Map(flatNodes.map((n) => [n.project.id, n])),
    [flatNodes],
  );
  /** 渲染序列（树序展平后的可见项目 id），拖拽 items 与未分组插入位都基于它 */
  const visibleIds = useMemo(() => flatNodes.map((n) => n.project.id), [flatNodes]);

  const toggleFolder = (uuid: string) =>
    setCollapsedFolders((prev) => {
      const next = new Set(prev);
      if (next.has(uuid)) next.delete(uuid);
      else next.add(uuid);
      return next;
    });

  // ---- 组合排序：未分组（UNGROUPED_ID 占位）+ 可见项目 ----
  // 未分组位置持久化为「前驱项目 id」（空 = 最前，默认项目第一位）
  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  const orderedIds = useMemo(() => {
    const raw = localStorage.getItem(LS_UNGROUPED_AFTER);
    const afterId = raw ? Number(raw) : null;
    let idx = 0; // 默认最前
    if (afterId != null && !Number.isNaN(afterId)) {
      const at = visibleIds.indexOf(afterId);
      if (at >= 0) idx = at + 1;
    }
    const combined = [...visibleIds];
    combined.splice(idx, 0, UNGROUPED_ID);
    return combined;
  }, [visibleIds]);

  const submitNew = async () => {
    const title = newTitle.trim();
    if (!title) {
      setAdding(false);
      return;
    }
    try {
      // #36：新建项目默认色按现有项目数轮换预设板（用户可右键改色）
      const nextColor = PRESET_10[projects.length % PRESET_10.length];
      await todoProjectCreate({ title, hex_color: nextColor });
      await refetchProjects();
    } finally {
      setNewTitle("");
      setAdding(false);
    }
  };

  // 删除项目：项目下有未完成任务 → 拒绝；无任务 → 确认后进入撤销窗口软删
  const undoableDelete = useUndoableDeleteAction();
  const confirmDelete = (project: TodoProject) => {
    setDeleteTarget(null);
    if (activeProjectId === project.id) navigate("/todo");
    undoableDelete({
      entityLabel: "项目",
      recordName: project.title,
      commit: async () => {
        await todoProjectDelete(project.id);
        await refetchProjects();
      },
      hide: (qc) => hideFromQueries(qc, ["todo-project"], project.id),
    });
  };

  // 拖拽结束：可见序列 arraymove（未分组位置存 localStorage）+ 项目全局重编号落库。
  //
  // M8+ 跨层级改父：横向位移决定意图——右移 ≥ 阈值 = 内嵌为落点行的子项，
  // 左移 ≥ 阈值 = 提升一级（挂到当前父的父下），位移不足 = 同级重排。
  // 判定与顺序规划全在纯函数 `planProjectDrop`（可单测），这里只做乐观更新 +
  // 落库。编号口径改为**未折叠全量 DFS 序**（折叠是浏览态，不该影响落库结果）。
  //
  // 未分组虚拟项不参与改父（它是伪项目）：其参与的拖拽仍走可见序列编号。
  const handleDragEnd = async (event: DragEndEvent) => {
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const activeId = active.id as number;
    const overId = over.id as number;
    const oldIndex = orderedIds.indexOf(activeId);
    const newIndex = orderedIds.indexOf(overId);
    if (oldIndex < 0 || newIndex < 0) return;

    // 未分组新位置：记录前驱项目 id（无前驱 = 最前）
    const reordered = [...orderedIds];
    const [moved] = reordered.splice(oldIndex, 1);
    reordered.splice(newIndex, 0, moved);
    const ugIdx = reordered.indexOf(UNGROUPED_ID);
    const prevId = ugIdx > 0 ? reordered[ugIdx - 1] : null;
    localStorage.setItem(LS_UNGROUPED_AFTER, prevId == null ? "" : String(prevId));

    // 改父判定（未分组参与时不适用）
    const involvesUngrouped = activeId === UNGROUPED_ID || overId === UNGROUPED_ID;
    const plan = involvesUngrouped
      ? null
      : planProjectDrop({ projects, activeId, overId, deltaX: event.delta.x });

    // 新序号：改父时用全量 DFS 序；未分组参与时退回可见序列编号
    const nextOrder = new Map<number, number>();
    if (plan != null) {
      plan.order.forEach((id, i) => nextOrder.set(id, i + 1));
    } else {
      reordered
        .filter((id) => id !== UNGROUPED_ID)
        .forEach((id, i) => nextOrder.set(id, i + 1));
    }

    const activeProject = projectById.get(activeId);
    const parentChanged =
      plan != null &&
      activeProject != null &&
      normalizeParentUuid(activeProject.parent_uuid) !== plan.parentUuid;

    // 乐观更新：只按 id 覆盖 sort_order / 被拖项的 parent_uuid（M8 后列表含折叠
    // 隐藏项，整表替换会把它们从缓存里抹掉导致展开后闪空）
    qc.setQueryData<TodoProject[]>(["todo-project", "list"], (prev) =>
      prev == null
        ? prev
        : prev.map((p) => {
            const so = nextOrder.get(p.id);
            if (so == null && !(parentChanged && p.id === activeId)) return p;
            return {
              ...p,
              sort_order: so ?? p.sort_order,
              parent_uuid: parentChanged && p.id === activeId ? plan.parentUuid : p.parent_uuid,
            };
          }),
    );

    for (const [id, so] of nextOrder) {
      await todoProjectUpdateSortOrder(id, so);
    }
    // 改父单独落库（三态：null = 移到顶层）；失败由末尾 refetch 兜回原状
    if (parentChanged) {
      await todoProjectUpdate(activeId, { parent_uuid: plan.parentUuid });
    }
    void refetchProjects();
  };

  // ---- 折叠态窄条：快捷视图图标 + 项目色点 + 展开钮（hover 提示补足上下文）----
  if (collapsed) {
    return (
      <div className="flex h-full w-12 shrink-0 flex-col items-center gap-1 border-r border-border bg-card/30 py-3">
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7"
              aria-label="展开侧栏"
              onClick={toggleCollapsed}
            >
              <PanelLeftOpen className="size-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>展开侧栏</TooltipContent>
        </Tooltip>

        <div className="mt-1 flex w-full flex-col items-center gap-1">
          {QUICK_VIEWS.map((v) => {
            const active = effectiveQuickView === v.key && !ungroupedActive;
            return (
              <Tooltip key={v.key}>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={v.label}
                    onClick={() => onSelectQuickView(v.key)}
                    className={cn(
                      "flex h-8 w-8 items-center justify-center rounded-md",
                      active ? "bg-primary/10" : "hover:bg-accent/50",
                    )}
                  >
                    <v.icon className="size-4" style={active ? { color: v.color } : undefined} />
                  </button>
                </TooltipTrigger>
                <TooltipContent>{v.label}</TooltipContent>
              </Tooltip>
            );
          })}
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label="保存当前筛选"
                className="flex h-8 w-8 items-center justify-center rounded-md hover:bg-accent/50"
                onClick={onCreateSavedFilter}
              >
                <Filter className="size-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>保存当前筛选</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label="回收站"
                onClick={() => navigate("/todo/trash")}
                className={cn(
                  "flex h-8 w-8 items-center justify-center rounded-md",
                  trashActive ? "bg-primary/10" : "hover:bg-accent/50",
                )}
              >
                <Trash2 className="size-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>回收站</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label="统计"
                onClick={() => navigate("/todo/stats")}
                className={cn(
                  "flex h-8 w-8 items-center justify-center rounded-md",
                  statsActive ? "bg-primary/10" : "hover:bg-accent/50",
                )}
              >
                <BarChart3 className="size-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>统计</TooltipContent>
          </Tooltip>
        </div>

        <div className="mt-2 flex w-full flex-col items-center gap-1">
          {projects.map((p) => {
            const active = effectiveProjectId === p.id && !ungroupedActive;
            return (
              <Tooltip key={p.id}>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={p.title}
                    onClick={() => onSelectProject(p.id)}
                    className={cn(
                      "flex h-7 w-7 items-center justify-center rounded-md",
                      active ? "bg-primary/10" : "hover:bg-accent/50",
                    )}
                  >
                    <Folder
                      className="h-4 w-4"
                      style={{ color: p.hex_color || TODO_ACCENT }}
                    />
                  </button>
                </TooltipTrigger>
                <TooltipContent>
                  {p.title}
                  {undoneCounts[p.id] ? ` · ${undoneCounts[p.id]}` : ""}
                </TooltipContent>
              </Tooltip>
            );
          })}
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-full w-56 shrink-0 flex-col border-r border-border bg-card/30">
      {/* 展开态头部：折叠钮（#21 手动覆盖入口） */}
      <div className="flex items-center justify-between px-3 pt-3">
        <span className="text-xs uppercase tracking-wide text-muted-foreground">视图</span>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              className="h-6 w-6"
              aria-label="折叠侧栏"
              onClick={toggleCollapsed}
            >
              <PanelLeftClose className="size-3.5" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>折叠侧栏</TooltipContent>
        </Tooltip>
      </div>
      {/* 快捷入口区 */}
      <div className="space-y-1 p-3">
        {QUICK_VIEWS.map((v) => {
          const active = effectiveQuickView === v.key && !ungroupedActive;
          return (
            <button
              key={v.key}
              type="button"
              onClick={() => onSelectQuickView(v.key)}
              className={cn(
                "flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm",
                active ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
              )}
            >
              {/* 未选中与未分组图标同款（继承前景色），选中才显示语义色 */}
              <v.icon className="size-4" style={active ? { color: v.color } : undefined} />
              <span>{v.label}</span>
            </button>
          );
        })}
        {/* 回收站/统计（壳层嵌套路由面板，不参与快捷视图筛选状态机） */}
        <button
          type="button"
          onClick={() => navigate("/todo/trash")}
          className={cn(
            "flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm",
            trashActive ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
          )}
        >
          <Trash2 className="size-4" />
          <span>回收站</span>
        </button>
        <button
          type="button"
          onClick={() => navigate("/todo/stats")}
          className={cn(
            "flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm",
            statsActive ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
          )}
        >
          <BarChart3 className="size-4" />
          <span>统计</span>
        </button>
      </div>

      {/* #35 保存的筛选器（Apple Smart List 同款；空列表不渲染分组） */}
      {savedFilters.length > 0 && (
        <div className="px-3">
          <div className="flex items-center justify-between py-1">
            <span className="text-xs uppercase tracking-wide text-muted-foreground">筛选器</span>
          </div>
          <div className="space-y-0.5">
            {savedFilters.map((f) => {
              const active = activeSavedFilterId === f.id && !trashActive && !statsActive;
              return (
                <div
                  key={f.id}
                  className={cn(
                    "group flex w-full items-center gap-2 rounded-md px-3 py-1.5 text-sm",
                    active ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
                  )}
                >
                  <Filter className="size-3.5 shrink-0 text-muted-foreground" />
                  <button
                    type="button"
                    className="min-w-0 flex-1 truncate text-left"
                    onClick={() => onSelectSavedFilter(f.id)}
                  >
                    {f.name}
                  </button>
                  <button
                    type="button"
                    aria-label={`删除筛选器 ${f.name}`}
                    className="shrink-0 opacity-0 group-hover:opacity-100"
                    onClick={() => onDeleteSavedFilter(f.id)}
                  >
                    <Trash2 className="size-3 text-muted-foreground hover:text-destructive" />
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* 项目列表区 */}
      <div className="flex min-h-0 flex-1 flex-col px-3 pb-3">
        <div className="flex items-center justify-between py-1">
          <span className="text-xs uppercase tracking-wide text-muted-foreground">项目</span>
          <Button variant="ghost" size="icon" className="h-6 w-6" onClick={() => setAdding(true)}>
            <Plus className="size-3.5" />
          </Button>
        </div>

        <ScrollArea className="min-h-0 flex-1">
          <DndContext collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
            <SortableContext
              items={orderedIds}
              strategy={verticalListSortingStrategy}
            >
              <div className="space-y-0.5">
                {orderedIds.map((id) => {
                  if (id === UNGROUPED_ID) {
                    return (
                      <SortableUngroupedRow
                        key={id}
                        active={ungroupedActive && !trashActive && !statsActive}
                        onSelect={onSelectUngrouped}
                      />
                    );
                  }
                  const node = nodeById.get(id);
                  const project = node?.project ?? projectById.get(id);
                  if (project == null) return null;
                  const uuid = normalizeParentUuid(project.uuid);
                  const hasChildren = (node?.children.length ?? 0) > 0;
                  const isCollapsed = hasChildren && uuid != null && collapsedFolders.has(uuid);
                  return (
                    <SortableProjectRow
                      key={id}
                      project={project}
                      depth={node?.depth ?? 0}
                      hasChildren={hasChildren}
                      collapsed={isCollapsed}
                      onToggleCollapse={() => uuid != null && toggleFolder(uuid)}
                      undoneCount={undoneCounts[id] ?? 0}
                      active={effectiveProjectId === id && !ungroupedActive}
                      onSelect={() => onSelectProject(id)}
                      onRequestDelete={(hasUndone, undoneCount) => {
                        const target = projectById.get(id);
                        if (target) setDeleteTarget({ project: target, hasUndone, undoneCount });
                      }}
                      onRequestEdit={() => {
                        const target = projectById.get(id);
                        if (target) setEditTarget(target);
                      }}
                      onRequestArchive={() => {
                        const target = projectById.get(id);
                        if (target) void toggleArchive(target);
                      }}
                    />
                  );
                })}

                {/* 内联新增：输入框固定在已有项目之后 */}
                {adding && (
                  <Input
                    className="mt-0.5 h-8"
                    autoFocus
                    value={newTitle}
                    placeholder="项目名称"
                    onChange={(e) => setNewTitle(e.target.value)}
                    onBlur={submitNew}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") void submitNew();
                      if (e.key === "Escape") {
                        setNewTitle("");
                        setAdding(false);
                      }
                    }}
                  />
                )}

                {/* 归档区（有归档项目才渲染；行可点击进项目视图读任务，
                    右键取消归档回主区；非拖拽语义，不在 SortableContext 内） */}
                {archivedProjects.length > 0 && (
                  <div className="mt-1">
                    <button
                      type="button"
                      aria-expanded={archivedOpen}
                      onClick={() => setArchivedOpen((v) => !v)}
                      className="flex w-full items-center gap-2 rounded-md px-3 py-1.5 text-sm text-muted-foreground hover:bg-accent/50"
                    >
                      {archivedOpen ? (
                        <ChevronDown className="size-3.5" />
                      ) : (
                        <ChevronRight className="size-3.5" />
                      )}
                      <Archive className="size-3.5" />
                      <span>已归档</span>
                      <span className="text-xs tabular-nums">{archivedProjects.length}</span>
                    </button>
                    {archivedOpen && (
                      <div className="space-y-0.5 pl-2">
                        {archivedProjects.map((p) => (
                          <div
                            key={p.id}
                            className={cn(
                              "group flex w-full items-center gap-2 rounded-md px-3 py-1.5 text-sm",
                              effectiveProjectId === p.id
                                ? "bg-primary/10 font-medium text-primary"
                                : "hover:bg-accent/50",
                            )}
                          >
                            <Folder
                              className="h-4 w-4 shrink-0"
                              style={{ color: p.hex_color || TODO_ACCENT }}
                            />
                            <button
                              type="button"
                              className="min-w-0 flex-1 truncate text-left text-muted-foreground"
                              onClick={() => onSelectProject(p.id)}
                            >
                              {p.title}
                            </button>
                            <Tooltip>
                              <TooltipTrigger asChild>
                                <button
                                  type="button"
                                  aria-label={`取消归档 ${p.title}`}
                                  className="shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                                  onClick={() => void toggleArchive(p)}
                                >
                                  <ArchiveRestore className="size-3 text-muted-foreground hover:text-foreground" />
                                </button>
                              </TooltipTrigger>
                              <TooltipContent>取消归档</TooltipContent>
                            </Tooltip>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            </SortableContext>
          </DndContext>
        </ScrollArea>
      </div>

      {/* 删除保护双弹窗（04 §3.1） */}
      <AlertDialog
        open={deleteTarget?.hasUndone === true}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>无法删除</AlertDialogTitle>
            <AlertDialogDescription>
              该项目下还有未完成任务，请先清空或移走任务后再删除。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogAction>我知道了</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog
        open={deleteTarget != null && deleteTarget.hasUndone === false}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除项目</AlertDialogTitle>
            <AlertDialogDescription className="break-words">
              确定要删除项目「{deleteTarget?.project.title}」吗？删除后 5 秒内可撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => deleteTarget && confirmDelete(deleteTarget.project)}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* 编辑项目（#36 重命名 + 改色；M8 追加「上级文件夹」选择） */}
      <ProjectEditDialog
        project={editTarget}
        projects={projects}
        onClose={() => setEditTarget(null)}
        onSaved={() => void refetchProjects()}
      />
    </div>
  );
}

/**
 * 编辑项目对话框：名称 Input + 10 色预设板 + 上级文件夹 Select。
 * 保存 = todoProjectUpdate(title, hex_color, parent_uuid)，
 * 三个字段各自「有变化才提交」（parent_uuid 走三态：null = 移到顶层）。
 */
function ProjectEditDialog({
  project,
  projects,
  onClose,
  onSaved,
}: {
  project: TodoProject | null;
  /** 全量活跃项目：供「上级文件夹」候选计算（排除自身与后代，防成环） */
  projects: TodoProject[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [title, setTitle] = useState("");
  const [color, setColor] = useState("");
  const [parentUuid, setParentUuid] = useState<string>(PARENT_NONE);
  // 打开时装载当前项目值（key 重挂载或 open 翻转均可正确初始化）
  const [loadedFor, setLoadedFor] = useState<number | null>(null);
  if (project != null && loadedFor !== project.id) {
    setLoadedFor(project.id);
    setTitle(project.title);
    setColor(project.hex_color || PRESET_10[3]);
    setParentUuid(normalizeParentUuid(project.parent_uuid) ?? PARENT_NONE);
  }

  const selfUuid = normalizeParentUuid(project?.uuid);
  const parentOptions = useMemo(
    () =>
      parentFolderCandidates(projects, selfUuid).filter(
        (c) => normalizeParentUuid(c.uuid) != null,
      ),
    [projects, selfUuid],
  );
  const folderLabels = useMemo(
    () => buildFolderPathLabels(buildProjectTree(projects)),
    [projects],
  );

  if (project == null) return null;

  const save = async () => {
    const t = title.trim();
    if (!t) return;
    const nextParent = parentUuid === PARENT_NONE ? null : parentUuid;
    const currentParent = normalizeParentUuid(project.parent_uuid);
    try {
      await todoProjectUpdate(project.id, {
        title: t !== project.title ? t : undefined,
        hex_color: color !== project.hex_color ? color : undefined,
        parent_uuid: nextParent !== currentParent ? nextParent : undefined,
      });
      onSaved();
    } finally {
      onClose();
    }
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>编辑项目</DialogTitle>
        </DialogHeader>
        <div className="space-y-4">
          <Input
            autoFocus
            value={title}
            maxLength={50}
            placeholder="项目名称"
            onChange={(e) => setTitle(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") void save();
            }}
          />
          {/* 10 色板（与标签管理器同形制）：当前色描边圈出 */}
          <div className="flex flex-wrap items-center gap-1.5">
            {PRESET_10.map((c) => (
              <button
                key={c}
                type="button"
                aria-label={`设为 ${c}`}
                onClick={() => setColor(c)}
                className={cn(
                  "size-6 rounded-full border-2 transition-transform hover:scale-110",
                  color.toLowerCase() === c.toLowerCase()
                    ? "border-foreground"
                    : "border-transparent",
                )}
                style={{ background: c }}
              />
            ))}
          </div>
          {/* 上级文件夹：候选排除自身与后代；显示带祖先路径避免同名歧义 */}
          <div className="space-y-1.5">
            <label
              className="text-xs text-muted-foreground"
              htmlFor="project-parent-folder"
            >
              上级文件夹
            </label>
            <Select value={parentUuid} onValueChange={setParentUuid}>
              <SelectTrigger id="project-parent-folder" className="w-full">
                <SelectValue placeholder="顶层（不分组）" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={PARENT_NONE}>顶层（不分组）</SelectItem>
                {parentOptions.map((c) => (
                  <SelectItem key={c.uuid} value={c.uuid}>
                    {folderLabels.get(c.uuid) ?? c.title}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            取消
          </Button>
          <Button disabled={!title.trim()} onClick={() => void save()}>
            保存
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** 未分组虚拟项（id=-1，可拖拽参与项目排序） */
function SortableUngroupedRow({
  active,
  onSelect,
}: {
  active: boolean;
  onSelect: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({
    id: UNGROUPED_ID,
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: transform ? `translateY(${transform.y}px)` : undefined, transition }}
      className={cn(
        "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
        active
          ? "bg-primary/10 font-medium text-primary"
          : "text-sidebar-foreground hover:bg-sidebar-accent/50",
      )}
    >
      <GripVertical
        {...attributes}
        {...listeners}
        className="w-3 cursor-grab text-muted-foreground/30 opacity-0 group-hover:opacity-100"
      />
      <button
        type="button"
        onClick={onSelect}
        className="flex min-w-0 flex-1 items-center gap-2 text-left"
      >
        <Inbox className="size-4 shrink-0" />
        <span className="truncate">未分组</span>
      </button>
    </div>
  );
}

/** 单行可拖拽项目项（M8：带层级缩进与子项目折叠箭头） */
function SortableProjectRow({
  project,
  depth,
  hasChildren,
  collapsed,
  onToggleCollapse,
  undoneCount,
  active,
  onSelect,
  onRequestDelete,
  onRequestEdit,
  onRequestArchive,
}: {
  project: TodoProject;
  /** 层级深度：顶层 0，每层缩进 14px */
  depth: number;
  /** 是否有子项目（无子项目时渲染占位保持图标列对齐） */
  hasChildren: boolean;
  collapsed: boolean;
  onToggleCollapse: () => void;
  undoneCount: number;
  active: boolean;
  onSelect: () => void;
  /** 上报删除请求；hasUndone 决定弹窗类型（保护 / 确认） */
  onRequestDelete: (hasUndone: boolean, undoneCount: number) => void;
  /** 上报编辑请求（重命名/改色/改上级文件夹；#36 + M8） */
  onRequestEdit: () => void;
  /** 上报归档请求（本批新增；is_archived 翻转由父级 toggleArchive 处理） */
  onRequestArchive: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({
    id: project.id,
  });

  return (
    <div
      ref={setNodeRef}
      data-testid="project-row"
      data-uuid={project.uuid}
      data-depth={depth}
      style={{
        // 横向位移一并跟随：改层级靠横向手势表达，不给位移反馈等于没有反馈
        transform: transform
          ? `translate3d(${transform.x}px, ${transform.y}px, 0)`
          : undefined,
        transition,
        // 层级缩进用物理属性 paddingLeft（避开与 Tailwind `px-2` 的逻辑属性 padding-inline 冲突）
        paddingLeft: 8 + depth * 14,
      }}
      className={cn(
        "group flex items-center gap-2 rounded-md py-1.5 pr-2 text-sm",
        active ? "bg-primary/10 font-medium text-primary" : "hover:bg-sidebar-accent/50",
      )}
    >
      {/* 拖拽把手（title 挂外层 span：Lucide 图标不接 title 属性）：横向位移
          就是「改层级」手势，提示文案保证可发现性 */}
      <span
        title="拖动排序：向右拖成为子项，向左拖移出上一层"
        className="flex w-3 items-center"
      >
        <GripVertical
          {...attributes}
          {...listeners}
          aria-label={`拖动项目 ${project.title}`}
          className="cursor-grab text-muted-foreground/30 opacity-0 group-hover:opacity-100"
        />
      </span>
      {/* 折叠箭头：仅父节点渲染；叶子渲染等宽占位保持名称左对齐 */}
      {hasChildren ? (
        <button
          type="button"
          aria-label={`${collapsed ? "展开" : "折叠"}子项目 ${project.title}`}
          aria-expanded={!collapsed}
          onClick={(e) => {
            e.stopPropagation();
            onToggleCollapse();
          }}
          className="flex size-4 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
        >
          {collapsed ? (
            <ChevronRight className="size-3.5" />
          ) : (
            <ChevronDown className="size-3.5" />
          )}
        </button>
      ) : (
        <span className="size-4 shrink-0" aria-hidden />
      )}
      {/* 右键菜单：标题头 + 编辑项目（重命名/改色/改上级）+ 归档 + 删除（保护弹窗由父级处理） */}
      <ProjectContextMenu
        project={project}
        onRequestDelete={() => onRequestDelete(undoneCount > 0, undoneCount)}
        onRequestEdit={onRequestEdit}
        onRequestArchive={onRequestArchive}
      >
        <button
          type="button"
          onClick={onSelect}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
        >
          <Folder
            className="h-4 w-4 shrink-0"
            style={{ color: project.hex_color || TODO_ACCENT }}
          />
          <span className="truncate">{project.title}</span>
        </button>
      </ProjectContextMenu>
    </div>
  );
}
