/**
 * 时间轴面板（M9 阶段二，对标 TickTick Timeline）：日历「时间」档的整幅视图。
 *
 * 形制：左侧 44px 小时刻度 + `dayCount` 天列（默认 7 天：周一→周日；档位
 * 支持 1 / 3 / 7 天，对标 TickTick 日/三日/周视图），每列 24 小时网格，
 * 任务按 time-block 口径渲染为绝对定位色块（起算/截断/分车道口径见
 * `../shared/time-block.ts` 头注释）。块色取项目色（无项目回落 TODO_ACCENT），
 * 点击块进详情抽屉；完成态弱化不警示。
 *
 * 时段拖拽（#73）：按住块体竖移改起点、横向跨列改日；拖底边改时长。
 * 语义与落库口径全在 `../shared/timeslot-drag.ts` 纯函数（15 分钟吸附、
 * 落点夹到列内、倒推块改 due 不种 start）；本组件只取指针位移、渲染预览
 * 与提交 patch。拖拽中的块**不吃点击**（位移过阈值才吞事件）。
 *
 * 跨日块只渲染在起点日列（视觉截断，hover title 给完整时段）。
 * 纵向滚动容器用 div.overflow-auto（满高预览区不嵌 Radix ScrollArea——
 * viewport 包裹打断高度链，qraft 同款坑）。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { CalendarX } from "lucide-react";

import { cn } from "@/lib/utils";
import { TODO_ACCENT } from "../shared/constants";
import {
  assignLanes,
  blockDayIndex,
  DAY_MS,
  layoutTimeBlock,
  taskTimeBlock,
  type TaskTimeBlock,
} from "../shared/time-block";
import {
  resolveTimeslotMove,
  resolveTimeslotResize,
  timeslotDropPatch,
} from "../shared/timeslot-drag";
import { addDays } from "@/lib/date-utils";
import type { TodoProject, TodoTask } from "@/lib/tauri";

/** 每小时行高（px）：48px 下 30 分钟块约 24px，可容一行截断标题 */
const HOUR_PX = 48;
const GRID_HEIGHT = 24 * HOUR_PX;
/** 初始滚动锚点：无今天列时落到 7:00 */
const DEFAULT_SCROLL_HOUR = 7;
/** 块底边把手高度（px）：够抓又不遮标题 */
const RESIZE_HANDLE_PX = 6;
/** 位移超过此值视为拖拽（吞掉随后的 click，避免松手误开详情） */
const DRAG_THRESHOLD_PX = 3;

