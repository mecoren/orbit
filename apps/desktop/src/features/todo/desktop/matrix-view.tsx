/**
 * MatrixView — 四象限视图（Eisenhower Matrix，TickTick 同款；移动端 2026-09-25
 * 先落地，桌面端对齐补齐。轴口径见 groupEisenhower：重要 = 优先级≥高(3)，
 * 紧急 = 截止≤今天末（本地日界，含逾期）；已完成不入桶，完成历史走侧栏「已完成」）
 *
 * 桌面形态取舍：宽屏一屏摆得下四格，**恒定 2×2**（不做移动端的概览→下钻两态）；
 * 每格 = 象限色带 + 格头（行动短语 / 轴文案 / 计数）+ 格内独立虚拟化列表——
 * 整列表渲染一律过 useVirtualizer（内存门禁 domNodesSlope 哨兵口径）。
 * 行信息层级与 TaskRow 同源（优先级左缘竖条 / 勾选 / 标签 / 项目 / 提醒 /
 * 截止 / 子任务进度），交互收敛为勾选完成 + 点击开详情 + hover 收藏：
 * 拖拽重排与多选批量在象限分桶下语义不成立（顺序被桶位覆盖）。
 */
import { memo, useCallback, useMemo, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Clock, Grid2x2, Star } from "lucide-react";

import { cn } from "@/lib/utils";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
import { completeTask } from "../shared/task-actions";
import {
  EISENHOWER_META,
  groupEisenhower,
  type EisenhowerQuadrant,
} from "../shared/task-filters";
import { todoTaskUpdate, type ProjectedTaskLabel, type TodoProject, type TodoTask } from "@/lib/tauri";
import { patchQueriesData } from "@/lib/query-patch";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";
import { LabelChips } from "../shared/label-chips";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder, type TaskReminderMeta } from "../shared/reminder-meta";
import { dueTextOf } from "./task-table-view";

export interface MatrixViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  /** 任务→标签映射（TaskPanel 级拉取，行内渲染标签 chips） */
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  /** 任务→提醒映射（TaskPanel 级拉取，行内渲染提醒徽标） */
  remindersByTask: Map<number, TaskReminderMeta[]>;
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  onOpenDetail: (id: number) => void;
}

/** 格内行固定高（estimateSize 与实测恒一致，同 task-list-view 的 57 口径） */
const ROW_HEIGHT = 50;

/** 象限渲染顺序（枚举序 = 先重要后次要、先紧急后不紧急）与识别色带
 *  （全走既有语义类：destructive / primary / warning / 中性灰，零新增色值） */
const QUADRANT_ORDER: EisenhowerQuadrant[] = [
  "urgentImportant",
  "importantNotUrgent",
  "urgentNotImportant",
  "neither",
];

const QUADRANT_TINT: Record<EisenhowerQuadrant, string> = {
  urgentImportant: "bg-destructive",
  importantNotUrgent: "bg-primary",
  urgentNotImportant: "bg-warning",
  neither: "bg-muted-foreground/60",
};

