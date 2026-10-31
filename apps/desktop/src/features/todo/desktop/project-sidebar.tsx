/**
 * ProjectSidebar — 项目侧栏（04 文档 §3.1 复刻）
 *
 * 结构：快捷入口区（6 视图，选中才显示语义色图标）+ 项目列表区
 * （Folder 图标按项目色染色 + 名称，内联新增在列表尾部，
 * 右键菜单内联确认归档/删除——不收起菜单，未完成任务时删除只告知）。
 * 未分组为虚拟项（id=-1），可拖拽参与项目排序，默认项目第一位，
 * 位置持久化为「前驱项目 id」存 localStorage（LS_UNGROUPED_AFTER）。
 *
 * 窄窗折叠（07 报告 #21 接线）：useIsNarrow（<lg=1024）驱动自动折叠，
 * 用户可手动覆盖并持久化（LS_SIDEBAR_MANUAL_COLLAPSED）；折叠态渲染
 * 图标窄条（快捷视图 + 未分组 Inbox + 项目 Folder 图标按项目色染色），展开恢复完整三栏。
 *
 * M8 清单文件夹分组：项目按 `parent_uuid` 构成层级树（父子序、depth 缩进、
 * 有子项者带折叠箭头），孤儿/自引用/成环一律回落顶层（shared/project-tree）。
 *
 * M8+ 拖拽跨层级：横向位移即意图——右移把项目内嵌为落点行的子项、左移提升
 * 一级、位移不足则同级重排（判定在纯函数 `planProjectDrop`）；编辑弹窗的
 * 「上级文件夹」下拉仍保留，是拖拽的等价入口 + 触屏/键盘可达路径。
 * 拖拽无把手：整行长按 250ms 激活（PointerSensor delay 约束），短击仍是选中。
 */
import { useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocation, useNavigate } from "react-router";
import { useSortable } from "@dnd-kit/sortable";
import { toast } from "sonner";
import {
  closestCenter,
  DndContext,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import {
  SortableContext,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { Archive, ArchiveRestore, BarChart3, CalendarCheck, ChevronDown, ChevronRight, Filter, Folder, FolderInput, Inbox, PanelLeftClose, PanelLeftOpen, Pencil, Plus, Trash2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { useAppStore } from "@/stores/app-store";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import { useIsNarrow } from "@/hooks/use-breakpoint";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
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
  todoProjectSetReviewInterval,
  todoProjectsDueForReview,
  todoProjectUpdate,
  todoProjectUpdateSortOrder,
  type TodoProject,
} from "@/lib/tauri";
import { LS_UNGROUPED_AFTER, QUICK_VIEWS, TODO_ACCENT, type QuickViewKey, PRESET_10 } from "../shared/constants";
import type { QuickViewCounts } from "../shared/sidebar-counts";
import { REVIEW_INTERVAL_PRESETS, REVIEW_OFF } from "../shared/project-review";
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
import { ConfirmPopover } from "../shared/confirm-popover";

/** 未分组虚拟 id */
export const UNGROUPED_ID = -1;

/** Select 哨兵值：Radix Select 不接受空串 value，用哨兵代表「顶层」 */
const PARENT_NONE = "__none__";


interface ProjectSidebarProps {
  projects: TodoProject[];
  /** 项目 id → 未完成任务数（由父级从任务全量数据聚合，删除保护判定用） */
  undoneCounts: Record<number, number>;
  /** 快捷视图 → 角标计数（壳层 SQL 聚合；未就绪时行尾不渲染数字） */
  quickViewCounts?: QuickViewCounts;
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
  /** #107：编辑既有筛选器（改名 / 改条件） */
  onEditSavedFilter: (id: number) => void;
  onDeleteSavedFilter: (id: number) => void;
}

export function ProjectSidebar({
  projects,
  undoneCounts,
  quickViewCounts,
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
  onEditSavedFilter,
  onDeleteSavedFilter,
}: ProjectSidebarProps) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  // 收件箱分诊（F2）：未分组行入口经意图计数器传到 task-panel 的弹窗
  const bumpTriageIntent = useAppStore((s) => s.bumpTriageIntent);
  const [adding, setAdding] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  // 回收站/统计/回顾面板激活态（/todo/trash、/todo/stats、/todo/review；
  // 激活时快捷视图/项目/未分组行全部不高亮）
  const trashActive = location.pathname === "/todo/trash";
  const statsActive = location.pathname === "/todo/stats";
  const reviewActive = location.pathname === "/todo/review";

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

  // 编辑项目对话框状态（#36 重命名 + 改色）：null 关闭
  const [editTarget, setEditTarget] = useState<TodoProject | null>(null);

  // 筛选器删除确认（行内小弹框，锚定在删除钮旁）：null 关闭。
  // 侧栏行只有 3px 图标，误点即删（软删且无回收站入口），故先出一层轻量确认。
  const [confirmDeleteFilterId, setConfirmDeleteFilterId] = useState<number | null>(null);

  // ---- 归档区（展开态项目列表尾部折叠组）----
  // 归档列表独立 queryKey：db-change 表级失效只命中 ["todo-project"] 前缀,
  // 归档切换经 refetchProjects + refetchArchived 双失效
  const [archivedOpen, setArchivedOpen] = useState(false);
  // 取消归档确认（行内小弹框，锚定归档区的恢复钮）：与正向归档确认同形制
  const [confirmUnarchiveId, setConfirmUnarchiveId] = useState<number | null>(null);
  const { data: archivedProjects = [] } = useQuery({
    queryKey: ["todo-project", "archived"],
    queryFn: () => todoProjectListArchived(),
    staleTime: 2 * 60 * 1000,
  });
  const refetchArchived = () =>
    qc.invalidateQueries({ queryKey: ["todo-project", "archived"] });

  // ---- 待回顾徽标（F1）：到期项目 id 集（判定真值在 core，前端只渲染点）----
  const { data: reviewDue = [] } = useQuery({
    queryKey: ["todo-project", "review-due"],
    queryFn: () => todoProjectsDueForReview(Date.now()),
    staleTime: 60 * 1000,
  });
  const reviewDueIds = useMemo(
    () => new Set(reviewDue.map((s) => s.project.id)),
    [reviewDue],
  );

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

  // 回收站/统计/回顾面板激活时清空快捷视图/项目/未分组的行高亮（互斥语义的扩展态）
  const effectiveQuickView = trashActive || statsActive || reviewActive ? null : activeQuickView;
  const effectiveProjectId = trashActive || statsActive || reviewActive ? null : activeProjectId;

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

  // 同步锁防连按 Enter / 双击「新建」建出两个同名项目（ref 不经过渲染，
  // 同一帧内连触两次也挡得住）
  const newProjectLock = useRef(false);
  const submitNew = async () => {
    const title = newTitle.trim();
    if (!title) {
      setAdding(false);
      return;
    }
    if (newProjectLock.current) return;
    newProjectLock.current = true;
    try {
      // #36：新建项目默认色按现有项目数轮换预设板（用户可右键改色）
      const nextColor = PRESET_10[projects.length % PRESET_10.length];
      await todoProjectCreate({ title, hex_color: nextColor });
      await refetchProjects();
      setNewTitle("");
      setAdding(false);
    } catch (e) {
      // 失败保留输入框与草稿，用户可直接重试
      toast.error(`新建项目失败：${e instanceof Error ? e.message : String(e)}`);
    } finally {
      newProjectLock.current = false;
    }
  };

  // 删除项目：无任务 → 菜单内确认后进入撤销窗口软删（未完成任务拦截在菜单
  // 确认区里做——见 ProjectContextMenu 的 undoneCount 分支）
  const undoableDelete = useUndoableDeleteAction();
  const confirmDelete = (project: TodoProject) => {
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

  // 整行长按拖拽（无把手）：静止按住 250ms 才起拖，期间位移超 8px 视为
  // 滚动/误触取消，短击不受影响（点击仍走选中）。只注册 PointerSensor——
  // 默认传感器里的 KeyboardSensor 以 Space/Enter 起拖且行即 activator 时
  // 不校验事件 target，会抢走内层按钮的键盘激活。
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { delay: 250, tolerance: 8 } }),
  );

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
      // 整栏统一滚动（2026-10-10）：小窗高度下窄条内容同样溢出被裁，根列即滚动容器，
      // 原生滚动条走全局标准常显可见（禁 scrollbar-width 非 auto 值）
      <nav
        aria-label="侧栏导航"
        className="flex h-full w-12 shrink-0 flex-col items-center gap-1 overflow-y-auto border-r border-border bg-card/30 py-3"
      >
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
            const count = quickViewCounts?.[v.key] ?? 0;
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
                <TooltipContent>
                  {v.label}
                  {count > 0 ? ` · ${count}` : ""}
                </TooltipContent>
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
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label="回顾"
                onClick={() => navigate("/todo/review")}
                className={cn(
                  "relative flex h-8 w-8 items-center justify-center rounded-md",
                  reviewActive ? "bg-primary/10" : "hover:bg-accent/50",
                )}
              >
                <CalendarCheck className="size-4" />
                {reviewDue.length > 0 && (
                  <span className="absolute right-1 top-1 size-1.5 rounded-full bg-warning" />
                )}
              </button>
            </TooltipTrigger>
            <TooltipContent>回顾{reviewDue.length > 0 ? ` · 待回顾 ${reviewDue.length}` : ""}</TooltipContent>
          </Tooltip>
        </div>

        <div className="mt-2 flex w-full flex-col items-center gap-1">
          {/* 未分组（虚拟项）在折叠窄条同样保留入口（组首，与展开态默认位置一致） */}
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label="未分组"
                onClick={onSelectUngrouped}
                className={cn(
                  "flex h-7 w-7 items-center justify-center rounded-md",
                  ungroupedActive && !trashActive && !statsActive && !reviewActive
                    ? "bg-primary/10"
                    : "hover:bg-accent/50",
                )}
              >
                <Inbox className="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>未分组</TooltipContent>
          </Tooltip>
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
      </nav>
    );
  }

  return (
    // 整栏统一滚动（2026-10-10）：快捷入口 + 筛选器 + 项目列表同一条滚动列，根列即
    // 滚动容器、原生滚动条走全局标准常显可见。旧结构快捷入口区不可收缩，小窗高度下会把
    // 项目区挤到 0 高（723×378 实测 viewport 0px、30 个项目行全部不可达），项目列表里的
    // Radix ScrollArea 滚动条又是 hover 才渲染的悬浮条——用户感知「没有滑动条」。
    // 取舍：「项目 +」标题与顶部「视图」头随内容滚走（不再钉住）。
    <nav
      aria-label="侧栏导航"
      className="flex h-full w-56 shrink-0 flex-col overflow-y-auto border-r border-border bg-card/30"
    >
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
          const count = quickViewCounts?.[v.key] ?? 0;
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
              {/* 行尾计数（参考 TickTick 版式：纯灰数字不占常态视觉）；aria-hidden
                  保住按钮可访问名恰为视图名（e2e 的 exact 匹配依赖它）。
                  贴行右缘，与项目区同一条计数竖线（项目区的尾部图标排在数字左侧） */}
              {count > 0 && (
                <span
                  aria-hidden="true"
                  className="ml-auto text-xs tabular-nums text-muted-foreground"
                >
                  {count}
                </span>
              )}
            </button>
          );
        })}
        {/* 回收站/统计/回顾（壳层嵌套路由面板，不参与快捷视图筛选状态机） */}
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
        {/* 回顾中心（F1 项目回顾节奏）：到期时右侧给计数徽标提示 */}
        <button
          type="button"
          onClick={() => navigate("/todo/review")}
          className={cn(
            "flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm",
            reviewActive ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
          )}
        >
          <CalendarCheck className="size-4" />
          <span>回顾</span>
          {reviewDue.length > 0 && (
            <span className="ml-auto rounded-md bg-warning/15 px-1.5 py-0.5 text-xs tabular-nums text-warning">
              {reviewDue.length}
            </span>
          )}
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
                    aria-label={`编辑筛选器 ${f.name}`}
                    className="shrink-0 opacity-0 group-hover:opacity-100"
                    onClick={() => onEditSavedFilter(f.id)}
                  >
                    <Pencil className="size-3 text-muted-foreground hover:text-foreground" />
                  </button>
                  <ConfirmPopover
                    open={confirmDeleteFilterId === f.id}
                    onOpenChange={(o) => setConfirmDeleteFilterId(o ? f.id : null)}
                    title="删除筛选器"
                    description={`确定要删除「${f.name}」吗？删除后将从侧栏移除。`}
                    onConfirm={() => onDeleteSavedFilter(f.id)}
                  >
                    <button
                      type="button"
                      aria-label={`删除筛选器 ${f.name}`}
                      className={cn(
                        "shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                        // 弹框打开后鼠标离开行，行内按钮会回到 opacity-0——保持可见，
                        // 否则锚点视觉上"消失"只剩一个悬空小框
                        confirmDeleteFilterId === f.id && "opacity-100",
                      )}
                    >
                      <Trash2 className="size-3 text-muted-foreground hover:text-destructive" />
                    </button>
                  </ConfirmPopover>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* 项目列表区（整栏统一滚动：不再自带 flex-1/ScrollArea，随根列滚动） */}
      <div className="px-3 pb-3">
        <div className="flex items-center justify-between py-1">
          <span className="text-xs uppercase tracking-wide text-muted-foreground">项目</span>
          <Button
            variant="ghost"
            size="icon"
            className="h-6 w-6"
            aria-label="新建项目"
            onClick={() => setAdding(true)}
          >
            <Plus className="size-3.5" />
          </Button>
        </div>

        <div>
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
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
                        onRequestTriage={bumpTriageIntent}
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
                      dueForReview={reviewDueIds.has(id)}
                      active={effectiveProjectId === id && !ungroupedActive}
                      onSelect={() => onSelectProject(id)}
                      onConfirmDelete={() => {
                        const target = projectById.get(id);
                        if (target) confirmDelete(target);
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
                      className="flex w-full items-center gap-2 rounded-md py-1.5 pl-3 pr-2 text-sm text-muted-foreground hover:bg-accent/50"
                    >
                      <Archive className="size-3.5" />
                      <span>已归档</span>
                      {/* 计数推到行尾（不再紧贴文字连读成「已归档3」），
                          折叠箭头钉最右——与项目行同版式 */}
                      <span className="ml-auto text-xs tabular-nums">
                        {archivedProjects.length}
                      </span>
                      <span className="flex size-3.5 shrink-0 items-center justify-center">
                        {archivedOpen ? (
                          <ChevronDown className="size-3.5" />
                        ) : (
                          <ChevronRight className="size-3.5" />
                        )}
                      </span>
                    </button>
                    {archivedOpen && (
                      <div className="space-y-0.5 pl-2">
                        {archivedProjects.map((p) => (
                          <div
                            key={p.id}
                            className={cn(
                              "group flex w-full items-center gap-2 rounded-md py-1.5 pl-3 pr-2 text-sm",
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
                            {/* 取消归档：与归档同形制先出轻量确认（锚定恢复钮），
                                确认后才翻转 is_archived 回到主列表 */}
                            <ConfirmPopover
                              open={confirmUnarchiveId === p.id}
                              onOpenChange={(o) => setConfirmUnarchiveId(o ? p.id : null)}
                              title="取消归档"
                              description={`确定要将「${p.title}」恢复到项目列表吗？`}
                              confirmLabel="恢复"
                              confirmTone="default"
                              onConfirm={() => void toggleArchive(p)}
                              tooltip="取消归档"
                            >
                              <button
                                type="button"
                                aria-label={`取消归档 ${p.title}`}
                                className={cn(
                                  "shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                                  // 弹框打开后鼠标离开行仍保持锚点可见（同筛选器删除）
                                  confirmUnarchiveId === p.id && "opacity-100",
                                )}
                              >
                                <ArchiveRestore className="size-3 text-muted-foreground hover:text-foreground" />
                              </button>
                            </ConfirmPopover>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            </SortableContext>
          </DndContext>
        </div>
      </div>

      {/* 编辑项目（#36 重命名 + 改色；M8 追加「上级文件夹」选择） */}
      <ProjectEditDialog
        project={editTarget}
        projects={projects}
        onClose={() => setEditTarget(null)}
        onSaved={() => void refetchProjects()}
      />
    </nav>
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
  // F1 回顾周期档（REVIEW_OFF 哨兵 = 关闭；档位天数为唯一真值）
  const [reviewDays, setReviewDays] = useState<string>(REVIEW_OFF);
  // 打开时装载当前项目值（key 重挂载或 open 翻转均可正确初始化）
  const [loadedFor, setLoadedFor] = useState<number | null>(null);
  if (project != null && loadedFor !== project.id) {
    setLoadedFor(project.id);
    setTitle(project.title);
    setColor(project.hex_color || PRESET_10[3]);
    setParentUuid(normalizeParentUuid(project.parent_uuid) ?? PARENT_NONE);
    setReviewDays(
      project.review_interval_days && project.review_interval_days > 0
        ? String(project.review_interval_days)
        : REVIEW_OFF,
    );
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
    // F1 回顾周期：有变化才写；走 setReviewInterval 语义化入口
    //（开启时从未回顾过则从现在起算、关闭时清残留暂缓——raw update 不带这些语义）
    const nextReviewDays =
      reviewDays === REVIEW_OFF ? null : Number(reviewDays);
    const currentReviewDays =
      project.review_interval_days && project.review_interval_days > 0
        ? project.review_interval_days
        : null;
    try {
      await todoProjectUpdate(project.id, {
        title: t !== project.title ? t : undefined,
        hex_color: color !== project.hex_color ? color : undefined,
        parent_uuid: nextParent !== currentParent ? nextParent : undefined,
      });
      if (nextReviewDays !== currentReviewDays) {
        await todoProjectSetReviewInterval(project.id, nextReviewDays);
      }
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
          {/* F1 回顾周期：到期项目进侧栏「回顾」中心，逐项目走三步向导 */}
          <div className="space-y-1.5">
            <label
              className="text-xs text-muted-foreground"
              htmlFor="project-review-interval"
            >
              回顾周期
            </label>
            <Select value={reviewDays} onValueChange={setReviewDays}>
              <SelectTrigger id="project-review-interval" className="w-full">
                <SelectValue placeholder="关闭" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={REVIEW_OFF}>关闭</SelectItem>
                {REVIEW_INTERVAL_PRESETS.map((p) => (
                  <SelectItem key={p.days} value={String(p.days)}>
                    {p.label}
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

/** 未分组虚拟项（id=-1，整行长按拖拽参与项目排序；行尾 hover 出分诊入口 F2） */
function SortableUngroupedRow({
  active,
  onSelect,
  onRequestTriage,
}: {
  active: boolean;
  onSelect: () => void;
  /** 分诊入口（F2）：经 app-store 意图计数器传到 task-panel 的分诊弹窗 */
  onRequestTriage: () => void;
}) {
  const { listeners, setNodeRef, transform, transition } = useSortable({
    id: UNGROUPED_ID,
  });

  return (
    <div
      ref={setNodeRef}
      {...listeners}
      style={{ transform: transform ? `translateY(${transform.y}px)` : undefined, transition }}
      className={cn(
        // select-none：长按拖拽期间不把行文字刷成选中态
        "group flex select-none items-center gap-2 rounded-md py-1.5 pl-3 pr-2 text-sm",
        active
          ? "bg-primary/10 font-medium text-primary"
          : "text-sidebar-foreground hover:bg-sidebar-accent/50",
      )}
    >
      <button
        type="button"
        onClick={onSelect}
        className="flex min-w-0 flex-1 items-center gap-2 text-left"
      >
        <Inbox className="size-4 shrink-0" />
        <span className="truncate">未分组</span>
      </button>
      {/* 分诊入口（与归档行「取消归档」同版式：hover 才出现，不占常态行宽） */}
      <Tooltip>
        <TooltipTrigger asChild>
          <button
            type="button"
            aria-label="分诊未分组"
            onClick={(e) => {
              e.stopPropagation();
              onRequestTriage();
            }}
            className="flex size-4 shrink-0 items-center justify-center opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
          >
            <FolderInput className="size-3 text-muted-foreground hover:text-foreground" />
          </button>
        </TooltipTrigger>
        <TooltipContent>分诊未分组（逐条决定归属）</TooltipContent>
      </Tooltip>
    </div>
  );
}

/** 单行可拖拽项目项（M8：带层级缩进与子项目折叠箭头；整行长按拖拽） */
function SortableProjectRow({
  project,
  depth,
  hasChildren,
  collapsed,
  onToggleCollapse,
  undoneCount,
  dueForReview,
  active,
  onSelect,
  onConfirmDelete,
  onRequestEdit,
  onRequestArchive,
}: {
  project: TodoProject;
  /** 层级深度：顶层 0，每层缩进 14px */
  depth: number;
  /** 是否有子项目（有则行尾渲染折叠箭头） */
  hasChildren: boolean;
  collapsed: boolean;
  onToggleCollapse: () => void;
  undoneCount: number;
  /** F1 项目回顾：该项目已到期待回顾（琥珀点徽标，点击进回顾中心） */
  dueForReview: boolean;
  active: boolean;
  onSelect: () => void;
  /** 删除确认通过后直接执行（撤销窗口软删由父级负责） */
  onConfirmDelete: () => void;
  /** 上报编辑请求（重命名/改色/改上级文件夹；#36 + M8） */
  onRequestEdit: () => void;
  /** 上报归档请求（本批新增；is_archived 翻转由父级 toggleArchive 处理） */
  onRequestArchive: () => void;
}) {
  const { listeners, setNodeRef, transform, transition } = useSortable({
    id: project.id,
  });
  const navigate = useNavigate();

  return (
    <div
      ref={setNodeRef}
      {...listeners}
      data-testid="project-row"
      data-uuid={project.uuid}
      data-depth={depth}
      style={{
        // 横向位移一并跟随：改层级靠横向手势表达，不给位移反馈等于没有反馈
        transform: transform
          ? `translate3d(${transform.x}px, ${transform.y}px, 0)`
          : undefined,
        transition,
        // 层级缩进用物理属性 paddingLeft（避开与 Tailwind 的逻辑属性 padding-inline 冲突）。
        // 基准 12 = 行容器 px-3 后与快捷视图区图标列同列（图标 left 24、文字 left 48）
        paddingLeft: 12 + depth * 14,
      }}
      className={cn(
        // select-none：长按拖拽期间不把行文字刷成选中态
        "group flex select-none items-center gap-2 rounded-md py-1.5 pr-2 text-sm",
        active ? "bg-primary/10 font-medium text-primary" : "hover:bg-sidebar-accent/50",
      )}
    >
      {/* 右键菜单：标题头 + 编辑项目（重命名/改色/改上级）+ 归档 + 删除（保护弹窗由父级处理） */}
      <ProjectContextMenu
        project={project}
        undoneCount={undoneCount}
        onRequestEdit={onRequestEdit}
        onRequestArchive={onRequestArchive}
        onConfirmDelete={onConfirmDelete}
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
        {/* 行尾未完成计数（纯灰数字；0 不占位）：紧跟行尾图标左侧右对齐 */}
        {undoneCount > 0 && (
          <span className="ml-auto text-xs tabular-nums text-muted-foreground">
            {undoneCount}
          </span>
        )}
        {/* F1 待回顾徽标：琥珀圆点 + tooltip，点击直达回顾中心（排在计数与
            折叠箭头之间；到期是「状态」不是「计数」，点状提示即可） */}
        {dueForReview && (
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label={`${project.title}待回顾`}
                onClick={(e) => {
                  e.stopPropagation();
                  navigate("/todo/review");
                }}
                className="flex size-3.5 shrink-0 items-center justify-center"
              >
                <span className="size-2 rounded-full bg-warning" />
              </button>
            </TooltipTrigger>
            <TooltipContent>待回顾 · 点击进入回顾中心</TooltipContent>
          </Tooltip>
        )}
        {/* 折叠箭头：仅父节点渲染，钉在行尾最右（不在图标前占槽——那会在行首与
            图标之间空出一条死带；叶子行零占位） */}
        {hasChildren && (
          <button
            type="button"
            aria-label={`${collapsed ? "展开" : "折叠"}子项目 ${project.title}`}
            aria-expanded={!collapsed}
            onClick={onToggleCollapse}
            className="flex size-3.5 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
          >
            {collapsed ? (
              <ChevronRight className="size-3.5" />
            ) : (
              <ChevronDown className="size-3.5" />
            )}
          </button>
        )}
      </ProjectContextMenu>
    </div>
  );
}
