/**
 * TaskListView — 任务列表行（04 文档 §3.2 复刻）
 *
 * 行规格：圆形 checkbox（done 联动 status/done_at）+ 标题（划线）+
 * 元信息行（优先级色点/项目名/截止时间，逾期整段红）+ hover 星标。
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
import { useMemo, useRef, useState, type ReactNode } from "react";
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
import { Check, CircleCheck, Clock, Flag, FolderInput, GripVertical, Inbox, Plus, Star, StarOff, Sunrise, Trash2, X } from "lucide-react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
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
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
import { midpoint } from "../shared/position";
import { batchUpdateStatus, batchUpdatePriority, batchUpdateFavorite, batchMoveToProject, batchUpdateMyDay } from "../shared/batch-actions";
import { useUndoableDeleteAction, hideFromQueries } from "@/hooks/use-undoable-delete";
import { todoTaskDelete, todoTaskUpdate, todoTaskUpdatePosition, type TodoLabel, type TodoProject, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR, PRIORITY_LABELS, TODO_ACCENT } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { TaskContextMenu } from "./task-context-menu";

interface TaskListViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  /** 任务→标签映射（list-page 级拉取，行内渲染标签 chips） */
  labelsByTask: Map<number, TodoLabel[]>;
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  /** 空态"新建任务"动作回调（由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  onOpenDetail: (id: number) => void;
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

export function TaskListView({ tasks, projects, labelsByTask, loading, error, onCreateClick, onOpenDetail }: TaskListViewProps) {
  const qc = useQueryClient();
  const scrollRef = useRef<HTMLDivElement>(null);

  // 键盘导航（P1#8）：行 DOM 注册表 + 焦点移动（scrollToIndex 跟随）
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const focusRow = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    virtualizer.scrollToIndex(index, { align: "auto" });
    // 动态 measureElement 下，目标行可能晚一帧才挂载：rAF 重试至多 5 帧
    // （评审 I2 修复，与 Task 3 落地版保持一致）
    let tries = 0;
    const tryFocus = () => {
      const el = rowRefs.current.get(tasks[index]?.id);
      if (el) {
        el.focus();
      } else if (++tries < 5) {
        requestAnimationFrame(tryFocus);
      }
    };
    requestAnimationFrame(tryFocus);
  };

  // P0 虚拟化：仅渲染可视窗 ± overscan。行高估算 57（py-3×2 + 标题20 + meta16 + 边框）
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 57,
    overscan: 8,
    getItemKey: (i) => tasks[i].id,
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
      toast.success(`已批量${label} ${sel.length} 条任务`);
    } catch (e) {
      console.error("批量操作失败:", e);
      toast.error(`批量${label}失败，已完成的条目不回滚`);
    } finally {
      setBatchBusy(false);
      clearSelection();
    }
  };

  /** 批量删除（P2#17）：分批顺序提交；复用 use-undoable-delete 的
   *  乐观隐藏 + 5s 撤销窗口语义（隐藏立即生效、超时统一真删）。 */
  const batchDelete = (sel: TodoTask[]) => {
    if (sel.length === 0) return;
    const ids = sel.map((t) => t.id);
    const shownIds = new Set(ids);
    for (const t of sel) {
      undoableDelete({
        entityLabel: "任务",
        recordName: t.title,
        hide: (q) => hideFromQueries<TodoTask>(q, ["todo_tasks"], t.id),
        commit: async () => {
          await Promise.all(ids.map((id) => todoTaskDelete(id)));
          shownIds.clear();
        },
      });
    }
    // 撤销语义：整批恢复（单槽位撤销 = 恢复全部被隐藏行）
    void toast.info(`已删除 ${ids.length} 条任务`, {
      description: "撤销将恢复本次全部删除",
    });
    // 撤销按钮由每条 toast 自带；批量场景下点任意一条的撤销都调
    // invalidateQueries 恢复全部隐藏行（DB 未提交），提交窗口后统一落库。
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
          <div key={i} className="flex items-center gap-3 px-4 py-3">
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
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    void todoTaskUpdate(t.id, {
      my_day_date: t.my_day_date === today.getTime() ? null : today.getTime(),
    });
  };
  const draggingTask = draggingId != null ? tasks.find((t) => t.id === draggingId) : undefined;

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={rowsFirstCollision}
      onDragStart={handleDragStart}
      onDragEnd={(e) => void handleDragEnd(e)}
      onDragCancel={() => setDraggingId(null)}
    >
      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        <RowContainerDropZone totalSize={virtualizer.getTotalSize()}>
          {virtualizer.getVirtualItems().map((vi) => {
            const t = tasks[vi.index];
            const overdue = !!t.due_date && !t.done && t.due_date < Date.now();
            const due = dueText(t.due_date);
            const projectName = t.project_id != null ? projectById.get(t.project_id)?.title : undefined;
            return (
              // 绝对定位行容器：divide-y 在脱离文档流的兄弟间不生效，改每行自带 border-b。
              // 用 top 而非 transform 定位（见文件头注释）
              <div
                key={t.id}
                data-index={vi.index}
                ref={virtualizer.measureElement}
                style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
              >
                <TaskContextMenu task={t} projects={projects} onOpenDetail={() => onOpenDetail(t.id)}>
                  <TaskRow
                    task={t}
                    index={vi.index}
                    count={tasks.length}
                    labels={labelsByTask.get(t.id) ?? []}
                    projectName={projectName}
                    due={due}
                    overdue={overdue}
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
                    onFocusMove={(dir) => focusRow(vi.index + (dir === "down" ? 1 : -1))}
                    onToggleDone={() => void completeTask(t)}
                    onToggleFavorite={() => toggleFavorite(t)}
                    onToggleMyDay={() => toggleMyDay(t)}
                  />
                </TaskContextMenu>
              </div>
            );
          })}
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
                  {/* 固定 16px 前缀槽：无优先级留空也占位，保证各行文字对齐（与右键菜单同款式） */}
                  <span className="flex w-4 shrink-0 items-center justify-center">
                    {lv > 0 && <span className="h-2 w-2 rounded-full" style={{ backgroundColor: PRIORITY_COLOR[lv] }} />}
                  </span>
                  {label}
                </DropdownMenuItem>
              ))}
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
                  <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: p.hex_color || TODO_ACCENT }} />
                  {p.title}
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
                  batchDelete(selectedTasks);
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
  projectName?: string;
  due: string | null;
  overdue: boolean;
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
  onFocusMove: (dir: "up" | "down") => void;
  onToggleDone: () => void;
  onToggleFavorite: () => void;
  onToggleMyDay: () => void;
}

