/**
 * TaskListView — 任务列表行（04 文档 §3.2 复刻）
 *
 * 行规格：圆形 checkbox（done 联动 status/done_at）+ 标题（划线）+
 * 元信息行（标签/项目名/截止时间，逾期整段红）+ 优先级左缘竖条（P1–P5）+ hover 星标。
 * P1 增强：
 * - 虚拟化（P0）：仅渲染可视窗 ± overscan；绝对定位行必须用 top 定位，
 *   transform 会成为 fixed 后代（ContextMenuBase 哨兵）的 containing block。
 * - 键盘可达（P1#8）：行 role=button/tabIndex，Enter/Space 打开详情，j/k 移动焦点。
 * - 拖拽排序（P1#11）：GripVertical 手柄发起（行点击仍是打开详情），
 *   落在某行 → 插其前；落容器空白 → 尾部追加；position 中值写入后失效任务缓存。
 * - 多选批量（P2#17）：checkbox 或 shift 区间选择；两枚以上弹出批量工具条
 *   （完成/未完成/收藏/项目移动/删除，项目移动带中值落位）。详情抽屉仍由
 *   未选中行打开，选中行点击仅切换勾选（与多数竞品一致）。
 */
import { memo, useMemo, useRef, useState, type ReactNode } from "react";
import { formatDistanceToNow } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQueryClient } from "@tanstack/react-query";
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  pointerWithin,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type CollisionDetection,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import {
  ListChecks, Check, CircleCheck, CalendarClock, Clock, Flag, FolderInput, GripVertical, Inbox, Plus, Star, StarOff, Sunrise, Trash2, TriangleAlert, X } from "lucide-react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
import { completeTask } from "../shared/task-actions";
import { groupOverdueFirst, todayStartMs, toggleMyDayValue } from "../shared/task-filters";
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
import { midpoint } from "../shared/position";
import { batchSetDueDate, batchUpdateStatus, batchUpdatePriority, batchUpdateFavorite, batchMoveToProject, batchUpdateMyDay } from "../shared/batch-actions";
import { useUndoableDeleteAction, hideManyFromQueries } from "@/hooks/use-undoable-delete";
import { todoTaskDelete, todoTaskUpdate, todoTaskUpdatePosition, type TodoLabel, type TodoProject, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR, PRIORITY_LABELS, TODO_ACCENT, MY_DAY_COLOR } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type DisplayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import { TaskContextMenu } from "./task-context-menu";

interface TaskListViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  /** 任务→标签映射（list-page 级拉取，行内渲染标签 chips） */
  labelsByTask: Map<number, TodoLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，行内渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  /** 空态"新建任务"动作回调（由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  onOpenDetail: (id: number) => void;
  /** 是否允许手动拖拽（仅排序档 manual；#26） */
  sortable?: boolean;
}

