/**
 * KanbanView — 看板视图（04 文档 §3.3 复刻）
 *
 * - 分列：按项目（未分组归"未分组"，列序 localeCompare）或按状态（pending→doing→done 固定）
 * - 卡片同时挂 useDraggable + useDroppable；PointerSensor distance:5
 * - 拖拽语义：同列落卡片 → 插到目标前；同列空白 → 追加；异列 → 先改归属再排序。
 *   position 一律取中值算法写入（03 文档 §一）。
 */
import { useMemo, useRef, useState } from "react";
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
}

interface ColumnDef {
  key: string;
  title: string;
  color: string;
}

export function KanbanView({ tasks, projects, groupBy, labelsByTask }: KanbanViewProps) {
  const qc = useQueryClient();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const [draggingId, setDraggingId] = useState<number | null>(null);
  // 拖拽刚结束的时间戳：抑制 dragend 后误触发的卡片 click（打开详情）
  const dragEndStamp = useRef(0);
  // PointerSensor distance:5（04 §3.3：位移 5px 内不算拖拽，保证点击）
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
  );

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
    for (const p of [...projects].sort((a, b) => a.title.localeCompare(b.title))) {
      byKey.set(String(p.id), { key: String(p.id), title: p.title, color: TODO_ACCENT });
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
    for (const list of map.values()) {
      list.sort((a, b) => {
        if (a.position !== b.position) return a.position - b.position;
        return b.created_at - a.created_at;
      });
    }
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
        // 同列空白 → 追加到末尾
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
      // 同列插到目标前：取目标与前一张卡片的中值
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
              draggingId={draggingId}
              dragEndStamp={dragEndStamp}
              onOpenDetail={(id) => setSelectedTaskId(id)}
            />
          ))}
        </div>

        <DragOverlay dropAnimation={null}>
          {draggingTask ? (
            <KanbanCard
              task={draggingTask}
              labels={labelsByTask.get(draggingTask.id) ?? []}
              overlay
            />
          ) : null}
        </DragOverlay>
      </DndContext>
    </div>
  );
}

/* ================= 列 ================= */

function KanbanColumn({
  column,
  tasks,
  projects,
  labelsByTask,
  draggingId,
  dragEndStamp,
  onOpenDetail,
}: {
  column: ColumnDef;
  tasks: TodoTask[];
  projects: TodoProject[];
  labelsByTask: Map<number, TodoLabel[]>;
  draggingId: number | null;
  /** 拖拽结束时间戳 ref（点击抑制用） */
  dragEndStamp: React.RefObject<number>;
  onOpenDetail: (id: number) => void;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${column.key}` });

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

      {/* 卡片区：flex+gap 控制卡片间距。不可用 space-y——卡片被 ContextMenuBase 的
          display:contents 包裹层与 fixed 哨兵隔开，margin 落在无盒子元素上不生效 */}
      <div ref={setNodeRef} className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto p-2">
        {tasks.length === 0 ? (
          <div className="flex h-20 items-center justify-center text-xs text-muted-foreground/40">
            拖拽任务到此处
          </div>
        ) : (
          tasks.map((t) => (
            <TaskContextMenu
              key={t.id}
              task={t}
              projects={projects}
              onOpenDetail={() => onOpenDetail(t.id)}
            >
              <KanbanCard
                task={t}
                labels={labelsByTask.get(t.id) ?? []}
                dragging={draggingId === t.id}
                dragEndStamp={dragEndStamp}
                onOpenDetail={onOpenDetail}
              />
            </TaskContextMenu>
          ))
        )}
      </div>
    </div>
  );
}

/* ================= 卡片 ================= */

function KanbanCard({
  task,
  labels,
  dragging,
  overlay,
  dragEndStamp,
  onOpenDetail,
}: {
  task: TodoTask;
  labels: TodoLabel[];
  dragging?: boolean;
  overlay?: boolean;
  /** 拖拽结束时间戳 ref（overlay 不需要） */
  dragEndStamp?: React.RefObject<number>;
  onOpenDetail?: (id: number) => void;
}) {
  const draggable = useDraggable({ id: `task:${task.id}`, disabled: !!overlay });
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
        "cursor-grab rounded-md border border-border/50 bg-card p-3 shadow-sm hover:shadow-md active:cursor-grabbing",
        dragging && "opacity-40",
        isOver && !dragging && "ring-2 ring-primary/40",
        overlay && "border-primary/40 shadow-xl",
        overlay && "cursor-grabbing",
      )}
    >
      {/* 优先级条；未设优先级（P0）按「低」的灰色显示，保证所有卡片都有色条 */}
      <div
        className="mb-2 h-0.5 rounded-full"
        style={{ background: PRIORITY_COLOR[task.priority] || PRIORITY_COLOR[1] }}
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
      {(task.due_date != null || task.percent_done > 0) && (
        <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
          {task.due_date != null && (
            <span className="inline-flex items-center gap-1">
              <Calendar size={10} />
              {format(new Date(task.due_date), "MM-dd")}
            </span>
          )}
          {task.percent_done > 0 && <span>{Math.round(task.percent_done)}%</span>}
        </div>
      )}
    </div>
  );
}

/** overlay 场景无需 droppable/draggable 注册 */
function setNodeRefNull(_node: HTMLElement | null) {}