/** #RRGGBB → rgba 字符串（块底色弱化用；非法/空串回落 null 由调用方兜底） */
function hexAlpha(hex: string, alpha: number): string | null {
  const m = /^#([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

function two(n: number): string {
  return String(n).padStart(2, "0");
}

function hm(ms: number): string {
  const d = new Date(ms);
  return `${two(d.getHours())}:${two(d.getMinutes())}`;
}

const WEEKDAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"];

/** 拖拽中的预览态（纯局部，不入库；松手才提交） */
interface DragState {
  taskId: number;
  /** move = 移动块体；resize = 拖底边改时长 */
  kind: "move" | "resize";
  /** 指针起点（client 坐标） */
  originX: number;
  originY: number;
  dx: number;
  dy: number;
  moved: boolean;
}

interface DayColumn {
  date: Date;
  dayStartMs: number;
  blocks: Array<TaskTimeBlock & { layout: { topRatio: number; heightRatio: number }; lane: number; laneCount: number }>;
}

interface TimelinePanelProps {
  tasks: TodoTask[];
  /** 面板第一列的日 0 点（本地）——周档为周一零点 */
  anchor: Date;
  /** 列数（1 / 3 / 7；默认 7） */
  dayCount?: number;
  projects: TodoProject[];
  onOpenDetail: (id: number) => void;
  /** 时段拖拽落库（patch 字段见 shared/timeslot-drag） */
  onReschedule?: (taskId: number, patch: Record<string, number>) => Promise<void> | void;
}

export function TimelinePanel({
  tasks,
  anchor,
  dayCount = 7,
  projects,
  onOpenDetail,
  onReschedule,
}: TimelinePanelProps) {
  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  const taskById = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks]);
  const scrollRef = useRef<HTMLDivElement>(null);
  // 列宽实测：拖拽跨列吸附按真实列宽算，纯 CSS 百分比给不出 px
  const gridRef = useRef<HTMLDivElement>(null);

  // 当前时刻（今天列红线）；60s 步进即可（红线粒度无需秒级）
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  // N 天列：整段任务一次遍历分列，列内 clamp + 分车道
  const columns = useMemo<DayColumn[]>(() => {
    const anchorMs = anchor.getTime();
    const buckets: TaskTimeBlock[][] = Array.from({ length: dayCount }, () => []);
    for (const t of tasks) {
      const block = taskTimeBlock(t);
      if (!block) continue;
      const idx = blockDayIndex(block, anchorMs, dayCount);
      if (idx === -1) continue;
      buckets[idx].push(block);
    }
    return buckets.map((blocks, i) => {
      const dayStartMs = anchorMs + i * DAY_MS;
      const layouts = blocks.map((b) => ({ block: b, layout: layoutTimeBlock(b, dayStartMs) }));
      const lanes = assignLanes(layouts.map((x) => x.layout));
      const laneCount = lanes.length > 0 ? Math.max(...lanes) + 1 : 1;
      return {
        date: addDays(anchor, i),
        dayStartMs,
        blocks: layouts.map((x, j) => ({ ...x.block, layout: x.layout, lane: lanes[j], laneCount })),
      };
    });
  }, [tasks, anchor, dayCount]);

  const hasAnyBlock = columns.some((c) => c.blocks.length > 0);

  // 初始滚动：视图含今天 → 定位到当前时刻上一小时半；否则 7:00（工作日时段观感）
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const anchorMs = anchor.getTime();
    const nowMs = now.getTime();
    const span = dayCount * DAY_MS;
    const anchorHour =
      nowMs >= anchorMs && nowMs < anchorMs + span
        ? Math.max(0, now.getHours() + now.getMinutes() / 60 - 1.5)
        : DEFAULT_SCROLL_HOUR;
    el.scrollTop = anchorHour * HOUR_PX;
    // 仅挂载/换档时定位；now 每 60s 变化不应重置用户滚动位置
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [anchor, dayCount]);

  const [drag, setDrag] = useState<DragState | null>(null);
  const dragRef = useRef<DragState | null>(null);
  dragRef.current = drag;

  // 拖拽落库：语义全在 timeslotDropPatch；无变化返回 null 直接跳过
  const commitDrag = async (state: DragState) => {
    if (!onReschedule) return;
    const task = tasks.find((t) => t.id === state.taskId);
    if (!task) return;
    const colIndex = columns.findIndex((c) =>
      c.blocks.some((b) => b.taskId === state.taskId),
    );
    const b = columns[colIndex]?.blocks.find((x) => x.taskId === state.taskId);
    if (!b) return;
    const columnWidthPx = columnWidth();
    const grid =
      state.kind === "move"
        ? resolveTimeslotMove(b, colIndex, dayCount, { x: state.dx, y: state.dy }, {
            hourPx: HOUR_PX,
            columnWidthPx,
          })
        : { ...b, ...resolveTimeslotResize(b, state.dy, HOUR_PX) };
    const patch = timeslotDropPatch(task, {
      startMs: grid.startMs,
      durationMin: grid.durationMin,
    });
    if (!patch) return;
    await onReschedule(state.taskId, patch as Record<string, number>);
  };

  /** 列宽（px）：网格容器宽减去 44px 刻度列后均分 */
  const columnWidth = (): number => {
    const el = gridRef.current;
    if (!el) return 0;
    const w = (el.clientWidth - 44) / dayCount;
    return w > 0 ? w : 0;
  };

  // 指针捕获挂在 window：块体只渲染在起点列，拖到别的列上时 pointermove
  // 仍要跟手（dnd-kit 覆盖不了「块体内相对位移」这种连续手势）
  useEffect(() => {
    if (!drag) return;
    const onMove = (e: PointerEvent) => {
      const cur = dragRef.current;
      if (!cur) return;
      const dx = e.clientX - cur.originX;
      const dy = e.clientY - cur.originY;
      if (
        !cur.moved &&
        Math.abs(dx) <= DRAG_THRESHOLD_PX &&
        Math.abs(dy) <= DRAG_THRESHOLD_PX
      ) {
        return;
      }
      e.preventDefault();
      setDrag({ ...cur, dx, dy, moved: true });
    };
    const onUp = (e: PointerEvent) => {
      const cur = dragRef.current;
      setDrag(null);
      if (!cur) return;
      if (!cur.moved) return; // 未过阈值 = 点击，由 click 处理
      e.preventDefault();
      void commitDrag(cur);
    };
    window.addEventListener("pointermove", onMove, { passive: false });
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onUp);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [drag !== null]);

  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const nowRatio = (now.getTime() - todayStart) / DAY_MS;

  const gridCols = { gridTemplateColumns: `44px repeat(${dayCount}, minmax(0, 1fr))` };
  const hasRangeLabel = dayCount > 1;

  return (
    <div className="flex h-full min-h-0 flex-col">
      {/* 列头：44px 刻度占位 + N 天（今天高亮，wait-home 同款主色实心） */}
      <div className={cn("grid shrink-0 border-b", gridCols)}>
        <div />
        {columns.map((col) => {
          const isToday = col.dayStartMs === todayStart;
          return (
            <div key={col.dayStartMs} className="flex flex-col items-center gap-0.5 py-2">
              <span
                className={cn(
                  "flex size-6 items-center justify-center rounded-full text-xs font-medium",
                  isToday ? "text-primary-foreground" : "text-muted-foreground",
                )}
                style={isToday ? { background: TODO_ACCENT } : undefined}
              >
                {col.date.getDate()}
              </span>
              {hasRangeLabel && (
                <span className="text-xs text-muted-foreground">
                  {`周${WEEKDAY_LABELS[(col.date.getDay() + 6) % 7]}`}
                </span>
              )}
            </div>
          );
        })}
      </div>

      {!hasAnyBlock ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-muted">
            <CalendarX className="size-6 text-muted-foreground" />
          </span>
          <p className="text-sm font-medium">
            {dayCount === 1 ? "当天没有可排时段的任务" : "本周没有可排时段的任务"}
          </p>
          <p className="text-xs text-muted-foreground">
            给任务设预计时长，并填写带时刻的开始或截止时间后在此显示
          </p>
        </div>
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
          <div ref={gridRef} className="grid" style={gridCols}>
            {/* 小时刻度列 */}
            <div className="relative" style={{ height: GRID_HEIGHT }}>
              {Array.from({ length: 24 }, (_, h) => (
                <div
                  key={h}
                  className="absolute right-1.5 -translate-y-1/2 text-[10px] tabular-nums text-muted-foreground"
                  style={{ top: h * HOUR_PX }}
                >
                  {two(h)}:00
                </div>
              ))}
            </div>
            {/* N 天列 */}
            {columns.map((col) => {
              const isToday = col.dayStartMs === todayStart;
              return (
                <div
                  key={col.dayStartMs}
                  className={cn("relative border-l", isToday && "bg-accent/40")}
                  style={{ height: GRID_HEIGHT }}
                >
                  {/* 24 小时横向网格线（repeating 渐变，末线由列底 border 收口） */}
                  <div
                    aria-hidden
                    className="absolute inset-0"
                    style={{
                      backgroundImage:
                        "repeating-linear-gradient(to bottom, var(--border) 0 1px, transparent 1px " +
                        `${HOUR_PX}px)`,
                    }}
                  />
                  {isToday && nowRatio >= 0 && nowRatio <= 1 && (
                    <div
                      aria-hidden
                      className="absolute inset-x-0 z-10 h-px bg-red-500/70"
                      style={{ top: nowRatio * GRID_HEIGHT }}
                    />
                  )}
                  {col.blocks.map((b, blockIdx) => {
                    const t = taskById.get(b.taskId);
                    const project = t?.project_id != null ? projectById.get(t.project_id) : undefined;
                    const hex = project?.hex_color?.trim();
                    const color = hex ? hex : TODO_ACCENT;
                    const bg = hexAlpha(color, 0.16) ?? "transparent";
                    // 拖拽预览：块体移动时重算起点与列，resize 只改块高
                    const isDragging = drag?.taskId === b.taskId && drag.moved;
                    let preview: TaskTimeBlock | null = null;
                    if (isDragging && drag) {
                      if (drag.kind === "move") {
                        const moved = resolveTimeslotMove(b, blockIdx, dayCount, {
                          x: drag.dx,
                          y: drag.dy,
                        }, { hourPx: HOUR_PX, columnWidthPx: columnWidth() });
                        preview = { ...b, startMs: moved.startMs };
                      } else {
                        preview = {
                          ...b,
                          durationMin: resolveTimeslotResize(b, drag.dy, HOUR_PX).durationMin,
                        };
                      }
                    }
                    const shownStart = preview?.startMs ?? b.startMs;
                    const shownDuration = preview?.durationMin ?? b.durationMin;
                    const layout = layoutTimeBlock({ ...b, startMs: shownStart, durationMin: shownDuration }, col.dayStartMs);
                    const endMs = Math.min(
                      shownStart + shownDuration * 60_000,
                      col.dayStartMs + DAY_MS,
                    );
                    const canDrag = !!onReschedule;
                    return (
                      <button
                        key={b.taskId}
                        type="button"
                        title={`${hm(Math.max(shownStart, col.dayStartMs))}–${hm(endMs)} · ${b.title}`}
                        className={cn(
                          "absolute z-[5] overflow-hidden rounded-sm border-l-[3px] px-1 py-0.5 text-left text-[11px] leading-tight",
                          "hover:z-20 hover:shadow-sm",
                          canDrag && (isDragging ? "z-30 cursor-grabbing shadow-md" : "cursor-grab"),
                          b.done && "opacity-50 line-through",
                        )}
                        style={{
                          top: layout.topRatio * GRID_HEIGHT,
                          height: Math.max(layout.heightRatio * GRID_HEIGHT, 18),
                          left: `${(b.lane / b.laneCount) * 100}%`,
                          width: `${(1 / b.laneCount) * 100}%`,
                          background: bg,
                          borderLeftColor: color,
                        }}
                        onClick={() => {
                          if (drag?.moved) return; // 拖拽松手不误开详情
                          onOpenDetail(b.taskId);
                        }}
                        onPointerDown={
                          canDrag
                            ? (e) => {
                                // 底边把手 = resize（命中区在块底 6px），其余为 move
                                const kind =
                                  e.clientY - e.currentTarget.getBoundingClientRect().bottom >
                                  -RESIZE_HANDLE_PX
                                    ? "resize"
                                    : "move";
                                setDrag({
                                  taskId: b.taskId,
                                  kind,
                                  originX: e.clientX,
                                  originY: e.clientY,
                                  dx: 0,
                                  dy: 0,
                                  moved: false,
                                });
                              }
                            : undefined
                        }
                      >
                        <span className="block truncate">{b.title}</span>
                        {canDrag && (
                          <span
                            aria-hidden
                            className="absolute inset-x-0 bottom-0 h-[6px] cursor-ns-resize opacity-0 hover:opacity-100"
                          />
                        )}
                      </button>
                    );
                  })}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}


