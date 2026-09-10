/**
 * 完成热力图组件（2026-09-10 对齐 wait-home activity-calendar 设计）
 *
 * GitHub 贡献图风格：按年展示逐日完成密度。
 * - 当前年 = 滚动 365 天（跨年覆盖去年同日至今）；历史年 = 完整年；
 * - 4 档色阶走待办强调色 alpha 22/45/68/90%（锚定 max≥4 分档，纯函数见
 *   shared/heatmap.ts，双端口径一致）；
 * - 布局：顶部月份标签、左侧 周一/周三/周五（7 槽与网格行精确对位）、
 *   右侧竖排年份按钮、底部 少/多 图例；
 * - 固定格宽 12px + 整块横向滚动兜底（窄容器不压缩观感，与移动端同构）；
 * - 悬停 tooltip 用 Portal 渲染到 body，脱离卡片 overflow 裁剪（wait-home 同款）。
 */
import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { layoutHeatmap } from "@/features/todo/shared/heatmap";
import { TODO_ACCENT } from "@/features/todo/shared/constants";
import type { StatsHeatmapCell } from "@/lib/tauri";

interface HeatmapCalendarProps {
  /** 逐日完成数（core stats_aggregate.heatmap.cells） */
  cells: StatsHeatmapCell[];
  /** 当前选中年份 */
  year: number;
  /** 可选年份列表（升序；有完成记录的年份） */
  years: number[];
  /** 年份切换回调 */
  onYearChange: (year: number) => void;
}

/** 格宽下限（px）：动态算宽低于此值时改走横向滚动，不压缩观感 */
const CELL_SIZE = 12;
const CELL_GAP = 2;
const WEEKDAY_LABEL_WIDTH = 30;
const MONTH_LABEL_HEIGHT = 18;
// shadcn Button size="sm" + w-14（56px）视觉宽度（wait-home 同款）
const YEAR_PILL_WIDTH = 56;
/** 年份栏与热力图主体之间的 flex 间距（px） */
const FLEX_GAP = 12;

/** 4 档色阶 alpha（0 档 = muted 空格；与 wait-home 22/45/68/90% 一致） */
const HEAT_ALPHAS = [0, 0.22, 0.45, 0.68, 0.9] as const;

