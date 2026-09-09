/**
 * 统计面板 —— /todo/stats（backlog #25：统计仪表盘，对标 TickTick 成就页）
 *
 * 数据 = orbit_core::api::stats_aggregate 一次性聚合（只读，不进同步白名单）：
 * - 总览卡：总数/未完成/已完成 + 近 7 天 / 30 天完成数；
 * - 热力图：半年窗口逐日完成数（GitHub contributions 式，5 档色阶自绘，
 *   不引图表库——cell 用 CSS grid，周日历列向排列，周一为首行）；
 * - 连续完成天数（streak）：当前 + 历史最长 + 今日是否已有完成；
 * - 分布卡：项目 / 优先级 / 星期（纯 div 条形图）。
 * 窗口档位 35 / 182 / 371 三档切换（热力图重算，其余卡片与窗口无关）。
 */
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Flame } from "lucide-react";

import { EqualizerLoader } from "@/components/EqualizerLoader";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import { statsAggregate, type StatsAggregate } from "@/lib/tauri";
import { PRIORITY_COLOR, PRIORITY_LABELS, TODO_ACCENT } from "@/features/todo/shared/constants";

/** 热力图窗口档位（天） */
const WINDOW_CHOICES = [
  { days: 35, label: "近 5 周" },
  { days: 182, label: "近半年" },
  { days: 371, label: "近一年" },
] as const;

/** 热力图 5 档色阶（0 档 = muted 空格，4 档走待办强调色同系加深） */
const HEAT_LEVELS = [
  "bg-muted/60",
  "opacity-30",
  "opacity-55",
  "opacity-80",
  "opacity-100",
] as const;

/** count → 色阶档（0 / 1 / 2-3 / 4-6 / ≥7；GitHub 式开方分桶） */
function heatLevel(count: number): number {
  if (count <= 0) return 0;
  if (count === 1) return 1;
  if (count <= 3) return 2;
  if (count <= 6) return 3;
  return 4;
}

/** 月份标签：按窗口首格月份 + 遇新月份收一格 */
function monthMarkers(cells: { date: string }[]): string[] {
  const marks: string[] = [];
  let lastMonth = -1;
  for (const c of cells) {
    const m = Number(c.date.slice(5, 7));
    if (m !== lastMonth) {
      marks.push(`${m}月`);
      lastMonth = m;
    } else {
      marks.push("");
    }
  }
  return marks;
}

/** 单个分布条形行（label / 已完成数 / 未完成数；bar 宽按同卡内最大值归一） */
function DistBar({
  label,
  done,
  pending,
  max,
  color,
  labelColor,
}: {
  label: string;
  done: number;
  pending: number;
  max: number;
  color: string;
  /** label 文字色（项目分布按项目色着字；其余卡缺省默认色） */
  labelColor?: string;
}) {
  const total = done + pending;
  if (total <= 0) return null;
  const donePct = (done / max) * 100;
  const pendingPct = (pending / max) * 100;
  return (
    <div className="space-y-1">
      <div className="flex items-baseline justify-between text-xs">
        <span className="min-w-0 truncate" style={labelColor ? { color: labelColor } : undefined}>
          {label}
        </span>
        <span className="shrink-0 tabular-nums text-muted-foreground">
          {done} / {total}
        </span>
      </div>
      {/* 双段条：完成段实色，未完成段同色 25% 弱化——条形全程对应行色；双零宽段不渲染 */}
      <div className="flex h-1.5 w-full gap-0.5 overflow-hidden rounded-full bg-muted/50">
        {done > 0 && (
          <div
            className="h-full rounded-full"
            style={{ width: `${donePct}%`, background: color }}
          />
        )}
        {pending > 0 && (
          <div
            className="h-full rounded-full"
            style={{ width: `${pendingPct}%`, background: color, opacity: 0.25 }}
          />
        )}
      </div>
    </div>
  );
}

