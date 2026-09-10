/**
 * 统计面板 —— /todo/stats（backlog #25：统计仪表盘，对标 TickTick 成就页）
 *
 * 数据 = orbit_core::api::stats_aggregate 一次性聚合（只读，不进同步白名单）：
 * - 总览卡：总数/未完成/已完成 + 近 7 天 / 30 天完成数；
 * - 热力图：按年逐日完成数（GitHub contributions 式，2026-09-10 对齐
 *   wait-home 活动热力图——当前年滚动 365 天/历史年完整年、右侧竖排年份
 *   按钮、月份标签 + 周一/周三/周五行标、Portal tooltip、少/多图例；
 *   纯函数铺格见 shared/heatmap.ts，组件见 shared/heatmap-calendar.tsx）；
 * - 连续完成天数（streak）：当前 + 历史最长 + 今日是否已有完成；
 * - 分布卡：项目 / 优先级 / 星期（纯 div 条形图）。
 */
import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { BarChart3, Flame } from "lucide-react";

import { EmptyState } from "@/components/business/empty-state";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import { statsAggregate } from "@/lib/tauri";
import { PRIORITY_COLOR, PRIORITY_LABELS, TODO_ACCENT } from "@/features/todo/shared/constants";
import { HeatmapCalendar } from "@/features/todo/shared/heatmap-calendar";

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
  const [year, setYear] = useState<number>(() => new Date().getFullYear());

  const statsQuery = useQuery({
    queryKey: ["stats", "aggregate", year],
    queryFn: () => statsAggregate(year),
    staleTime: 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const agg = statsQuery.data;

  // 年份列表到达后校正选中：初始当前年若不在可选列表（无完成记录回退口径），
  // 切到列表最新年，避免停在"只有空格"的年份
  useEffect(() => {
    if (agg && agg.available_years.length > 0 && !agg.available_years.includes(year)) {
      setYear(agg.available_years[agg.available_years.length - 1]);
    }
  }, [agg, year]);

  const heatTotal = useMemo(
    () => agg?.heatmap.cells.reduce((s, c) => s + c.count, 0) ?? 0,
    [agg],
  );

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
      </div>

      {/* 空态：total=0 时以页面级空态替换整块报表（普通容器垂直居中，
          对齐 TaskListView 空态口径；仅有一堆 0 值卡片会全部顶对齐堆叠） */}
      {o.total === 0 ? (
        <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto">
          <EmptyState
            icon={BarChart3}
            title="暂无统计数据"
            hint="创建并完成一些任务后，这里会展示你的完成情况"
          />
        </div>
      ) : (
      <ScrollArea className="min-h-0 flex-1">
        <div className="mx-auto max-w-5xl space-y-6 p-4">
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

          {/* 热力图（wait-home 活动热力图同款：月份标签/年份 pill/Portal tooltip/图例） */}
          <div className="rounded-lg border px-4 py-4">
            <p className="mb-3 text-sm font-medium">
              完成热力图
              <span className="ml-2 text-xs font-normal text-muted-foreground tabular-nums">
                {agg.heatmap.year} 年 · {heatTotal} 个完成
              </span>
            </p>
            <HeatmapCalendar
              cells={agg.heatmap.cells}
              year={year}
              years={agg.available_years}
              onYearChange={setYear}
            />
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
      )}
    </div>
  );
}