export function HeatmapCalendar({ cells, year, years, onYearChange }: HeatmapCalendarProps) {
  const [hovered, setHovered] = useState<
    { day: string; value: number; rect: DOMRect } | null
  >(null);
  // 卡片内容宽（热力图块最外层）：唯一被测量者，且不依赖子内容反撑——
  // 热力图内部全部 shrink-0，宽度只由 flex 布局分配决定，规避
  // 「观察的容器被 minWidth 反撑→测量值掺入旧格宽」的自引用。
  // 双通道测量：ResizeObserver（容器尺寸变化）+ 窗口 resize 兜底
  // （overflow 滚动容器首帧 contentRect 偶发窄值上报）
  const [blockEl, setBlockEl] = useState<HTMLDivElement | null>(null);
  const [blockWidth, setBlockWidth] = useState(0);

  useEffect(() => {
    if (!blockEl) return;
    const measure = () => setBlockWidth(blockEl.clientWidth);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(blockEl);
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [blockEl]);

  const { cells: dayCells, monthLabels, totalColumns } = useMemo(() => {
    const counts = new Map(cells.map((c) => [c.date, c.count]));
    return layoutHeatmap(counts, year);
  }, [cells, year]);

  // 动态格宽：撑满年份栏之外的可用宽度（最小 12px，不够时横向滚动）。
  // blockWidth 未测量时回退默认 12px（首帧），测量到达后重铺；
  // 向下取整保证合计宽度 ≤ 可用宽度（ceil 会差 1~Npx 触发无谓横滚）
  const dynamicCellSize = useMemo(() => {
    if (blockWidth === 0 || totalColumns <= 0) return CELL_SIZE;
    const available =
      blockWidth - YEAR_PILL_WIDTH - FLEX_GAP - WEEKDAY_LABEL_WIDTH - CELL_GAP;
    const computed = (available - (totalColumns - 1) * CELL_GAP) / totalColumns;
    return Math.max(CELL_SIZE, Math.floor(computed));
  }, [blockWidth, totalColumns]);

  const gridWidth = totalColumns * (dynamicCellSize + CELL_GAP) - CELL_GAP;
  const gridHeight = 7 * (dynamicCellSize + CELL_GAP) - CELL_GAP;

  // 年份按钮降序（最新年在顶部）；当前选中不在列表也并入（防 core 回退口径漂移）
  const sortedYears = useMemo(() => {
    const set = new Set(years);
    set.add(year);
    return [...set].sort((a, b) => b - a);
  }, [years, year]);

  return (
    <>
      <div ref={setBlockEl} className="w-full overflow-x-auto pb-1 [scrollbar-width:thin]">
      {/* 子项全部 shrink-0：行宽自然 = 内容宽，窄卡片时溢出由外层横滚承接 */}
      <div className="flex items-start" style={{ gap: FLEX_GAP }}>
      <div className="shrink-0" style={{ width: WEEKDAY_LABEL_WIDTH + CELL_GAP + gridWidth }}>
          {/* 月份标签行 */}
          <div
            className="flex"
            style={{
              height: MONTH_LABEL_HEIGHT,
              paddingLeft: WEEKDAY_LABEL_WIDTH + CELL_GAP,
              marginBottom: CELL_GAP,
            }}
          >
            <div className="relative" style={{ width: gridWidth, height: "100%" }}>
              {monthLabels.map((label) => (
                <span
                  key={label.col}
                  className="absolute text-[10px] font-medium text-muted-foreground"
                  style={{
                    left: (label.col - 1) * (dynamicCellSize + CELL_GAP),
                    top: 0,
                  }}
                >
                  {label.text}
                </span>
              ))}
            </div>
          </div>

          {/* 网格主体：星期标签 + 格阵 */}
          <div className="flex">
            {/* 行标与网格行同构的 7 槽精确对位（周一槽/周三槽/周五槽各占一行高，
                其余槽留空）——justify-between 会把「周三」中心压到周四行中心，
                格小时错位明显 */}
            <div
              className="grid text-[10px] font-medium text-muted-foreground"
              style={{
                width: WEEKDAY_LABEL_WIDTH,
                height: gridHeight,
                marginRight: CELL_GAP,
                gridTemplateRows: `repeat(7, ${dynamicCellSize}px)`,
                gap: CELL_GAP,
              }}
            >
              {["周一", "", "周三", "", "周五", "", ""].map((label, i) => (
                <div
                  key={i}
                  className="flex items-center justify-end pr-0.5 leading-none"
                >
                  {label}
                </div>
              ))}
            </div>

            {/* 每格显式 gridColumn/gridRow，避免顺序填格错位 */}
            <div
              className="grid"
              style={{
                width: gridWidth,
                height: gridHeight,
                gridTemplateColumns: `repeat(${totalColumns}, ${dynamicCellSize}px)`,
                gridTemplateRows: `repeat(7, ${dynamicCellSize}px)`,
                gap: CELL_GAP,
              }}
              onMouseLeave={() => setHovered(null)}
            >
              {dayCells.map((cell) => (
                <div
                  key={cell.day}
                  className="rounded-[2px]"
                  style={{
                    gridColumn: cell.col,
                    gridRow: cell.row,
                    backgroundColor:
                      cell.level === 0
                        ? "var(--muted)"
                        : `color-mix(in srgb, ${TODO_ACCENT} ${HEAT_ALPHAS[cell.level] * 100}%, transparent)`,
                  }}
                  onMouseEnter={(e) =>
                    setHovered({
                      day: cell.day,
                      value: cell.value,
                      rect: e.currentTarget.getBoundingClientRect(),
                    })
                  }
                />
              ))}
            </div>
          </div>
        </div>

      {/* 右侧年份按钮（outline + 选中态 border-primary/bg-primary/5） */}
      <div
        className="flex shrink-0 flex-col items-stretch gap-1 overflow-y-auto [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden"
        style={{
          maxHeight: MONTH_LABEL_HEIGHT + CELL_GAP + gridHeight,
          maxWidth: YEAR_PILL_WIDTH,
        }}
      >
        {sortedYears.map((y) => {
          const selected = y === year;
          return (
            <Button
              key={y}
              type="button"
              variant="outline"
              size="sm"
              onClick={() => onYearChange(y)}
              aria-pressed={selected}
              aria-label={`切换到 ${y} 年`}
              className={cn(
                "w-14 px-2 py-0.5 text-xs tabular-nums",
                selected
                  ? "border-primary bg-primary/5 text-primary"
                  : "text-muted-foreground hover:bg-accent/50",
              )}
            >
              {y}
            </Button>
          );
        })}
      </div>
      </div>
      </div>

      {/* 图例：5 段色块（空 + 4 档）紧贴形成色带，对齐 GitHub 风格 */}
      <div className="mt-3 flex items-center justify-end gap-1.5 text-[10px] text-muted-foreground">
        <span>少</span>
        <div className="flex items-center" style={{ gap: CELL_GAP }}>
          <div
            className="rounded-[2px]"
            style={{ width: dynamicCellSize, height: dynamicCellSize, backgroundColor: "var(--muted)" }}
          />
          {HEAT_ALPHAS.slice(1).map((alpha, i) => (
            <div
              key={i}
              className="rounded-[2px]"
              style={{
                width: dynamicCellSize,
                height: dynamicCellSize,
                backgroundColor: `color-mix(in srgb, ${TODO_ACCENT} ${alpha * 100}%, transparent)`,
              }}
            />
          ))}
        </div>
        <span>多</span>
      </div>

      {/* 悬停 tooltip：Portal 渲染到 body，避免卡片 overflow 裁剪 */}
      {hovered &&
        typeof document !== "undefined" &&
        createPortal(
          <div
            className="pointer-events-none fixed z-50 rounded-md border bg-popover px-2 py-1 text-xs text-popover-foreground shadow-md"
            style={{ left: hovered.rect.right + 8, top: hovered.rect.top }}
          >
            <div>{hovered.day}</div>
            <div className="font-semibold">完成 {hovered.value} 个</div>
          </div>,
          document.body,
        )}
    </>
  );
}
