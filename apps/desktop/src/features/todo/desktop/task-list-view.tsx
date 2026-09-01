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
 */
import { useRef, useState, type ReactNode } from "react";
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
import { Clock, GripVertical, Inbox, Plus, Star } from "lucide-react";
import { useVirtualizer } from "@tanstack/react-virtual";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
import { completeTask } from "../shared/task-actions";
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
import { midpoint } from "../shared/position";
import { todoTaskUpdate, todoTaskUpdatePosition, type TodoLabel, type TodoProject, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR } from "../shared/constants";
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
                    registerRef={(el) => {
                      if (el) rowRefs.current.set(t.id, el);
                      else rowRefs.current.delete(t.id);
                    }}
                    onActivate={() => onOpenDetail(t.id)}
                    onFocusMove={(dir) => focusRow(vi.index + (dir === "down" ? 1 : -1))}
                    onToggleDone={() => void completeTask(t)}
                    onToggleFavorite={() => toggleFavorite(t)}
                  />
                </TaskContextMenu>
              </div>
            );
          })}
        </RowContainerDropZone>
      </div>

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
  registerRef: (el: HTMLDivElement | null) => void;
  onActivate: () => void;
  onFocusMove: (dir: "up" | "down") => void;
  onToggleDone: () => void;
  onToggleFavorite: () => void;
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
  registerRef,
  onActivate,
  onFocusMove,
  onToggleDone,
  onToggleFavorite,
}: TaskRowProps) {
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

      {/* 拖拽手柄：hover 显现；点击不冒泡（避免误触打开详情） */}
      <button
        type="button"
        aria-label="拖拽排序"
        className="shrink-0 cursor-grab touch-none text-muted-foreground/40 opacity-0 transition-opacity hover:text-muted-foreground group-hover:opacity-100 active:cursor-grabbing"
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

/** 完成态白色对勾（04 §3.2：白勾 SVG） */
function CheckSvg() {
  return (
    <svg
      viewBox="0 0 24 24"
      className="m-auto size-3 text-white"
      fill="none"
      stroke="currentColor"
      strokeWidth={3}
    >
      <path d="M20 6L9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
