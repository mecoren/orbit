/**
 * 时间轴面板（M9 阶段二，对标 TickTick Timeline）：日历第五档「时间」的整幅视图。
 *
 * 形制：左侧 44px 小时刻度 + 7 天列（周一→周日），每列 24 小时网格，
 * 任务按 time-block 口径渲染为绝对定位色块（起算/截断/分车道口径见
 * `../shared/time-block.ts` 头注释）。块色取项目色（无项目回落 TODO_ACCENT），
 * 点击块进详情抽屉；完成态弱化不警示。
 *
 * 有意不做（本批边界）：时段拖拽改期（移动端手势冲突 + 与月格拖拽语义不同源，
 * 待单独批次）；跨日块只渲染在起点日列（视觉截断，hover title 给完整时段）。
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
import { addDays } from "@/lib/date-utils";
import type { TodoProject, TodoTask } from "@/lib/tauri";

/** 每小时行高（px）：48px 下 30 分钟块约 24px，可容一行截断标题 */
const HOUR_PX = 48;
const GRID_HEIGHT = 24 * HOUR_PX;
/** 初始滚动锚点：无今天列时落到 7:00 */
const DEFAULT_SCROLL_HOUR = 7;

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

interface DayColumn {
  date: Date;
  dayStartMs: number;
  blocks: Array<TaskTimeBlock & { layout: { topRatio: number; heightRatio: number }; lane: number; laneCount: number }>;
}

interface TimelinePanelProps {
  tasks: TodoTask[];
  /** 周一 00:00（本地） */
  weekStart: Date;
  projects: TodoProject[];
  onOpenDetail: (id: number) => void;
}

export function TimelinePanel({ tasks, weekStart, projects, onOpenDetail }: TimelinePanelProps) {
  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  const taskById = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks]);
  const scrollRef = useRef<HTMLDivElement>(null);

  // 当前时刻（今天列红线）；60s 步进即可（红线粒度无需秒级）
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  // 周内 7 列：整周任务一次遍历分列，列内 clamp + 分车道
  const columns = useMemo<DayColumn[]>(() => {
    const weekStartMs = weekStart.getTime();
    const buckets: TaskTimeBlock[][] = Array.from({ length: 7 }, () => []);
    for (const t of tasks) {
      const block = taskTimeBlock(t);
      if (!block) continue;
      const idx = blockDayIndex(block, weekStartMs);
      if (idx === -1) continue;
      buckets[idx].push(block);
    }
    return buckets.map((blocks, i) => {
      const dayStartMs = weekStartMs + i * DAY_MS;
      const layouts = blocks.map((b) => ({ block: b, layout: layoutTimeBlock(b, dayStartMs) }));
      const lanes = assignLanes(layouts.map((x) => x.layout));
      const laneCount = lanes.length > 0 ? Math.max(...lanes) + 1 : 1;
      return {
        date: addDays(weekStart, i),
        dayStartMs,
        blocks: layouts.map((x, j) => ({ ...x.block, layout: x.layout, lane: lanes[j], laneCount })),
      };
    });
  }, [tasks, weekStart]);

  const hasAnyBlock = columns.some((c) => c.blocks.length > 0);

  // 初始滚动：视图含今天 → 定位到当前时刻上一小时半；否则 7:00（工作日时段观感）
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const weekStartMs = weekStart.getTime();
    const nowMs = now.getTime();
    const anchorHour =
      nowMs >= weekStartMs && nowMs < weekStartMs + 7 * DAY_MS
        ? Math.max(0, now.getHours() + now.getMinutes() / 60 - 1.5)
        : DEFAULT_SCROLL_HOUR;
    el.scrollTop = anchorHour * HOUR_PX;
    // 仅挂载/翻周时定位；now 每 60s 变化不应重置用户滚动位置
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [weekStart]);

  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const nowRatio =
    (now.getTime() - todayStart) / DAY_MS;

  return (
    <div className="flex h-full min-h-0 flex-col">
      {/* 列头：44px 刻度占位 + 7 天（今天高亮，wait-home 同款主色实心） */}
      <div className="grid shrink-0 grid-cols-[44px_repeat(7,minmax(0,1fr))] border-b">
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
              <span className="text-xs text-muted-foreground">
                {`周${WEEKDAY_LABELS[(col.date.getDay() + 6) % 7]}`}
              </span>
            </div>
          );
        })}
      </div>

      {!hasAnyBlock ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-muted">
            <CalendarX className="size-6 text-muted-foreground" />
          </span>
          <p className="text-sm font-medium">本周没有可排时段的任务</p>
          <p className="text-xs text-muted-foreground">
            给任务设预计时长，并填写带时刻的开始或截止时间后在此显示
          </p>
        </div>
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
          <div className="grid grid-cols-[44px_repeat(7,minmax(0,1fr))]">
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
            {/* 7 天列 */}
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
                  {col.blocks.map((b) => {
                    const t = taskById.get(b.taskId);
                    const project = t?.project_id != null ? projectById.get(t.project_id) : undefined;
                    const hex = project?.hex_color?.trim();
                    const color = hex ? hex : TODO_ACCENT;
                    const bg = hexAlpha(color, 0.16) ?? "transparent";
                    const endMs = Math.min(
                      b.startMs + b.durationMin * 60_000,
                      col.dayStartMs + DAY_MS,
                    );
                    return (
                      <button
                        key={b.taskId}
                        type="button"
                        title={`${hm(Math.max(b.startMs, col.dayStartMs))}–${hm(endMs)} · ${b.title}`}
                        className={cn(
                          "absolute z-[5] overflow-hidden rounded-sm border-l-[3px] px-1 py-0.5 text-left text-[11px] leading-tight",
                          "hover:z-20 hover:shadow-sm",
                          b.done && "opacity-50 line-through",
                        )}
                        style={{
                          top: b.layout.topRatio * GRID_HEIGHT,
                          height: Math.max(b.layout.heightRatio * GRID_HEIGHT, 18),
                          left: `${(b.lane / b.laneCount) * 100}%`,
                          width: `${(1 / b.laneCount) * 100}%`,
                          background: bg,
                          borderLeftColor: color,
                        }}
                        onClick={() => onOpenDetail(b.taskId)}
                      >
                        <span className="block truncate">{b.title}</span>
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
