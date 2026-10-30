/**
 * KanbanView — 看板视图（04 文档 §3.3 复刻）
 *
 * - 分列：五档 project / status / priority / label / due（纯函数见
 *   shared/kanban-group：列头 + 归属键 + 截止桶代表时刻；跨列拖拽改归属，
 *   标签档 = 换主标签（删源挂目），截止档 = 改期到桶代表时刻）
 * - 卡片同时挂 useDraggable + useDroppable；PointerSensor distance:5
 * - 拖拽语义：同列落卡片 → 插到目标前；同列空白 → 追加；异列 → 先改归属再排序。
 *   position 一律取中值算法写入（03 文档 §一）。
 * - 排序（#26）：列内保留父层传入序（task-panel 已按工具栏档位 sortTasks），
 *   本视图不再 position 重排——否则截止/优先级/标题/创建档在看板全部失效。
 *   拖拽源任何档位都挂（2026-10-30）——跨列改归属与排序档无关，此前用
 *   sortable 一并禁用会让非「拖拽顺序」档的看板完全拖不动；列内落位仅
 *   manual 档生效（其他档位提示切档），跨列落位仍走 position 中值。
 */
import { memo, useCallback, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  pointerWithin,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
  type DraggableAttributes,
} from "@dnd-kit/core";
import { format } from "date-fns";
import { toast } from "sonner";
import {
  Calendar,
  Check,
  CircleCheck,
  Flag,
  FolderInput,
  Star,
  StarOff,
  Sunrise,
  X,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { useTodoStore } from "@/features/todo/store";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  todoTaskLabelCreate,
  todoTaskLabelDelete,
  todoTaskLabelList,
  todoTaskUpdate,
  todoTaskUpdatePosition,
  type ProjectedTaskLabel,
  type TodoProject,
  type TodoTaskListItem,
} from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR, PRIORITY_LABELS } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type DisplayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import { isListActivationKey } from "../shared/list-keyboard";
import type { TaskSortKey } from "../shared/task-filters";
import { completeTask } from "../shared/task-actions";
import {
  batchSetDueDate,
  batchUpdateFavorite,
  batchUpdateMyDay,
  batchUpdatePriority,
  batchUpdateStatus,
} from "../shared/batch-actions";
import { midpoint } from "../shared/position";
import {
  dueBucketRepresentative,
  kanbanColumnKey,
  kanbanColumns,
  kanbanFallbackKey,
  type DueBucket,
  type KanbanColumnDef,
  type KanbanGroupBy,
} from "../shared/kanban-group";

import { TaskContextMenu } from "./task-context-menu";
import { CheckSvg } from "./task-list-view";

/** 分组维度（定义见 shared/kanban-group；此处 re-export 保持既有 import 路径） */
export type { KanbanGroupBy };

interface KanbanViewProps {
  tasks: TodoTaskListItem[];
  projects: TodoProject[];
  groupBy: KanbanGroupBy;
  /** 任务→标签映射（list-page 级拉取，卡片渲染标签 chips） */
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，卡片渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 工具栏排序档位（#26）：列内沿用传入序；manual 才允许列内拖拽重排 */
  sortKey: TaskSortKey;
  /** 加载态（H3）：查询进行中列内不闪「拖拽任务到此处」空态 */
  loading?: boolean;
  /**
   * 列键 → 该组总条数（P1 窗口化：列内只装前 N 条，角标仍报真实总数）。
   * 缺省 = 用已加载条数（全量通道，label 档等）。
   */
  groupTotals?: ReadonlyMap<string, number>;
  /**
   * 列满出口（#107）：列内只装前 N 条时，切到列表继续加载。
   * 只对能在列表工具栏表达的列（优先级/状态）附带筛选；项目/标签/截止档
   * 仅切视图（项目归属由壳层 props 控制，这里不越权改）。
   */
  onOpenColumnInList?: (colKey: string) => void;
}