/** 截止文案：±15 天内相对时间，否则 MM-dd（04 §3.2） */
function dueText(dueDate: number | null): string | null {
  if (!dueDate) return null;
  const ms = dueDate;
  const diff = Math.abs(ms - Date.now());
  if (diff <= 15 * 24 * 3600 * 1000) {
    return formatDistanceToNow(new Date(ms), { addSuffix: true, locale: zhCN });
  }
  const d = new Date(ms);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** dnd-kit id 形如 "row:<taskId>"，提取数字任务 id */
function rowIdOf(raw: string | number): number {
  const s = String(raw);
  return s.startsWith("row:") ? Number(s.slice(4)) : Number.NaN;
}

/** 行优先碰撞（评审 I3）：pointerWithin 对同含指针的矩形按「到中心距离」排序，
 *  小列表上高大的容器矩形会抢赢行目标、把"插某行前"误判为尾追——
 *  故先只取行命中，无行命中才回落容器。 */
const rowsFirstCollision: CollisionDetection = (args) => {
  const collisions = pointerWithin(args);
  const rowHits = collisions.filter((c) => String(c.id) !== "rows-container");
  return rowHits.length > 0 ? rowHits : collisions;
};

export function TaskListView({ tasks, projects, labelsByTask, remindersByTask, loading, error, onCreateClick, onOpenDetail, sortable = true }: TaskListViewProps) {
  const qc = useQueryClient();
  const scrollRef = useRef<HTMLDivElement>(null);

  // 键盘导航（P1#8）：行 DOM 注册表 + 焦点移动（scrollToIndex 跟随）。
  // 索引口径必须是 stream 而非 tasks：渲染顺序 = 逾期置顶 + 其余，
  // 按 tasks 取 id 会在存在逾期行时聚焦到错位的那一条
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const focusRow = (index: number) => {
    if (index < 0 || index >= stream.length) return;
    virtualizer.scrollToIndex(index, { align: "auto" });
    // 动态 measureElement 下，目标行可能晚一帧才挂载：rAF 重试至多 5 帧
    // （评审 I2 修复，与 Task 3 落地版保持一致）
    let tries = 0;
    const tryFocus = () => {
      const el = rowRefs.current.get(stream[index]?.id);
      if (el) {
        el.focus();
      } else if (++tries < 5) {
        requestAnimationFrame(tryFocus);
      }
    };
    requestAnimationFrame(tryFocus);
  };

  // 逾期置顶（A14）：置顶段与常规段合成**同一条虚拟流**（pinned 长度即分界），
  // 不再单独裸渲染。上一轮口径把逾期区留在虚拟化之外，理由是「逾期集天然有限」，
  // 实测证伪：10k 档 334 条逾期行未过虚拟窗，DOM 节点 955→9980、常驻堆 37→76MB、
  // 每次写重渲染多产生 ~12MB 垃圾（growth-curve 的 domNodes_10k / usedJSHeapMB_10k
  // / peakMB_duringChurn 三项指标同源）。索引语义统一后键盘导航覆盖置顶段。
  // 时间基准随数据变（跨零点拉新数据即换）——不能每渲染帧重建 now，
  // 否则 useMemo 失效：拖拽/选中态每次 set 都全量重跑分组
  const { pinned, stream } = useMemo(() => {
    const { overdue, rest } = groupOverdueFirst(tasks, Date.now());
    return {
      pinned: overdue.length,
      stream: overdue.length > 0 ? [...overdue, ...rest] : rest,
    };
  }, [tasks]);

  // P0 虚拟化：仅渲染可视窗 ± overscan。行高固定 57px（TaskRow h-[57px]），
  // 元信息有无不改变行高——固定尺寸让 estimateSize 与实测恒一致，
  // 消除动态 measure 下滚动/增删行时的高度重排抖动
  const virtualizer = useVirtualizer({
    count: stream.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 57,
    overscan: 8,
    getItemKey: (i) => stream[i].id,
  });

  // 拖拽（P1#11）：PointerSensor distance:6 —— 小位移不算拖拽，保证行点击；
  // hooks 全部集中在早退分支之前，保证无条件执行
  const [draggingId, setDraggingId] = useState<number | null>(null);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
  );

  // ---- 多选批量（P2#17）----
  // anchorId：单击/勾选的最近一行，shift 勾选以它为锚扩区间
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [anchorId, setAnchorId] = useState<number | null>(null);
  const [batchBusy, setBatchBusy] = useState(false);
  // 批量删除确认弹窗（多条误删后撤销心智重，删除前须确认）
  const [confirmBatchDelete, setConfirmBatchDelete] = useState(false);
  const undoableDelete = useUndoableDeleteAction();

  const selectedTasks = useMemo(
    () => tasks.filter((t) => selected.has(t.id)),
    [tasks, selected],
  );
  // 工具条动态文案：全完成→「标记未完成」/「移回待办」，否则按未完成口径处理
  const allDoneSelected = selectedTasks.length > 0 && selectedTasks.every((t) => t.done);

  /** 单行勾选切换；shift 时以 anchor 为锚做 [min,max] 闭区间选择（不并集，可反复改选） */
  const toggleSelect = (id: number, shift: boolean) => {
    if (shift && anchorId != null) {
      const a = tasks.findIndex((t) => t.id === anchorId);
      const b = tasks.findIndex((t) => t.id === id);
      if (a >= 0 && b >= 0) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelected(new Set(tasks.slice(lo, hi + 1).map((t) => t.id)));
        return;
      }
    }
    setAnchorId(id);
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const clearSelection = () => {
    setSelected(new Set());
    setAnchorId(null);
  };

  /** 批量动作执行骨架：跑动作 → 清多选 → 统一失效任务缓存 */
  const runBatch = async (label: string, action: (sel: TodoTask[]) => Promise<unknown>) => {
    const sel = selectedTasks;
    if (sel.length === 0 || batchBusy) return;
    setBatchBusy(true);
    try {
      await action(sel);
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
      toast.success(`已批量${label} ${sel.length} 条任务`, {
        description: "Ctrl+Z 可撤销",
      });
    } catch (e) {
      console.error("批量操作失败:", e);
      toast.error(`批量${label}失败，已完成的条目不回滚`);
    } finally {
      setBatchBusy(false);
      clearSelection();
    }
  };

  /** 批量删除（P2#17）：单笔 undoableDelete（一次隐藏全部 + 一次提交全部），
   *  撤销一键整批恢复。此前实现循环 N 次调用——单槽位 pendingRef 下
   *  第 i 笔会把第 i-1 笔 flush 立即落库（真删），后续 toast 的撤销按钮
   *  全部失效（cancel 已 ran 返回 false），「整批恢复」实际只剩最后一笔。 */
  const batchDelete = (sel: TodoTask[]) => {
    if (sel.length === 0) return;
    const ids = sel.map((t) => t.id);
    undoableDelete({
      entityLabel: "任务",
      count: ids.length,
      hide: (q) => hideManyFromQueries<TodoTask>(q, ["todo_tasks"], ids),
      commit: async () => {
        await Promise.all(ids.map((id) => todoTaskDelete(id)));
      },
    });
    setSelected(new Set());
    setAnchorId(null);
  };

  const handleDragStart = (e: DragStartEvent) => {
    const id = rowIdOf(e.active.id);
    if (!Number.isNaN(id)) setDraggingId(id);
  };

  const handleDragEnd = async (e: DragEndEvent) => {
    const { active, over } = e;
    setDraggingId(null);
    if (!over) return;
    const draggedId = rowIdOf(active.id);
    const idx = tasks.findIndex((t) => t.id === draggedId);
    if (Number.isNaN(draggedId) || idx < 0) return;

    if (String(over.id) === "rows-container") {
      // 容器空白 → 尾部追加
      const last = tasks[tasks.length - 1];
      if (!last || last.id === draggedId) return;
      await todoTaskUpdatePosition(draggedId, midpoint(last.position));
    } else {
      const targetId = rowIdOf(over.id);
      const targetIdx = tasks.findIndex((t) => t.id === targetId);
      if (targetIdx < 0 || targetId === draggedId) return;
      // 目标的前一张已是拖拽行 → 位置未变，免写库
      const prev = tasks[targetIdx - 1];
      if (prev && prev.id === draggedId) return;
      const prevPos = prev && prev.id !== draggedId ? prev.position : undefined;
      await todoTaskUpdatePosition(draggedId, midpoint(prevPos, tasks[targetIdx].position));
    }
    // 排序展示口径在前端 sortTasks(position 升序)，失效后按新 position 重排
    void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
  };

  if (loading) {
    return (
      <div className="flex-1 divide-y divide-border/30 overflow-y-auto" aria-busy="true">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="flex h-[57px] items-center gap-3 px-4">
            <Skeleton className="h-5 w-5 shrink-0 rounded-full" />
            <div className="min-w-0 flex-1 space-y-2">
              <Skeleton className="h-4 w-2/5" />
              <Skeleton className="h-3 w-1/5" />
            </div>
          </div>
        ))}
      </div>
    );
  }
  if (error) {
    return (
      <div className="flex-1 overflow-y-auto p-4">
        <ErrorState message={error} />
      </div>
    );
  }
  if (tasks.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="暂无任务"
          hint="用底部输入栏快速记录，或点击下方按钮"
          action={
            onCreateClick ? (
              <Button size="sm" variant="outline" onClick={onCreateClick}>
                <Plus size={14} className="mr-1" />
                新建任务
              </Button>
            ) : undefined
          }
        />
      </div>
    );
  }

  const projectById = new Map(projects.map((p) => [p.id, p]));
  const toggleFavorite = (t: TodoTask) => {
    void todoTaskUpdate(t.id, { is_favorite: t.is_favorite ? 0 : 1 });
  };
  // 我的一天：加入当天（本地零点）/ 移出（null）。视图按日判断，
  // 昨天加入的任务今天自动退出视图但数据保留（微软 To Do 同款语义）
  const toggleMyDay = (t: TodoTask) => {
    void todoTaskUpdate(t.id, { my_day_date: toggleMyDayValue(t.my_day_date) });
  };
  const draggingTask = draggingId != null ? tasks.find((t) => t.id === draggingId) : undefined;

  const renderRow = (t: TodoTask, vi: { index: number; start: number }) => {
    // 每帧一次 nowMs 供行内 overdue/reminder 判定（此前每行 2 次 Date.now()，
    // 虚拟窗 ~25 行 = 50 次分配/帧）
    const nowMs = Date.now();
    const overdue = !!t.due_date && !t.done && t.due_date < nowMs;
    // 置顶段只换外观与拖拽能力，行为与常规段一致（可点/可勾选/可键盘到达）
    const isPinned = vi.index < pinned;
    const due = dueText(t.due_date);
    const project = t.project_id != null ? projectById.get(t.project_id) : undefined;
    const reminder = displayReminder(remindersByTask.get(t.id) ?? [], nowMs, !!t.done);
    return (
      // 绝对定位行容器：divide-y 在脱离文档流的兄弟间不生效，改每行自带 border-b。
      // 用 top 而非 transform 定位（见文件头注释）
      <div
        key={t.id}
        data-index={vi.index}
        ref={virtualizer.measureElement}
        className={cn(
          isPinned && "bg-destructive/5",
          !isPinned && pinned > 0 && vi.index === pinned && "border-t border-border/30",
        )}
        style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
      >
        <TaskContextMenu task={t} projects={projects} onOpenDetail={() => onOpenDetail(t.id)}>
          <TaskRow
            task={t}
            index={vi.index}
            count={stream.length}
            labels={labelsByTask.get(t.id) ?? []}
            project={project}
            due={due}
            overdue={overdue}
            reminder={reminder}
            dragging={draggingId === t.id}
            selected={selected.has(t.id)}
            hasSelection={selected.size > 0}
            registerRef={(el) => {
              if (el) rowRefs.current.set(t.id, el);
              else rowRefs.current.delete(t.id);
            }}
            onActivate={() => {
              // 有选择态时，行点击切换勾选（与竞品一致）；否则打开详情
              if (selected.size > 0) toggleSelect(t.id, false);
              else onOpenDetail(t.id);
            }}
            onToggleSelect={(shift) => toggleSelect(t.id, shift)}
            onClearSelection={clearSelection}
            onFocusMove={(dir) => focusRow(vi.index + (dir === "down" ? 1 : -1))}
            onToggleDone={() => void completeTask(t)}
            onToggleFavorite={() => toggleFavorite(t)}
            onToggleMyDay={() => toggleMyDay(t)}
            sortable={sortable && !isPinned}
          />
        </TaskContextMenu>
      </div>
    );
  };

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={rowsFirstCollision}
      onDragStart={handleDragStart}
      onDragEnd={(e) => void handleDragEnd(e)}
      onDragCancel={() => setDraggingId(null)}
    >
      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        {/* 逾期段标题（常驻小节点）：段内任务行本身进虚拟流。留在文档流里
            会让虚拟窗整体下偏一个标题高（~29px），远小于 overscan 的 8 行
            （456px），故不出空白；置顶段行进流前该偏移是 N×57px，滚动到
            中段即整屏空白——这也是本轮把两段合一的附带修正 */}
        {pinned > 0 && (
          <div className="flex items-center gap-1.5 bg-destructive/5 px-4 py-1.5">
            <TriangleAlert className="size-3.5 text-destructive" />
            <span className="text-xs font-medium text-destructive">逾期 · {pinned}</span>
          </div>
        )}
        <RowContainerDropZone totalSize={virtualizer.getTotalSize()}>
          {virtualizer.getVirtualItems().map((vi) => renderRow(stream[vi.index], vi))}
        </RowContainerDropZone>
      </div>

      {/* 多选批量工具条（P2#17）：≥1 选中时浮现底部居中。
          排版：计数 + 图标按钮（Tooltip 补语义）+ 分隔线 + 退出；
          优先级/移动项目走 DropdownMenu（点菜单项即执行，无草稿态），
          总宽收敛在 ~420px，窄窗口不与列表滚动区打架。 */}
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

          {/* 批量动作图标按钮：Tooltip 补全语义（纯图标省宽度） */}
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
                    ),
                  ),
              },
              {
                label: allDoneSelected ? "移回待办" : "移入进行中",
                icon: FolderInput,
                run: () =>
                  runBatch(allDoneSelected ? "移回待办" : "移入进行中", (sel) =>
                    batchUpdateStatus(sel, allDoneSelected ? { status: "pending" } : { status: "doing" }),
                  ),
              },
              { label: "加入我的一天", icon: Sunrise, run: () => runBatch("加入我的一天", (sel) => batchUpdateMyDay(sel, true)) },
              { label: "收藏", icon: Star, run: () => runBatch("收藏", (sel) => batchUpdateFavorite(sel, true)) },
              { label: "取消收藏", icon: StarOff, run: () => runBatch("取消收藏", (sel) => batchUpdateFavorite(sel, false)) },
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

          {/* 设置优先级：下拉菜单 6 档色点，点选即执行 */}
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
                <DropdownMenuItem key={lv} onSelect={() => void runBatch("设置优先级", (sel) => batchUpdatePriority(sel, lv))}>
                  {/* 16px 前缀槽 + 色点（含 P0「无」浅灰点），各行文字对齐（与右键菜单同款式） */}
                  <span className="flex w-4 shrink-0 items-center justify-center">
                    <span className="h-2 w-2 rounded-full" style={{ backgroundColor: PRIORITY_COLOR[lv] }} />
                  </span>
                  {label}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>

          {/* 批量改期：档位点选即执行（rescheduleDue 同口径换日期） */}
          <DropdownMenu>
            <Tooltip>
              <TooltipTrigger asChild>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="批量改期" disabled={batchBusy}>
                    <CalendarClock size={14} />
                  </Button>
                </DropdownMenuTrigger>
              </TooltipTrigger>
              <TooltipContent>批量改期</TooltipContent>
            </Tooltip>
            <DropdownMenuContent align="center">
              <DropdownMenuItem onSelect={() => void runBatch("改期到今天", (sel) => batchSetDueDate(sel, "today"))}>今天</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => void runBatch("改期到明天", (sel) => batchSetDueDate(sel, "tomorrow"))}>明天</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => void runBatch("改期到下周一", (sel) => batchSetDueDate(sel, "next_monday"))}>下周一</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => void runBatch("清除截止", (sel) => batchSetDueDate(sel, "clear"))}>清除截止</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>

          {/* 移动到项目：下拉菜单项目色点，点选即执行；未分组作首项 */}
          <DropdownMenu>
            <Tooltip>
              <TooltipTrigger asChild>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="移动到项目" disabled={batchBusy}>
                    <FolderInput size={14} />
                  </Button>
                </DropdownMenuTrigger>
              </TooltipTrigger>
              <TooltipContent>移动到项目</TooltipContent>
            </Tooltip>
            <DropdownMenuContent align="center">
              {projects.length > 0 && (
                <>
                  <DropdownMenuLabel>移动到项目</DropdownMenuLabel>
                  <DropdownMenuSeparator />
                </>
              )}
              <DropdownMenuItem
                onSelect={() =>
                  void runBatch("移动到项目", async (sel) => {
                    await batchMoveToProject(sel, null, tasks);
                  })
                }
              >
                <span className="flex h-2.5 w-2.5 shrink-0 items-center justify-center">
                  <Inbox size={12} className="text-muted-foreground" />
                </span>
                未分组
              </DropdownMenuItem>
              {projects.map((p) => (
                <DropdownMenuItem
                  key={p.id}
                  onSelect={() =>
                    void runBatch("移动到项目", async (sel) => {
                      await batchMoveToProject(sel, p.id, tasks);
                    })
                  }
                >
                  <span className="truncate" style={{ color: p.hex_color || TODO_ACCENT }}>
                    {p.title}
                  </span>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8 text-destructive hover:text-destructive"
                aria-label="删除"
                disabled={batchBusy}
                onClick={() => {
                  if (batchBusy) return;
                  setConfirmBatchDelete(true);
                }}
              >
                <Trash2 size={14} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>删除</TooltipContent>
          </Tooltip>

          <span className="mx-1 h-4 w-px bg-border" />
          <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="退出多选" onClick={clearSelection}>
            <X size={14} />
          </Button>
        </div>
      )}

      {/* 批量删除确认：N 条数量入文案（图标按钮重构后误触概率上升，
          多条删除虽可整批撤销，误删→撤销的心智成本仍高于一次确认） */}
      <AlertDialog open={confirmBatchDelete} onOpenChange={setConfirmBatchDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除 {selectedTasks.length} 条任务</AlertDialogTitle>
            <AlertDialogDescription>
              确定要删除已选的 {selectedTasks.length} 条任务吗？删除后 5 秒内可整批撤销，之后将移入回收站。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                setConfirmBatchDelete(false);
                batchDelete(selectedTasks);
              }}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* 拖拽浮层：简化行副本 */}
      <DragOverlay dropAnimation={null}>
        {draggingTask ? (
          <div className="flex items-center gap-3 rounded-md border bg-background px-4 py-3 shadow-lg">
            <span className="h-5 w-5 shrink-0 rounded-full border-2 border-muted-foreground/30" />
            <span className="max-w-[320px] truncate text-sm">{draggingTask.title}</span>
          </div>
        ) : null}
      </DragOverlay>
    </DndContext>
  );
}

