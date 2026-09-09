/**
 * KanbanView — 看板视图（04 文档 §3.3 复刻）
 *
 * - 分列：按项目（未分组归"未分组"，列序 localeCompare）或按状态（pending→doing→done 固定）
 * - 卡片同时挂 useDraggable + useDroppable；PointerSensor distance:5
 * - 拖拽语义：同列落卡片 → 插到目标前；同列空白 → 追加；异列 → 先改归属再排序。
 *   position 一律取中值算法写入（03 文档 §一）。
 * - 排序（#26）：列内保留父层传入序（task-panel 已按工具栏档位 sortTasks），
 *   本视图不再 position 重排——否则截止/优先级/标题/创建档在看板全部失效。
 *   仅 manual 档允许拖拽重排（与列表视图 sortable 口径一致）；跨列移动
 *   （改归属）任何档位都允许，落位仍走 position 中值。
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
} from "@dnd-kit/core";
import { format } from "date-fns";
import { Calendar, Check, Star } from "lucide-react";

import { cn } from "@/lib/utils";
import { useTodoStore } from "@/features/todo/store";
import {
  todoTaskUpdate,
  todoTaskUpdatePosition,
  type TodoLabel,
  type TodoProject,
  type TodoTask,
} from "@/lib/tauri";
import { FAVORITE_COLOR, PRIORITY_COLOR, STATUS_COLOR, TODO_ACCENT } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type DisplayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import type { TaskSortKey } from "../shared/task-filters";
import { completeTask } from "../shared/task-actions";
import { midpoint } from "../shared/position";
import { TaskContextMenu } from "./task-context-menu";

export type KanbanGroupBy = "project" | "status";

interface KanbanViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  groupBy: KanbanGroupBy;
  /** 任务→标签映射（list-page 级拉取，卡片渲染标签 chips） */
  labelsByTask: Map<number, TodoLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，卡片渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  /** 工具栏排序档位（#26）：列内沿用传入序；manual 才允许拖拽重排 */
  sortKey: TaskSortKey;
}

interface ColumnDef {
  key: string;
  title: string;
  color: string;
}