/** 统计面板（TodoShell 嵌套路由 /todo/stats；壳层提供侧栏与弹层） */
export function StatsPanel() {
  const [days, setDays] = useState<number>(182);

  const statsQuery = useQuery({
    queryKey: ["stats", "aggregate", days],
    queryFn: () => statsAggregate(days),
    staleTime: 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const agg = statsQuery.data;

  // 热力图：周日历分列（周一为首列），列 = 周，行 = 周一..周日
  const weeks = useMemo(() => {
    if (!agg) return [] as { cells: StatsAggregate["heatmap"]["cells"]; month: string }[];
    const cells = agg.heatmap.cells;
    const marks = monthMarkers(cells);
    // 首格对齐：补首列前置空格让第一列恰为完整周一..周日
    const firstDow = new Date(`${cells[0].date}T00:00:00`).getDay(); // 0=周日
    const pad = (firstDow + 6) % 7; // 转周一=0 基
    const padded: (typeof cells)[number][] = Array.from({ length: pad }, () => ({
      date: "",
      count: -1,
    }));
    const all = [...padded, ...cells];
    const cols: { cells: typeof all; month: string }[] = [];
    for (let i = 0; i < all.length; i += 7) {
      const col = all.slice(i, i + 7);
      // 月标签取本列第一个非空格的月标记
      const month = marks[Math.max(0, i - pad)] ?? "";
      cols.push({ cells: col, month });
    }
    return cols;
  }, [agg]);

  if (!agg) {
    return (
      <div className="grid h-full place-items-center">
        <EqualizerLoader />
      </div>
    );
  }

  const o = agg.overview;
  const s = agg.streak;
  const maxProject = Math.max(1, ...agg.by_project.map((r) => r.done_count + r.pending_count));
  const maxPriority = Math.max(1, ...agg.by_priority.map((r) => r.done_count + r.pending_count));
  const maxWeekday = Math.max(1, ...agg.by_weekday.map((r) => r.done_count));
  const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

  return (
    <div className="flex h-full flex-col">
      {/* 工具栏 */}
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
        <div className="flex items-baseline gap-2">
          <h1 className="text-lg font-semibold">统计</h1>
          <span className="text-xs text-muted-foreground">已完成 {o.done} · 未完成 {o.pending}</span>
        </div>
        {/* 热力图窗口档位（仅热力图随窗口变化） */}
        <div className="flex items-center gap-1 rounded-md border p-0.5">
          {WINDOW_CHOICES.map((w) => (
            <button
              key={w.days}
              type="button"
              className={cn(
                "rounded-sm px-2 py-1 text-xs",
                days === w.days
                  ? "bg-primary/10 font-medium text-primary"
                  : "text-muted-foreground hover:text-foreground",
              )}
              onClick={() => setDays(w.days)}
            >
              {w.label}
            </button>
          ))}
        </div>
      </div>

      <ScrollArea className="min-h-0 flex-1">
        <div className="mx-auto max-w-3xl space-y-6 p-4">
          {/* 总览 + streak */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
            {[
              { label: "总任务", value: o.total },
              { label: "已完成", value: o.done },
              { label: "未完成", value: o.pending },
              { label: "近 7 天完成", value: o.done_last_7d },
              { label: "近 30 天完成", value: o.done_last_30d },
            ].map((c) => (
              <div key={c.label} className="rounded-lg border px-3 py-2.5">
                <p className="text-xs text-muted-foreground">{c.label}</p>
                <p className="mt-1 text-2xl font-semibold tabular-nums">{c.value}</p>
              </div>
            ))}
          </div>

          <div className="flex items-center gap-3 rounded-lg border px-4 py-3">
            <Flame
              className={cn("size-5 shrink-0", s.current > 0 ? "text-orange-500" : "text-muted-foreground/40")}
            />
            <div className="min-w-0 flex-1">
              <p className="text-sm font-medium">
                连续完成 <span className="tabular-nums text-lg">{s.current}</span> 天
                <span className="ml-2 text-xs font-normal text-muted-foreground">
                  历史最长 {s.best} 天 · {s.done_today ? "今天已完成 ✅" : "今天还没完成任何任务"}
                </span>
              </p>
            </div>
          </div>

          {/* 热力图（CSS grid 自绘：列=周 行=周一..周日；色阶走待办强调色） */}
          <div className="rounded-lg border px-4 py-4">
            <p className="mb-3 text-sm font-medium">完成热力图</p>
            <div className="overflow-x-auto pb-1">
              <div className="flex gap-2">
                {/* 星期轴 */}
                <div className="flex flex-col gap-[3px] pt-[18px]">
                  {WEEKDAYS.map((w, i) => (
                    <div key={w} className="h-[11px] text-[10px] leading-[11px] text-muted-foreground">
                      {i % 2 === 0 ? w : ""}
                    </div>
                  ))}
                </div>
                <div className="min-w-0 flex-1">
                  {/* 月标签行 */}
                  <div className="mb-1 flex gap-[3px]">
                    {weeks.map((w, i) => (
                      <div key={i} className="w-[11px] text-[10px] leading-none text-muted-foreground">
                        {w.month}
                      </div>
                    ))}
                  </div>
                  {/* 格阵：每列 flex-col，一行 7 格 */}
                  <div className="flex gap-[3px]">
                    {weeks.map((w, wi) => (
                      <div key={wi} className="flex flex-col gap-[3px]">
                        {w.cells.map((c, ci) => {
                          if (c.count < 0) return <div key={ci} className="size-[11px]" />;
                          const lv = heatLevel(c.count);
                          return (
                            <div
                              key={ci}
                              title={`${c.date}：完成 ${c.count} 个`}
                              className={cn("size-[11px] rounded-[3px]", HEAT_LEVELS[lv])}
                              style={lv > 0 ? { background: TODO_ACCENT } : undefined}
                            />
                          );
                        })}
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
            {/* 图例 */}
            <div className="mt-3 flex items-center justify-end gap-1 text-[10px] text-muted-foreground">
              <span>少</span>
              {HEAT_LEVELS.map((_, i) => (
                <div
                  key={i}
                  className={cn("size-[10px] rounded-[2px]", HEAT_LEVELS[i])}
                  style={i > 0 ? { background: TODO_ACCENT } : undefined}
                />
              ))}
              <span>多</span>
            </div>
          </div>

          {/* 分布卡三连 */}
          <div className="grid gap-3 md:grid-cols-3">
            <div className="space-y-2.5 rounded-lg border px-4 py-3">
              <p className="text-sm font-medium">项目分布</p>
              {agg.by_project.length === 0 && (
                <p className="text-xs text-muted-foreground">暂无任务</p>
              )}
              {agg.by_project.map((r) => (
                <DistBar
                  key={r.project_id ?? "none"}
                  label={r.project_title ?? "未分组"}
                  done={r.done_count}
                  pending={r.pending_count}
                  max={maxProject}
                  color={r.project_hex_color || TODO_ACCENT}
                  labelColor={r.project_id != null ? r.project_hex_color || TODO_ACCENT : undefined}
                />
              ))}
            </div>

            <div className="space-y-2.5 rounded-lg border px-4 py-3">
              <p className="text-sm font-medium">优先级分布</p>
              {agg.by_priority.length === 0 && (
                <p className="text-xs text-muted-foreground">暂无任务</p>
              )}
              {agg.by_priority.map((r) => (
                <DistBar
                  key={r.priority}
                  label={PRIORITY_LABELS[r.priority] ?? `P${r.priority}`}
                  done={r.done_count}
                  pending={r.pending_count}
                  max={maxPriority}
                  color={PRIORITY_COLOR[r.priority] || PRIORITY_COLOR[0]}
                />
              ))}
            </div>

            <div className="space-y-2.5 rounded-lg border px-4 py-3">
              <p className="text-sm font-medium">星期分布（已完成）</p>
              {agg.by_weekday.map((r) => (
                <DistBar
                  key={r.weekday}
                  label={WEEKDAYS[r.weekday] ?? String(r.weekday)}
                  done={r.done_count}
                  pending={0}
                  max={maxWeekday}
                  color={TODO_ACCENT}
                />
              ))}
            </div>
          </div>
        </div>
      </ScrollArea>
    </div>
  );
}