/** 容器 droppable：承接落在末行以下空白处的拖拽（尾部追加）。
 *  min-h-full 让内容不足一屏时容器仍覆盖滚动区全部视口（评审 I2：
 *  否则高度=totalSize 与行矩形完全重合，「移到末位」几何上不可达）。 */
function RowContainerDropZone({ totalSize, children }: { totalSize: number; children: ReactNode }) {
  const { setNodeRef } = useDroppable({ id: "rows-container" });
  return (
    <div
      ref={setNodeRef}
      style={{ height: totalSize, position: "relative" }}
      className="min-h-full"
    >
      {children}
    </div>
  );
}

interface TaskRowProps {
  task: TodoTask;
  index: number;
  count: number;
  labels: TodoLabel[];
  project?: TodoProject;
  due: string | null;
  overdue: boolean;
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder: DisplayReminder | null;
  /** 本行正被拖拽（原始行降透明度，浮层由 DragOverlay 渲染） */
  dragging: boolean;
  /** 多选态（P2#17） */
  selected: boolean;
  /** 任一行被选中时，行点击语义从「打开详情」切换为「切换勾选」 */
  hasSelection: boolean;
  registerRef: (el: HTMLDivElement | null) => void;
  onActivate: () => void;
  /** 勾选框点击（shift=true 为区间选锚点扩展） */
  onToggleSelect: (shift: boolean) => void;
  /** Esc 选中态退选全部 */
  onClearSelection: () => void;
  onFocusMove: (dir: "up" | "down") => void;
  onToggleDone: () => void;
  onToggleFavorite: () => void;
  onToggleMyDay: () => void;
  /** 非 manual 排序档（#26）：隐藏拖拽把手、禁用行拖拽（顺序由排序档决定） */
  sortable: boolean;
}