function TaskRow({
  task: t,
  index,
  count,
  labels,
  projectName,
  due,
  overdue,
  dragging,
  selected,
  hasSelection,
  registerRef,
  onActivate,
  onToggleSelect,
  onFocusMove,
  onToggleDone,
  onToggleFavorite,
  onToggleMyDay,
}: TaskRowProps) {
  const myDayToday = new Date();
  myDayToday.setHours(0, 0, 0, 0);
  const inMyDay = t.my_day_date === myDayToday.getTime();
  const { attributes, listeners, setNodeRef: setDragRef } = useDraggable({
    id: `row:${t.id}`,
    // 本行拖拽进行中即禁用拖拽源（浮层副本不再作为拖拽源；边界行禁拖无意义故不处理）
    disabled: dragging,
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
        "group relative flex cursor-default items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30",
        "focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring",
        isOver && "bg-accent/40",
        dragging && "opacity-40",
        selected && "bg-primary/5 ring-1 ring-inset ring-primary/30",
      )}
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return; // IME 组合期不响应
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
      {/* 优先级色条（行底部 2px，与看板卡顶部色条同语义）；
          未设优先级（P0）按「低」的灰色显示，保证所有行都有色条 */}
      <span
        aria-hidden
        className="pointer-events-none absolute inset-x-0 bottom-0 h-0.5"
        style={{ background: PRIORITY_COLOR[t.priority] || PRIORITY_COLOR[1] }}
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

      {/* 标题 + 元信息 */}
      <div className="min-w-0 flex-1">
        <div
          className={cn(
            "truncate text-[15px] leading-5",
            t.done && "text-muted-foreground line-through",
          )}
        >
          {t.title}
        </div>
        {(t.priority > 0 || labels.length > 0 || projectName || due) && (
          <div
            className={cn(
              "mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground",
              overdue && OVERDUE_COLOR_CLASS,
            )}
          >
            <LabelChips labels={labels} />
            {projectName && <span>{projectName}</span>}
            {due && (
              <span className="inline-flex items-center gap-0.5">
                <Clock size={11} />
                {due}
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
        style={inMyDay ? { color: "#F59E0B" } : undefined}
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
}

/** 完成态对勾（04 §3.2：白勾 SVG；多选勾选框复用，参数化尺寸/线宽） */
function CheckSvg({ className = "m-auto size-3 text-white", stroke = 3 }: { className?: string; stroke?: number }) {
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