export function MatrixView({
  tasks,
  projects,
  labelsByTask,
  remindersByTask,
  loading,
  error,
  onOpenDetail,
}: MatrixViewProps) {
  const qc = useQueryClient();

  // 分组随数据变（now 不每帧重建：同 task-list-view 口径，拖拽/选中态
  // 每次 set 不全量重跑分组——本视图无拖拽，但保持同一基准习惯）
  const buckets = useMemo(() => groupEisenhower(tasks, new Date()), [tasks]);
  const projectById = useMemo(
    () => new Map(projects.map((p) => [p.id, p])),
    [projects],
  );

  // 行动作（stable 引用：行 memo 比较器忽略函数 props，这里收口成 useCallback
  // 纯属习惯——写路径语义与 task-list-view 逐字同源）
  const toggleDone = useCallback(
    (t: TodoTask) => {
      void completeTask(t, qc);
    },
    [qc],
  );
  const toggleFavorite = useCallback((t: TodoTask) => {
    // 乐观翻转（D3）：纯字段，先 paint 后收敛（失效链仍在）
    patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], {
      is_favorite: t.is_favorite ? 0 : 1,
    });
    void todoTaskUpdate(t.id, { is_favorite: t.is_favorite ? 0 : 1 });
  }, [qc]);

  if (loading) {
    return (
      <div className="grid min-h-0 flex-1 grid-cols-2 grid-rows-2 gap-3 p-3" aria-busy="true">
        {QUADRANT_ORDER.map((q) => (
          <Skeleton key={q} className="h-full w-full rounded-md" />
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
        <EmptyState icon={Grid2x2} title="暂无任务" hint="底部输入栏快速记录，四象限帮你排好先后" />
      </div>
    );
  }

  return (
    <div className="grid min-h-0 flex-1 grid-cols-2 grid-rows-2 gap-3 p-3">
      {QUADRANT_ORDER.map((q) => (
        <QuadrantCard
          key={q}
          quadrant={q}
          tasks={buckets[q]}
          projectById={projectById}
          labelsByTask={labelsByTask}
          remindersByTask={remindersByTask}
          onOpenDetail={onOpenDetail}
          onToggleDone={toggleDone}
          onToggleFavorite={toggleFavorite}
        />
      ))}
    </div>
  );
}

interface QuadrantCardProps {
  quadrant: EisenhowerQuadrant;
  tasks: TodoTask[];
  projectById: Map<number, TodoProject>;
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  remindersByTask: Map<number, TaskReminderMeta[]>;
  onOpenDetail: (id: number) => void;
  onToggleDone: (t: TodoTask) => void;
  onToggleFavorite: (t: TodoTask) => void;
}

/** 单象限格：色带 + 格头 + 格内独立虚拟化列表（每格一个 useVirtualizer 实例） */
function QuadrantCard({
  quadrant,
  tasks,
  projectById,
  labelsByTask,
  remindersByTask,
  onOpenDetail,
  onToggleDone,
  onToggleFavorite,
}: QuadrantCardProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 6,
    getItemKey: (i) => tasks[i].id,
  });
  const meta = EISENHOWER_META[quadrant];

  return (
    <section className="flex min-h-0 flex-col overflow-hidden rounded-md border bg-card">
      {/* 象限色带：顶缘 3px（与移动端矩阵格同形制，只做识别信号不整格铺色） */}
      <div aria-hidden className={cn("h-[3px] shrink-0", QUADRANT_TINT[quadrant])} />
      <header className="flex shrink-0 items-baseline gap-2 px-3 pb-1 pt-2">
        <h2 className="text-sm font-semibold">{meta.action}</h2>
        <span className="truncate text-xs text-muted-foreground">{meta.axis}</span>
        <span className="ml-auto shrink-0 text-xs font-semibold tabular-nums text-muted-foreground">
          {tasks.length}
        </span>
      </header>
      {tasks.length === 0 ? (
        <div className="flex flex-1 items-center justify-center pb-4 text-xs text-muted-foreground/70">
          暂无任务
        </div>
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
          <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
            {virtualizer.getVirtualItems().map((vi) => {
              const t = tasks[vi.index];
              // 每帧一次 nowMs 供行内 overdue/reminder 判定（同 renderRow 口径）
              const nowMs = Date.now();
              const reminder = displayReminder(remindersByTask.get(t.id) ?? [], nowMs, !!t.done);
              return (
                <div
                  key={vi.key}
                  data-index={vi.index}
                  style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
                >
                  <MatrixRow
                    task={t}
                    project={t.project_id != null ? projectById.get(t.project_id) : undefined}
                    labels={labelsByTask.get(t.id) ?? []}
                    reminder={reminder}
                    overdue={!!t.due_date && !t.done && t.due_date < nowMs}
                    onOpenDetail={() => onOpenDetail(t.id)}
                    onToggleDone={() => onToggleDone(t)}
                    onToggleFavorite={() => onToggleFavorite(t)}
                  />
                </div>
              );
            })}
          </div>
        </div>
      )}
    </section>
  );
}