const TaskRow = memo(function TaskRow({
  task: t,
  index,
  count,
  labels,
  project,
  due,
  overdue,
  reminder,
  dragging,
  selected,
  hasSelection,
  registerRef,
  onActivate,
  onToggleSelect,
  onClearSelection,
  onFocusMove,
  onToggleDone,
  onToggleFavorite,
  onToggleMyDay,
  sortable,
}: TaskRowProps) {
  const inMyDay = t.my_day_date === todayStartMs();
  const { attributes, listeners, setNodeRef: setDragRef } = useDraggable({
    id: `row:${t.id}`,
    // 本行拖拽进行中即禁用拖拽源（浮层副本不再作为拖拽源；边界行禁拖无意义故不处理）；
    // 非 manual 排序档下整体禁拖（#26：顺序由排序档决定，拖拽会立即被覆盖）
    disabled: dragging || !sortable,
  });
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id: `row:${t.id}` });

  return (
    <div
      ref={(el) => {
        setDragRef(el);
        setDropRef(el);
        registerRef(el);
      }}
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className={cn(
        "group relative flex h-[57px] cursor-default items-center gap-3 border-b border-border/30 px-4 hover:bg-accent/30",
        "focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring",
        isOver && "bg-accent/40",
        dragging && "opacity-40",
        selected && "bg-primary/5 ring-1 ring-inset ring-primary/30",
      )}
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return; // IME 组合期不响应
        // x 键切选中（Linear 同款，P2 批量扩展）；Escape 选中态退选全部
        if (e.target === e.currentTarget && (e.key === "x" || e.key === "X")) {
          e.preventDefault();
          onToggleSelect(false);
          return;
        }
        if (e.target === e.currentTarget && e.key === "Escape" && hasSelection) {
          e.preventDefault();
          onClearSelection();
          return;
        }
        // 评审 C1 修复（与 Task 3 落地版一致）：焦点在内层控件上时保留其原生
        // Enter/Space 点击；仅当焦点在本行容器时才拦截为打开详情。j/k 冒泡可用。
        if (e.target === e.currentTarget && isListActivationKey(e.key)) {
          e.preventDefault();
          onActivate();
          return;
        }
        const dir = listNavDirection(e.key);
        if (!dir) return;
        if (index === 0 && dir === "up") return;
        if (index === count - 1 && dir === "down") return;
        e.preventDefault();
        onFocusMove(dir);
      }}
    >
      {/* 优先级左缘竖条（与日历右栏任务行同形制）：六档全显——
          P0「无」浅灰 #D1D5DB 也参与，选择有颜色、列表可见颜色一致 */}
      <span
        aria-hidden
        className="pointer-events-none absolute inset-y-1.5 left-0 w-1 rounded-full"
        style={{ background: PRIORITY_COLOR[t.priority] }}
      />

      {/* 多选勾选框（P2#17）：hover 或已有选中时显现；
          shift 点击 = 以最近一次勾选为锚做区间选择 */}
      <button
        type="button"
        aria-label={selected ? "取消选中" : "选中"}
        aria-pressed={selected}
        className={cn(
          "flex h-5 w-5 shrink-0 items-center justify-center rounded-[4px] border transition-colors",
          selected
            ? "border-primary bg-primary text-primary-foreground"
            : "border-muted-foreground/30 hover:border-primary",
          hasSelection ? "opacity-100" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
        )}
        onClick={(e) => {
          e.stopPropagation();
          onToggleSelect(e.shiftKey);
        }}
      >
        {selected ? (
          <CheckSvg className="size-3.5" stroke={3} />
        ) : null}
      </button>

      {/* 拖拽手柄：hover 显现；点击不冒泡（避免误触打开详情） */}
      {/* 拖拽把手：仅 manual 排序档显示（#26；拖拽源已禁用时同时隐藏） */}
      {sortable && (
        <button
          type="button"
          aria-label="拖拽排序"
          className={cn(
            "shrink-0 cursor-grab touch-none text-muted-foreground/40 transition-opacity hover:text-muted-foreground active:cursor-grabbing",
            hasSelection ? "opacity-0" : "opacity-0 group-hover:opacity-100",
          )}
          onClick={(e) => e.stopPropagation()}
          {...listeners}
          {...attributes}
          tabIndex={-1}
        >
          <GripVertical size={14} />
        </button>
      )}

      {/* 完成 checkbox：圆环 */}
      <button
        type="button"
        aria-label={t.done ? "标记未完成" : "标记完成"}
        className={cn(
          "h-5 w-5 shrink-0 rounded-full border-2 transition-colors",
          t.done ? "border-primary bg-primary" : "border-muted-foreground/30 hover:border-primary",
        )}
        onClick={(e) => {
          e.stopPropagation();
          onToggleDone();
        }}
      >
        {t.done ? <CheckSvg /> : null}
      </button>

      {/* 标题 + 元信息（行高固定 57px：元信息有无不影响行高，
          多行内容整体垂直居中；无元信息时标题独占也居中） */}
      <div className="flex min-w-0 flex-1 flex-col justify-center">
        <div
          className={cn(
            "truncate text-[15px] leading-5",
            t.done && "text-muted-foreground line-through",
          )}
        >
          {t.title}
        </div>
        {(labels.length > 0 || project != null || due || reminder != null || t.percent_done > 0) && (
          <div
            className={cn(
              "mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground",
              overdue && OVERDUE_COLOR_CLASS,
            )}
          >
            <LabelChips labels={labels} />
            {project && (
              <span
                className="truncate"
                style={{ color: project.hex_color || TODO_ACCENT }}
              >
                {project.title}
              </span>
            )}
            {/* 行内提醒徽标（详情抽屉同款双态：未来=Bell / 到期未完=BellRing 红） */}
            <ReminderChip reminder={reminder} />
            {due && (
              <span className="inline-flex items-center gap-0.5">
                <Clock size={11} />
                {due}
              </span>
            )}
            {/* 子任务进度（MS To Do Steps 计数同款体验；percent_done 由后端
                子任务勾选自动回算，0 = 无子任务或不适用不显示） */}
            {t.percent_done > 0 && t.percent_done < 100 && (
              <span className="inline-flex items-center gap-0.5 tabular-nums">
                <ListChecks size={11} />
                {Math.round(t.percent_done)}%
              </span>
            )}
          </div>
        )}
      </div>

      {/* 我的一天：今天已加入时常显（Sunrise 实心），否则 hover 显现 */}
      <button
        type="button"
        aria-label={inMyDay ? "移出我的一天" : "加入我的一天"}
        className={cn(
          "shrink-0",
          inMyDay ? "opacity-100" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
        )}
        style={inMyDay ? { color: MY_DAY_COLOR } : undefined}
        onClick={(e) => {
          e.stopPropagation();
          onToggleMyDay();
        }}
      >
        <Sunrise size={16} fill={inMyDay ? "currentColor" : "none"} />
      </button>

      {/* 星标：hover 显现 */}
      <button
        type="button"
        aria-label={t.is_favorite ? "取消收藏" : "收藏"}
        className={cn(
          "shrink-0",
          t.is_favorite
            ? "opacity-100"
            : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
        )}
        style={{ color: FAVORITE_COLOR }}
        onClick={(e) => {
          e.stopPropagation();
          onToggleFavorite();
        }}
      >
        <Star size={16} fill={t.is_favorite ? "currentColor" : "none"} />
      </button>
    </div>
  );
}, taskRowPropsEqual);

/**
 * TaskRow memo 比较器：忽略函数 props（registerRef/onToggle 等内联箭头
 * 每次渲染新引用，默认浅比较必然击穿）；业务字段全量比较——拖拽态
 * （dragging）、选中态（selected/hasSelection）、数据态变化精确重渲染。
 */
function taskRowPropsEqual(prev: TaskRowProps, next: TaskRowProps): boolean {
  return (
    prev.task === next.task &&
    prev.index === next.index &&
    prev.count === next.count &&
    prev.labels === next.labels &&
    prev.project === next.project &&
    prev.due === next.due &&
    prev.overdue === next.overdue &&
    prev.reminder === next.reminder &&
    prev.dragging === next.dragging &&
    prev.selected === next.selected &&
    prev.hasSelection === next.hasSelection &&
    prev.sortable === next.sortable
  );
}

/** 完成态对勾（04 §3.2：白勾 SVG；多选勾选框复用，参数化尺寸/线宽） */
export function CheckSvg({ className = "m-auto size-3 text-white", stroke = 3 }: { className?: string; stroke?: number }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
    >
      <path d="M20 6L9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