export function KanbanView({ tasks, projects, groupBy, labelsByTask, remindersByTask, sortKey }: KanbanViewProps) {
  const qc = useQueryClient();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  // memo 友好：打开详情回调恒定引用，列/卡片 props 只随业务数据变化
  const openDetail = useCallback((id: number) => setSelectedTaskId(id), [setSelectedTaskId]);
  const [draggingId, setDraggingId] = useState<number | null>(null);
  // 拖拽刚结束的时间戳：抑制 dragend 后误触发的卡片 click（打开详情）
  const dragEndStamp = useRef(0);
  // PointerSensor distance:5（04 §3.3：位移 5px 内不算拖拽，保证点击）
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
  );
  // #26：仅拖拽顺序档允许拖拽重排（列内顺序由排序档决定，拖了也会被
  // 覆盖）；跨列移动改归属不受档位限制，见 handleDragEnd
  const sortable = sortKey === "manual";

  // ---- 分列 ----
  const columns = useMemo<ColumnDef[]>(() => {
    if (groupBy === "status") {
      return [
        { key: "pending", title: "待办", color: STATUS_COLOR.pending },
        { key: "doing", title: "进行中", color: STATUS_COLOR.doing },
        { key: "done", title: "已完成", color: STATUS_COLOR.done },
      ];
    }
    const byKey = new Map<string, ColumnDef>();
    // #36：项目列头用项目自身颜色（原来统一 TODO_ACCENT）
    for (const p of [...projects].sort((a, b) => a.title.localeCompare(b.title))) {
      byKey.set(String(p.id), { key: String(p.id), title: p.title, color: p.hex_color || TODO_ACCENT });
    }
    byKey.set("ungrouped", { key: "ungrouped", title: "未分组", color: TODO_ACCENT });
    return [...byKey.values()];
  }, [groupBy, projects]);

  const grouped = useMemo(() => {
    const map = new Map<string, TodoTask[]>();
    for (const col of columns) map.set(col.key, []);
    for (const t of tasks) {
      const key =
        groupBy === "status"
          ? t.status
          : t.project_id != null
            ? String(t.project_id)
            : "ungrouped";
      (map.get(key) ?? map.get("ungrouped")!).push(t);
    }
    // 列内保留父层传入序（工具栏 sortTasks 档位）——此处若再按
    // position 重排，非拖拽档的排序选择在看板将全部失效
    return map;
  }, [tasks, columns, groupBy]);

  const refetchTasks = () => void qc.invalidateQueries({ queryKey: ["todo_tasks"] });

  /** 异列：先改归属（project_id 或 status/done 联动），由调用方继续处理排序 */
  const moveAcross = async (taskId: number, colKey: string) => {
    if (groupBy === "project") {
      const pid = colKey === "ungrouped" ? null : Number(colKey);
      await todoTaskUpdate(taskId, { project_id: pid });
    } else if (colKey === "done") {
      const task = tasks.find((t) => t.id === taskId);
      if (task) await completeTask(task);
    } else {
      await todoTaskUpdate(taskId, { status: colKey, done: 0, done_at: null });
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
        if (!sortable) return;
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
      // 非拖拽档下顺序由排序档决定，写入立即被覆盖，跳过
      if (!sortable) return;
      const list = grouped.get(targetCol) ?? [];
      const idx = list.findIndex((t) => t.id === targetId);
      const prev = idx > 0 ? list[idx - 1] : undefined;
      if (prev?.id === taskId) return;
      await reorder(taskId, prev?.id ?? null, targetId);
    }
    refetchTasks();
  };

  const columnKeyOf = (t: TodoTask): string =>
    groupBy === "status" ? t.status : t.project_id != null ? String(t.project_id) : "ungrouped";

  const draggingTask = draggingId != null ? tasks.find((t) => t.id === draggingId) : undefined;

  return (
    <div
      className={cn(
        "min-h-0 flex-1",
        draggingId != null ? "overflow-x-hidden" : "overflow-x-auto",
      )}
    >
      <DndContext
        sensors={sensors}
        collisionDetection={pointerWithin}
        onDragStart={handleDragStart}
        onDragEnd={(e) => void handleDragEnd(e)}
      >
        <div className="flex h-full gap-4 p-4">
          {columns.map((col) => (
            <KanbanColumn
              key={col.key}
              column={col}
              tasks={grouped.get(col.key) ?? []}
              projects={projects}
              labelsByTask={labelsByTask}
              remindersByTask={remindersByTask}
              draggingId={draggingId}
              dragEndStamp={dragEndStamp}
              onOpenDetail={openDetail}
              sortable={sortable}
            />
          ))}
        </div>

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
const KanbanColumn = memo(function KanbanColumn({
  column,
  tasks,
  projects,
  labelsByTask,
  remindersByTask,
  draggingId,
  dragEndStamp,
  onOpenDetail,
  sortable,
}: {
  column: ColumnDef;
  tasks: TodoTask[];
  projects: TodoProject[];
  labelsByTask: Map<number, TodoLabel[]>;
  remindersByTask: Map<number, TaskReminderMeta[]>;
  draggingId: number | null;
  /** 拖拽结束时间戳 ref（点击抑制用） */
  dragEndStamp: React.RefObject<number>;
  onOpenDetail: (id: number) => void;
  /** 仅拖拽顺序档允许拖拽（#26）；跨列移动始终可用 */
  sortable: boolean;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${column.key}` });
  const scrollRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 76,
    overscan: 6,
    getItemKey: (i) => tasks[i].id,
  });

  return (
    <div
      className={cn(
        "flex w-72 shrink-0 flex-col rounded-lg border bg-muted/20",
        isOver ? "border-primary/40 bg-muted/40" : "border-border/50",
      )}
    >
      {/* 列头 */}
      <div className="flex items-center gap-2 border-b px-3 py-2">
        <span className="h-2 w-2 rounded-full" style={{ background: column.color }} />
        <span className="text-sm font-medium">{column.title}</span>
        <span className="text-xs text-muted-foreground">{tasks.length}</span>
      </div>

      {/* 卡片区：虚拟化行容器（绝对定位行 + gap 以 padding 计入 estimate 初值）。
          原 flex+gap 控制间距的说明已随虚拟化失效——间距改由行容器的 margin 承担 */}
      <div
        ref={(node) => {
          setNodeRef(node);
          // 同一 node 双注册：droppable 区 + 虚拟化滚动容器
          scrollRef.current = node;
        }}
        className="flex min-h-0 flex-1 flex-col overflow-y-auto p-2"
      >
        {tasks.length === 0 ? (
          <div className="flex h-20 items-center justify-center text-xs text-muted-foreground/40">
            拖拽任务到此处
          </div>
        ) : (
          <div
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
                  >
                    <KanbanCard
                      task={t}
                      labels={labelsByTask.get(t.id) ?? []}
                      reminder={displayReminder(remindersByTask.get(t.id) ?? [], Date.now(), !!t.done)}
                      dragging={draggingId === t.id}
                      dragEndStamp={dragEndStamp}
                      onOpenDetail={onOpenDetail}
                      sortable={sortable}
                    />
                  </TaskContextMenu>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
});

/* ================= 卡片 ================= */

const KanbanCard = memo(function KanbanCard({
  task,
  labels,
  reminder,
  dragging,
  overlay,
  dragEndStamp,
  onOpenDetail,
  sortable = true,
}: {
  task: TodoTask;
  labels: TodoLabel[];
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder: DisplayReminder | null;
  dragging?: boolean;
  overlay?: boolean;
  /** 拖拽结束时间戳 ref（overlay 不需要） */
  dragEndStamp?: React.RefObject<number>;
  onOpenDetail?: (id: number) => void;
  /** 仅拖拽顺序档可拖（#26）；跨列移动的落点仍注册（droppable 不受影响） */
  sortable?: boolean;
}) {
  const draggable = useDraggable({ id: `task:${task.id}`, disabled: !!overlay || !sortable });
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id: `task:${task.id}` });

  return (
    <div
      ref={(node) => {
        if (!overlay) {
          draggable.setNodeRef(node);
          setDropRef(node);
        } else {
          setNodeRefNull(node);
        }
      }}
      {...(overlay ? {} : draggable.attributes)}
      {...(overlay ? {} : draggable.listeners)}
      style={{ touchAction: "none" }}
      onClick={() => {
        // 拖拽松手后的 click 不视为点击打开详情
        if (dragEndStamp && Date.now() - dragEndStamp.current < 250) return;
        if (!overlay && !dragging) onOpenDetail?.(task.id);
      }}
      className={cn(
        "rounded-md border border-border/50 bg-card p-3 shadow-sm hover:shadow-md",
        sortable && "cursor-grab active:cursor-grabbing",
        dragging && "opacity-40",
        isOver && !dragging && "ring-2 ring-primary/40",
        overlay && "border-primary/40 shadow-xl",
        overlay && "cursor-grabbing",
      )}
    >
      {/* 优先级条（卡片顶部 2px）：六档全显——P0「无」浅灰 #D1D5DB 也参与 */}
      <div
        className="mb-2 h-0.5 rounded-full"
        style={{ background: PRIORITY_COLOR[task.priority] }}
      />

      {/* 标题行：完成勾 + 标题 + 星标 */}
      <div className="flex items-start gap-1.5">
        {task.done ? <Check size={14} className="mt-0.5 shrink-0 text-success" /> : null}
        <span
          className={cn(
            // break-words：长连续文本（URL/长英文串无空格断点）在卡内强制断行，
            // 否则整串不换行撑出卡片右缘
            "min-w-0 flex-1 break-words text-sm font-medium leading-5",
            task.done && "text-muted-foreground line-through",
          )}
        >
          {task.title}
        </span>
        {!!task.is_favorite && <Star size={13} style={{ color: FAVORITE_COLOR }} fill="currentColor" />}
      </div>

      {/* 标签 chips（标签自选色） */}
      {labels.length > 0 && (
        <div className="mt-1.5">
          <LabelChips labels={labels} max={2} />
        </div>
      )}

      {/* 底部元信息 */}
      {(task.due_date != null || reminder != null || task.percent_done > 0) && (
        <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
          {task.due_date != null && (
            <span className="inline-flex items-center gap-1">
              <Calendar size={10} />
              {format(new Date(task.due_date), "MM-dd")}
            </span>
          )}
          <ReminderChip reminder={reminder} />
          {task.percent_done > 0 && <span>{Math.round(task.percent_done)}%</span>}
        </div>
      )}
    </div>
  );
});

/** overlay 场景无需 droppable/draggable 注册 */
function setNodeRefNull(_node: HTMLElement | null) {}