interface MatrixRowProps {
  task: TodoTask;
  project?: TodoProject;
  labels: ProjectedTaskLabel[];
  /** 行内提醒徽标数据（displayReminder 产物；null = 无存活提醒行） */
  reminder: ReturnType<typeof displayReminder>;
  overdue: boolean;
  onOpenDetail: () => void;
  onToggleDone: () => void;
  onToggleFavorite: () => void;
}

/** 矩阵行（TaskRow 同源信息层级的紧凑版，h-50 固定高） */
const MatrixRow = memo(function MatrixRow({
  task: t,
  project,
  labels,
  reminder,
  overdue,
  onOpenDetail,
  onToggleDone,
  onToggleFavorite,
}: MatrixRowProps) {
  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className="group relative flex h-[50px] cursor-default items-center gap-2.5 border-b border-border/30 px-3 hover:bg-accent/30 focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
      onClick={onOpenDetail}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return;
        if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) {
          e.preventDefault();
          onOpenDetail();
        }
      }}
    >
      {/* 完成 checkbox：方角（TaskRow 同款，4px 圆角）；未完成描边 =
          优先级色（P0「无」回落中性灰）——紧急度以完成按钮颜色为准
          （原左缘竖条移除，颜色移交此处） */}
      <button
        type="button"
        aria-label={t.done ? "标记未完成" : "标记完成"}
        className={cn(
          "h-[18px] w-[18px] shrink-0 rounded-[4px] border-2 transition-colors",
          t.done
            ? "border-primary bg-primary"
            : "border-muted-foreground/30 hover:border-primary",
        )}
        style={
          !t.done && t.priority > 0
            ? { borderColor: PRIORITY_COLOR[t.priority] }
            : undefined
        }
        onClick={(e) => {
          e.stopPropagation();
          onToggleDone();
        }}
      >
        {t.done ? <CheckIcon /> : null}
      </button>

      {/* 标题 + 元信息（固定行高，元信息有无不影响） */}
      <div className="flex min-w-0 flex-1 flex-col justify-center">
        <div
          className={cn(
            "truncate text-[13px] leading-4",
            t.done && "text-muted-foreground line-through",
          )}
        >
          {t.title}
        </div>
        {(labels.length > 0 || project != null || reminder != null || t.due_date != null || t.percent_done > 0) && (
          <div
            className={cn(
              "mt-0.5 flex items-center gap-1.5 text-[11px] text-muted-foreground",
              overdue && OVERDUE_COLOR_CLASS,
            )}
          >
            <LabelChips labels={labels} />
            {project && (
              <span className="truncate" style={{ color: project.hex_color || TODO_ACCENT }}>
                {project.title}
              </span>
            )}
            <ReminderChip reminder={reminder} />
            {t.due_date != null && (
              <span className="inline-flex items-center gap-0.5">
                <Clock size={10} />
                {dueTextOf(t.due_date)}
              </span>
            )}
            {t.percent_done > 0 && t.percent_done < 100 && (
              <span className="inline-flex items-center gap-0.5 tabular-nums">
                {Math.round(t.percent_done)}%
              </span>
            )}
          </div>
        )}
      </div>

      {/* 星标：hover 显现（TaskRow 同款，无 my_day 按钮——象限格是优先级工作面） */}
      <button
        type="button"
        aria-label={t.is_favorite ? "取消收藏" : "收藏"}
        className={cn(
          "shrink-0",
          t.is_favorite
            ? "opacity-100"
            : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
        )}
        style={t.is_favorite ? { color: FAVORITE_COLOR } : undefined}
        onClick={(e) => {
          e.stopPropagation();
          onToggleFavorite();
        }}
      >
        <Star size={14} fill={t.is_favorite ? "currentColor" : "none"} />
      </button>
    </div>
  );
});

/** 完成态白勾（TaskRow 的 CheckSvg 同形；size 由本组件固定） */
function CheckIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      className="m-auto size-2.5 text-white"
      fill="none"
      stroke="currentColor"
      strokeWidth={3}
    >
      <path d="M20 6L9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