export function KanbanView({
  tasks,
  projects,
  groupBy,
  labelsByTask,
  remindersByTask,
  sortKey,
  loading,
  groupTotals,
  onOpenColumnInList,
}: KanbanViewProps) {
  const qc = useQueryClient();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  // memo 友好：打开详情回调恒定引用，列/卡片 props 只随业务数据变化
  const openDetail = useCallback((id: number) => setSelectedTaskId(id), [setSelectedTaskId]);
  const [draggingId, setDraggingId] = useState<number | null>(null);
  // 拖拽刚结束的时间戳：抑制 dragend 后误触发的卡片 click（打开详情）
  const dragEndStamp = useRef(0);

  // ---- 多选批量（与列表视图同语义；x 键切选中、选中态下点击卡片 = 切勾选）----
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [batchBusy, setBatchBusy] = useState(false);
  const selectedTasks = useMemo(() => tasks.filter((t) => selected.has(t.id)), [tasks, selected]);
  const allDoneSelected = selectedTasks.length > 0 && selectedTasks.every((t) => t.done);

  const toggleSelect = useCallback((id: number) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);
  // 恒定引用：内联箭头会让 draggingId 一变就击穿列/卡片的 memo，整板重渲染
  const clearSelection = useCallback(() => setSelected(new Set()), []);

  const runBatch = useCallback(
    async (label: string, action: (sel: TodoTaskListItem[]) => Promise<unknown>) => {
      const sel = selectedTasks;
      if (sel.length === 0 || batchBusy) return;
      setBatchBusy(true);
      try {
        await action(sel);
        void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
        toast.success(`已批量${label} ${sel.length} 条任务`, { description: "Ctrl+Z 可撤销" });
      } catch (e) {
        console.error("批量操作失败:", e);
        toast.error(`批量${label}失败，已完成的条目不回滚`);
      } finally {
        setBatchBusy(false);
        setSelected(new Set());
      }
    },
    [selectedTasks, batchBusy, qc],
  );
  // PointerSensor distance:5（04 §3.3：位移 5px 内不算拖拽，保证点击）
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
  );
  // #26：仅拖拽顺序档允许拖拽重排（列内顺序由排序档决定，拖了也会被
  // 覆盖）；跨列移动改归属不受档位限制，见 handleDragEnd
  const sortable = sortKey === "manual";

  // ---- 分列（shared/kanban-group 纯函数；五档 project/status/priority/label/due）----
  const columns = useMemo<KanbanColumnDef[]>(
    () => kanbanColumns(groupBy, projects, labelsByTask, tasks),
    [groupBy, projects, labelsByTask, tasks],
  );

  const grouped = useMemo(() => {
    const map = new Map<string, TodoTaskListItem[]>();
    const fallback = kanbanFallbackKey(groupBy);
    for (const col of columns) map.set(col.key, []);
    for (const t of tasks) {
      const key = kanbanColumnKey(groupBy, t, labelsByTask);
      (map.get(key) ?? map.get(fallback)!).push(t);
    }
    // 列内保留父层传入序（工具栏 sortTasks 档位）——此处若再按
    // position 重排，非拖拽档的排序选择在看板将全部失效
    return map;
  }, [tasks, columns, groupBy, labelsByTask]);

  const refetchTasks = () => void qc.invalidateQueries({ queryKey: ["todo_tasks"] });

  /** 异列：先改归属，由调用方继续处理排序 */
  const moveAcross = async (taskId: number, colKey: string) => {
    if (groupBy === "project") {
      const pid = colKey === "ungrouped" ? null : Number(colKey);
      await todoTaskUpdate(taskId, { project_id: pid });
    } else if (groupBy === "priority") {
      await todoTaskUpdate(taskId, { priority: Number(colKey.slice(4)) });
    } else if (groupBy === "label") {
      await moveTaskLabel(taskId, colKey);
    } else if (groupBy === "due") {
      const bucket = colKey.slice(4) as DueBucket;
      await todoTaskUpdate(taskId, { due_date: dueBucketRepresentative(bucket) });
    } else if (colKey === "done") {
      const task = tasks.find((t) => t.id === taskId);
      if (task) await completeTask(task, qc);
    } else {
      await todoTaskUpdate(taskId, { status: colKey, done: 0, done_at: null });
    }
  };

  /**
   * 标签列间移动 = 换主标签：删源挂目（其余标签不动）。
   * 源列由拖拽前归属键解析（落库前归属未变，kanbanColumnKey 仍是源列）；
   * 挂载行按 (task_id, label_id) 查链 id 后删（投影只有展示三列、无链 id）；
   * 查不到按「只挂目」退化（并发删除等竞态不阻断拖拽主流程）。
   */
  const moveTaskLabel = async (taskId: number, colKey: string) => {
    const task = tasks.find((t) => t.id === taskId);
    const fromKey = task ? kanbanColumnKey(groupBy, task, labelsByTask) : "lbl:none";
    const fromId = fromKey === "lbl:none" ? null : Number(fromKey.slice(4));
    const toId = colKey === "lbl:none" ? null : Number(colKey.slice(4));
    if (fromId != null && fromId !== toId) {
      try {
        const links = await todoTaskLabelList({ page: 1, page_size: 1000 });
        const link = links.find(
          (l) => l.task_id === taskId && l.label_id === fromId && !l.is_deleted,
        );
        if (link) await todoTaskLabelDelete(link.id);
      } catch (e) {
        console.error("标签换列解挂失败（继续挂载目标标签）:", e);
      }
    }
    if (toId != null && toId !== fromId) {
      await todoTaskLabelCreate({ task_id: taskId, label_id: toId });
    }
  };

  /** 排序落位：prevId=null 表示置于列首，nextId=null 表示列尾追加 */
  const reorder = async (taskId: number, prevId: number | null, nextId: number | null) => {
    const all = tasks;
    const prev = prevId != null ? all.find((t) => t.id === prevId) : undefined;
    const next = nextId != null ? all.find((t) => t.id === nextId) : undefined;
    const pos = midpoint(prev?.position, next?.position);
    await todoTaskUpdatePosition(taskId, pos);
  };

  /** dnd-kit id 形如 "task:123" / "col:xxx"，提取数字任务 id */
  const taskIdOf = (raw: string | number): number => {
    const s = String(raw);
    return s.startsWith("task:") ? Number(s.slice(5)) : Number.NaN;
  };

  const handleDragStart = (e: DragStartEvent) => {
    setDraggingId(taskIdOf(e.active.id));
  };

  /** 非「拖拽顺序」档的列内落位提示：跨列改归属照样能用，只是列内顺序由排序档决定 */
  const hintSortedColumn = () => {
    toast("列内顺序由当前排序档决定", {
      description: "切到「排序 → 拖拽顺序」后可手动调整",
    });
  };

  const handleDragEnd = async (e: DragEndEvent) => {
    const { active, over } = e;
    setDraggingId(null);
    dragEndStamp.current = Date.now();
    if (!over) return;
    const taskId = taskIdOf(active.id);
    const task = tasks.find((t) => t.id === taskId);
    if (!task || Number.isNaN(taskId)) return;

    // over 目标可能是卡片（id=task:<id>）或列（id=col:<key>）
    const overData = String(over.id);
    const draggedCol = columnKeyOf(task);

    if (overData.startsWith("col:")) {
      const colKey = overData.slice(4);
      if (colKey === draggedCol) {
        // 同列空白 → 追加到末尾；非拖拽档下同列 position 无意义，不写
        if (!sortable) return hintSortedColumn();
        const list = grouped.get(colKey) ?? [];
        const last = list[list.length - 1];
        if (last && last.id !== taskId) await reorder(taskId, last.id, null);
        return;
      }
      await moveAcross(taskId, colKey);
      // 异列落空白 → 追加到该列末尾
      const list = grouped.get(colKey) ?? [];
      const last = list[list.length - 1];
      if (last) await reorder(taskId, last.id, null);
      refetchTasks();
      return;
    }

    const targetId = taskIdOf(overData);
    const target = tasks.find((t) => t.id === targetId);
    if (!target || target.id === taskId) return;
    const targetCol = columnKeyOf(target);

    if (targetCol !== draggedCol) {
      await moveAcross(taskId, targetCol);
      // 异列插到目标前
      await reorder(taskId, null, targetId);
    } else {
      // 同列插到目标前：取目标与前一张卡片的中值；
      // 非拖拽档下顺序由排序档决定，写入立即被覆盖 → 提示切档
      if (!sortable) return hintSortedColumn();
      const list = grouped.get(targetCol) ?? [];
      const idx = list.findIndex((t) => t.id === targetId);
      const prev = idx > 0 ? list[idx - 1] : undefined;
      if (prev?.id === taskId) return;
      await reorder(taskId, prev?.id ?? null, targetId);
    }
    refetchTasks();
  };

  const columnKeyOf = (t: TodoTaskListItem): string =>
    kanbanColumnKey(groupBy, t, labelsByTask);

  const draggingTask = draggingId != null ? tasks.find((t) => t.id === draggingId) : undefined;

  // 加载态与列表视图同口径（H3）：查询进行中不闪列内「拖拽任务到此处」
  if (loading && tasks.length === 0) {
    return (
      <div aria-busy className="flex min-h-0 flex-1 gap-4 overflow-hidden p-4" data-testid="kanban-loading">
        {Array.from({ length: 4 }, (_, i) => (
          <div key={i} className="w-72 shrink-0 animate-pulse rounded-lg border border-border/50 bg-muted/20">
            <div className="space-y-2 border-b px-3 py-2">
              <div className="h-4 w-24 rounded bg-muted" />
            </div>
            <div className="space-y-2 p-2">
              {Array.from({ length: 3 }, (_, j) => (
                <div key={j} className="h-[60px] rounded-md bg-muted" />
              ))}
            </div>
          </div>
        ))}
      </div>
    );
  }

  return (
    <div
      className={cn(
        "relative min-h-0 flex-1",
        draggingId != null ? "overflow-x-hidden" : "overflow-x-auto",
      )}
    >
      <DndContext
        sensors={sensors}
        collisionDetection={pointerWithin}
        onDragStart={handleDragStart}
        onDragEnd={(e: DragEndEvent) => void handleDragEnd(e)}
      >
        <div className="flex h-full gap-4 p-4">
          {columns.map((col) => (
            <DroppableKanbanColumn
              key={col.key}
              column={col}
              tasks={grouped.get(col.key) ?? []}
              total={groupTotals?.get(col.key)}
              projects={projects}
              labelsByTask={labelsByTask}
              remindersByTask={remindersByTask}
              dragEndStamp={dragEndStamp}
              onOpenDetail={openDetail}
              onOpenColumnInList={onOpenColumnInList}
              selected={selected}
              hasSelection={selected.size > 0}
              onToggleSelect={toggleSelect}
              onClearSelection={clearSelection}
            />
          ))}
        </div>

        {/* 多选批量工具条（与列表视图同款浮动形制；不含移动项目——
            看板拖拽本身就是移动入口，工具条里再放一次反而冗余） */}
        {selected.size > 0 && (
          <div
            role="toolbar"
            aria-label={`已选中 ${selected.size} 条任务的批量操作`}
            className="absolute bottom-4 left-1/2 z-20 flex -translate-x-1/2 items-center gap-0.5 rounded-lg border bg-background px-2 py-1.5 shadow-lg"
          >
            <span className="px-2 text-sm text-muted-foreground tabular-nums" aria-live="polite">
              已选 {selected.size} 条
            </span>
            <span className="mx-1 h-4 w-px bg-border" />
            {(
              [
                {
                  label: allDoneSelected ? "标记未完成" : "标记完成",
                  icon: allDoneSelected ? CircleCheck : Check,
                  run: () =>
                    runBatch("标记完成", (sel) =>
                      batchUpdateStatus(
                        sel,
                        allDoneSelected
                          ? { done: 0, done_at: null, status: "pending" }
                          : { done: 1, done_at: Date.now(), status: "done" },
                        qc,
                      ),
                    ),
                },
                {
                  label: allDoneSelected ? "移回待办" : "移入进行中",
                  icon: FolderInput,
                  run: () =>
                    runBatch(allDoneSelected ? "移回待办" : "移入进行中", (sel) =>
                      batchUpdateStatus(sel, allDoneSelected ? { status: "pending" } : { status: "doing" }, qc),
                    ),
                },
                { label: "加入我的一天", icon: Sunrise, run: () => runBatch("加入我的一天", (sel) => batchUpdateMyDay(sel, true, qc)) },
                { label: "收藏", icon: Star, run: () => runBatch("收藏", (sel) => batchUpdateFavorite(sel, true, qc)) },
                { label: "取消收藏", icon: StarOff, run: () => runBatch("取消收藏", (sel) => batchUpdateFavorite(sel, false, qc)) },
              ] as const
            ).map(({ label, icon: Icon, run }) => (
              <Tooltip key={label}>
                <TooltipTrigger asChild>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    aria-label={label}
                    disabled={batchBusy}
                    onClick={() => void run()}
                  >
                    <Icon size={14} />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{label}</TooltipContent>
              </Tooltip>
            ))}
            <DropdownMenu>
              <Tooltip>
                <TooltipTrigger asChild>
                  <DropdownMenuTrigger asChild>
                    <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="批量改期" disabled={batchBusy}>
                      <Calendar size={14} />
                    </Button>
                  </DropdownMenuTrigger>
                </TooltipTrigger>
                <TooltipContent>批量改期</TooltipContent>
              </Tooltip>
              <DropdownMenuContent align="center">
                <DropdownMenuItem onSelect={() => void runBatch("改期到今天", (sel) => batchSetDueDate(sel, "today", qc))}>今天</DropdownMenuItem>
                <DropdownMenuItem onSelect={() => void runBatch("改期到明天", (sel) => batchSetDueDate(sel, "tomorrow", qc))}>明天</DropdownMenuItem>
                <DropdownMenuItem onSelect={() => void runBatch("改期到下周一", (sel) => batchSetDueDate(sel, "next_monday", qc))}>下周一</DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem onSelect={() => void runBatch("清除截止", (sel) => batchSetDueDate(sel, "clear", qc))}>清除截止</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            <DropdownMenu>
              <Tooltip>
                <TooltipTrigger asChild>
                  <DropdownMenuTrigger asChild>
                    <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="设置优先级" disabled={batchBusy}>
                      <Flag size={14} />
                    </Button>
                  </DropdownMenuTrigger>
                </TooltipTrigger>
                <TooltipContent>设置优先级</TooltipContent>
              </Tooltip>
              <DropdownMenuContent align="center">
                {PRIORITY_LABELS.map((label, lv) => (
                  <DropdownMenuItem key={lv} onSelect={() => void runBatch("设置优先级", (sel) => batchUpdatePriority(sel, lv, qc))}>
                    <span className="flex w-4 shrink-0 items-center justify-center">
                      <span className="h-2 w-2 rounded-full" style={{ backgroundColor: PRIORITY_COLOR[lv] }} />
                    </span>
                    {label}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
            <span className="mx-1 h-4 w-px bg-border" />
            <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="退出多选" onClick={() => setSelected(new Set())}>
              <X size={14} />
            </Button>
          </div>
        )}

        <DragOverlay dropAnimation={null}>
          {draggingTask ? (
            <KanbanCard
              task={draggingTask}
              labels={labelsByTask.get(draggingTask.id) ?? []}
              reminder={displayReminder(remindersByTask.get(draggingTask.id) ?? [], Date.now(), !!draggingTask.done)}
              overlay
            />
          ) : null}
        </DragOverlay>
      </DndContext>
    </div>
  );
}

/* ================= 列 ================= */

/**
 * 列内卡片虚拟化（P0 #5 看板补齐）：useVirtualizer 只挂可视窗 ± overscan。
 * 卡高随标题/标签行数浮动，故走动态 measureElement + 常量初值；
 * dnd-kit 拖拽用 transform 定位（视觉层）不动 DOM 流，与绝对定位
 * 行容器不冲突——dnd-kit 内部 transform 映射目标非布局盒。
 */
interface KanbanColumnProps {
  column: KanbanColumnDef;
  tasks: TodoTaskListItem[];
  /** 该列真实总数（窗口化下大于 tasks.length）；缺省 = tasks.length */
  total?: number;
  projects: TodoProject[];
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 拖拽结束时间戳 ref（点击抑制用） */
  dragEndStamp: React.RefObject<number>;
  onOpenDetail: (id: number) => void;
  /** 列满出口：切到列表继续加载（缺省 = 不渲染按钮） */
  onOpenColumnInList?: (colKey: string) => void;
  /** 多选态（P2 扩展：看板对齐列表/表格） */
  selected: Set<number>;
  hasSelection: boolean;
  onToggleSelect: (id: number) => void;
  /** Escape 退选全部（选中态下；透传卡片） */
  onClearSelection: () => void;
}

/**
 * 列 dnd 订阅壳（2026-10-30 拖拽卡顿治理）：
 * 原来 useDroppable 挂在列本体上，拖拽上下文一变整列就连带
 * `virtualizer.getVirtualItems()` 重建整棵行树（实测一次拖拽整列重渲染 86 次，
 * 是元素风暴的最大来源）。拆分后：壳只负责 isOver 边框 + droppable 注册，
 * 列本体（KanbanColumnBody）不再订阅拖拽上下文。
 */
const DroppableKanbanColumn = memo(function DroppableKanbanColumn(props: KanbanColumnProps) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${props.column.key}` });
  return (
    <div
      className={cn(
        "flex w-72 shrink-0 flex-col rounded-lg border bg-muted/20",
        isOver ? "border-primary/40 bg-muted/40" : "border-border/50",
      )}
    >
      <KanbanColumnBody {...props} dropRef={setNodeRef} />
    </div>
  );
});

const KanbanColumnBody = memo(function KanbanColumnBody({
  column,
  tasks,
  total,
  projects,
  labelsByTask,
  remindersByTask,
  dragEndStamp,
  onOpenDetail,
  onOpenColumnInList,
  selected,
  hasSelection,
  onToggleSelect,
  onClearSelection,
  dropRef,
}: KanbanColumnProps & {
  /** 列卡片区注册为 droppable 的节点回调 */
  dropRef?: (node: HTMLElement | null) => void;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  /** 同一 node 双注册：droppable 区 + 虚拟化滚动容器（回调保持稳定，避免每帧重挂） */
  const setScrollNode = useCallback(
    (node: HTMLDivElement | null) => {
      dropRef?.(node);
      scrollRef.current = node;
    },
    [dropRef],
  );
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 76,
    overscan: 6,
    getItemKey: (i) => tasks[i].id,
  });
  /**
   * 提醒徽标按任务缓存：displayReminder 每次调用都产新对象，不缓存的话
   * selected/多选批量等任一列渲染都会让全部卡片 memo 失效、整列整树重建。
   */
  const reminderByTask = useMemo(() => {
    const map = new Map<number, DisplayReminder | null>();
    const now = Date.now();
    for (const t of tasks) {
      map.set(t.id, displayReminder(remindersByTask.get(t.id) ?? [], now, !!t.done));
    }
    return map;
  }, [tasks, remindersByTask]);

  return (
    <>
      {/* 列头（P1 窗口化：角标报真实总数；窗口内只装了前 N 条） */}
      <div className="flex items-center gap-2 border-b px-3 py-2">
        <span className="h-2 w-2 rounded-full" style={{ background: column.color }} />
        <span className="text-sm font-medium">{column.title}</span>
        <span className="text-xs text-muted-foreground">{total ?? tasks.length}</span>
      </div>
      {total != null && total > tasks.length && (
        <div className="flex items-center justify-between gap-2 border-b bg-muted/30 px-3 py-1 text-[11px] text-muted-foreground">
          <span>
            已显示前 {tasks.length} 条，还有 {total - tasks.length} 条未加载
          </span>
          {onOpenColumnInList ? (
            <button
              type="button"
              className="shrink-0 rounded px-1 text-primary hover:underline focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              onClick={() => onOpenColumnInList(column.key)}
            >
              在列表中查看
            </button>
          ) : null}
        </div>
      )}

      {/* 卡片区：虚拟化行容器（绝对定位行 + gap 以 padding 计入 estimate 初值）。
          原 flex+gap 控制间距的说明已随虚拟化失效——间距改由行容器的 margin 承担 */}
      <div
        ref={setScrollNode}
        className="flex min-h-0 flex-1 flex-col overflow-y-auto p-2"
      >
        {tasks.length === 0 ? (
          <div className="flex h-20 items-center justify-center text-xs text-muted-foreground/40">
            拖拽任务到此处
          </div>
        ) : (
          /* shrink-0 不能省：本容器是 flex-col 的滚动区，虚拟高度holder 作为 flex
             子项默认 flex-shrink=1，会被压回视口高度——此时绝对定位的卡片溢出
             holder 形成「滚动高度 = 已渲染行下缘」，往下滚一屏 scrollHeight 就长
             一屏，滚动条滑块越拖越短（2026-10-30 用户反馈） */
          <div
            className="shrink-0"
            style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}
          >
            {virtualizer.getVirtualItems().map((vi) => {
              const t = tasks[vi.index];
              return (
                <div
                  key={t.id}
                  data-index={vi.index}
                  ref={virtualizer.measureElement}
                  style={{
                    position: "absolute",
                    top: vi.start,
                    left: 0,
                    width: "100%",
                    paddingBottom: 4,
                  }}
                >
                  <TaskContextMenu
                    task={t}
                    projects={projects}
                    onOpenDetail={() => onOpenDetail(t.id)}
                    onStartSelect={() => onToggleSelect(t.id)}
                  >
                    <SortableKanbanCard
                      task={t}
                      labels={labelsByTask.get(t.id) ?? []}
                      reminder={reminderByTask.get(t.id) ?? null}
                      dragEndStamp={dragEndStamp}
                      onOpenDetail={onOpenDetail}
                      selected={selected.has(t.id)}
                      hasSelection={hasSelection}
                      onToggleSelect={onToggleSelect}
                      onClearSelection={onClearSelection}
                    />
                  </TaskContextMenu>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
});

/* ================= 卡片 ================= */

interface KanbanCardProps {
  task: TodoTaskListItem;
  labels: ProjectedTaskLabel[];
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder: DisplayReminder | null;
  dragging?: boolean;
  overlay?: boolean;
  /** 拖拽结束时间戳 ref（overlay 不需要） */
  dragEndStamp?: React.RefObject<number>;
  onOpenDetail?: (id: number) => void;
  /** 多选勾选切换（P2 扩展；overlay 卡片不传） */
  onToggleSelect?: (id: number) => void;
  /** Escape 退选全部（选中态下） */
  onClearSelection?: () => void;
  selected?: boolean;
  /** 任一卡片被选中时，卡片点击语义切换为「切换勾选」（与列表行一致） */
  hasSelection?: boolean;
}

/**
 * 卡片 dnd 订阅壳（2026-10-30 拖拽卡顿治理）：
 * dnd-kit 的 useDraggable/useDroppable 读同一份拖拽上下文，指针跨卡时 over
 * 变化会让每个消费者重渲染——hook 挂在卡片本体上时，一次拖拽要把已渲染的
 * 几十张卡整树重建（dev 实测单次拖拽 6s 生成上万 React 元素、p95 帧间隔
 * 83ms、24 段长任务）。拆出薄壳后每帧只重建这层 div，卡片本体 memo 命中、
 * 不再进入子树。
 */
const SortableKanbanCard = memo(function SortableKanbanCard(props: KanbanCardProps) {
  const { task } = props;
  /** 任何排序档都挂拖拽源（2026-10-30）：跨列改归属与排序档无关；列内落位是否生效由父层判 sortable */
  const {
    setNodeRef: setDragRef,
    attributes,
    listeners,
    isDragging,
  } = useDraggable({ id: `task:${task.id}` });
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id: `task:${task.id}` });
  const setRefs = useCallback(
    (node: HTMLDivElement | null) => {
      setDragRef(node);
      setDropRef(node);
    },
    [setDragRef, setDropRef],
  );

  return (
    <div ref={setRefs} {...listeners} style={{ touchAction: "none" }}>
      <KanbanCard {...props} dragging={isDragging} isOver={isOver} dragAttributes={attributes} />
    </div>
  );
});

const KanbanCard = memo(function KanbanCard({
  task,
  labels,
  reminder,
  dragging,
  overlay,
  dragEndStamp,
  onOpenDetail,
  onToggleSelect,
  onClearSelection,
  selected = false,
  hasSelection = false,
  isOver = false,
  dragAttributes,
}: KanbanCardProps & {
  /** 作为放置目标的悬停态（SortableKanbanCard 传入；overlay 恒 false） */
  isOver?: boolean;
  /** dnd-kit draggable 属性（role/aria-describedby）；overlay 不传 */
  dragAttributes?: DraggableAttributes;
}) {
  const qc = useQueryClient();
  /** 逾期判定与列表行同源：截止早于当前时刻且未完成 */
  const overdue = task.due_date != null && !task.done && task.due_date < Date.now();
  /** 多选态才把勾选框切成多选框（拖拽浮层例外：浮层只做静态预览） */
  const selectMode = !!hasSelection && !overlay;

  return (
    <div
      {...dragAttributes}
      style={{ touchAction: "none" }}
      role="button"
      tabIndex={overlay ? -1 : 0}
      aria-label={`${task.done ? "已完成" : "未完成"}任务：${task.title}`}
      onClick={() => {
        // 拖拽松手后的 click 不视为点击打开详情
        if (dragEndStamp && Date.now() - dragEndStamp.current < 250) return;
        if (overlay || dragging) return;
        // 有选择态时点击 = 切换勾选（与列表行/竞品一致）；否则打开详情
        if (hasSelection) onToggleSelect?.(task.id);
        else onOpenDetail?.(task.id);
      }}
      onKeyDown={(e) => {
        // 键盘可达（H4，与列表/表格行同口径）：焦点在卡片容器时
        // Enter/Space 打开详情；焦点已在内层控件上则保留其原生行为。
        // x 键切选中（Linear 同款）；Escape 在选中态下退选全部
        if (e.nativeEvent.isComposing) return;
        if (e.target !== e.currentTarget) return;
        if (isListActivationKey(e.key)) {
          e.preventDefault();
          if (overlay || dragging) return;
          if (hasSelection) onToggleSelect?.(task.id);
          else onOpenDetail?.(task.id);
          return;
        }
        if (e.key === "x" || e.key === "X") {
          e.preventDefault();
          onToggleSelect?.(task.id);
        }
        if (e.key === "Escape" && hasSelection) {
          e.preventDefault();
          onClearSelection?.();
        }
      }}
      className={cn(
        "group relative rounded-md border border-border/50 bg-card p-3 shadow-sm hover:shadow-md",
        "focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring",
        "cursor-grab active:cursor-grabbing",
        dragging && "opacity-40",
        isOver && !dragging && "ring-2 ring-primary/40",
        overlay && "border-primary/40 shadow-xl",
        overlay && "cursor-grabbing",
        selected && "bg-primary/5 ring-1 ring-inset ring-primary/40",
      )}
    >
      {/* 多选态优先级左缘竖条（与列表行同口径）：常态优先级由完成框描边承载，
          进入多选后完成框让位给多选框、颜色无处可附，改由左缘竖条续上。
          卡片顶部不再画通栏色条——它悬在标题上方只剩一道孤线，反成噪点 */}
      {selectMode && (
        <span
          aria-hidden
          className="pointer-events-none absolute inset-y-2 left-0 w-1 rounded-full"
          style={{ background: PRIORITY_COLOR[task.priority] }}
        />
      )}

      {/* 标题行：勾选框 + 标题/元信息列 + 星标。
          勾选框与列表行同一次点击语义（2026-10-29 口径）：默认是完成框，
          进入多选态就地变多选框，不再多出一个隐形勾选圈占位 */}
      <div className="flex items-start gap-1.5">
        {selectMode ? (
          <button
            type="button"
            aria-label={selected ? "取消选中" : "选中任务"}
            aria-checked={selected}
            role="checkbox"
            className={cn(
              "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-[4px] border transition-colors",
              selected
                ? "border-primary bg-primary text-primary-foreground"
                : "border-muted-foreground/30 hover:border-primary",
              "focus-visible:outline-none",
            )}
            onClick={(e) => {
              e.stopPropagation();
              onToggleSelect?.(task.id);
            }}
          >
            {selected ? <CheckSvg className="size-3.5" stroke={3} /> : null}
          </button>
        ) : (
          /* 完成 checkbox（M5，与列表同款方角）：卡片正面直接入口，
             不必右键菜单绕一圈；未完成描边 = 优先级色（P0 回落中性灰） */
          <button
            type="button"
            aria-label={task.done ? "标记未完成" : "标记完成"}
            className={cn(
              "mt-0.5 h-5 w-5 shrink-0 rounded-[4px] border-2 transition-colors",
              task.done
                ? "border-muted-foreground bg-muted-foreground"
                : "border-muted-foreground/30 hover:border-primary",
            )}
            style={
              !task.done && task.priority > 0
                ? { borderColor: PRIORITY_COLOR[task.priority] }
                : undefined
            }
            onClick={(e) => {
              e.stopPropagation();
              void completeTask(task, qc);
            }}
          >
            {task.done ? <CheckSvg /> : null}
          </button>
        )}

        <div className="min-w-0 flex-1">
          <div
            className={cn(
              // break-words：长连续文本（URL/长英文串无空格断点）在卡内强制断行，
              // 否则整串不换行撑出卡片右缘
              "break-words text-sm font-medium leading-5",
              task.done && "text-muted-foreground line-through",
            )}
          >
            {task.title}
          </div>

          {/* 元信息单行：标签 / 截止 / 提醒 / 进度——与标题左缘对齐（旧版挂在
              卡片左内边距上，缩进比标题少 26px，整卡看着是歪的）；逾期未完成
              同列表行染红（旧版卡片只有灰色 MM-dd，逾期在板上没有任何信号） */}
          {(labels.length > 0 || task.due_date != null || reminder != null || task.percent_done > 0) && (
            <div className="mt-1.5 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
              {labels.length > 0 && <LabelChips labels={labels} max={2} />}
              {task.due_date != null && (
                <span
                  className={cn(
                    "inline-flex shrink-0 items-center gap-1",
                    overdue && OVERDUE_COLOR_CLASS,
                  )}
                >
                  <Calendar size={11} />
                  {format(new Date(task.due_date), "MM-dd")}
                </span>
              )}
              <ReminderChip reminder={reminder} />
              {task.percent_done > 0 && (
                <span className="shrink-0 tabular-nums">{Math.round(task.percent_done)}%</span>
              )}
            </div>
          )}
        </div>

        {!!task.is_favorite && (
          <Star size={13} className="mt-0.5 shrink-0" style={{ color: FAVORITE_COLOR }} fill="currentColor" />
        )}
      </div>
    </div>
  );
});
