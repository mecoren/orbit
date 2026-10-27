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
 * - 悬停 tooltip 用 Portal 渲染到 body，脱离卡片 overflow 裁剪（wait-home 同款）；
 *   底色走 bg-primary 对齐 ui/tooltip.tsx 原语（全项目悬浮提示统一主题色底白字）。
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
/** 年份栏与热力图主体之间的 flex 间距（px） */
const FLEX_GAP = 12;
/**
 * 固定排版槽数：闰年且 1/1 为周日时一年占 54 列（其余年 53 列）。
 * 所有年份统一按 54 槽算格宽——否则 53/54 列年份切换时格宽差 1px，
 * 格阵高度跟着变，页面滚动条随之出现/消失，整页内容上下跳一次。
 */
const MAX_COLUMNS = 54;

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

  // 排版槽数统一取 MAX_COLUMNS：所有年份格宽、格阵宽高完全一致
  const layoutColumns = Math.max(totalColumns, MAX_COLUMNS);

  // 动态格宽：撑满滚动区可用宽度（最小 12px，不够时该层自己横向滚动）。
  // blockWidth = 滚动容器的 clientWidth（年份栏已在 flex 布局中扣除，不再手动减）；
  // 未测量时回退默认 12px（首帧），测量到达后重铺；
  // 向下取整保证合计宽度 ≤ 可用宽度（ceil 会差 1~Npx 触发无谓横滚）
  const dynamicCellSize = useMemo(() => {
    if (blockWidth === 0 || layoutColumns <= 0) return CELL_SIZE;
    const available = blockWidth - WEEKDAY_LABEL_WIDTH - CELL_GAP;
    const computed = (available - (layoutColumns - 1) * CELL_GAP) / layoutColumns;
    return Math.max(CELL_SIZE, Math.floor(computed));
  }, [blockWidth, layoutColumns]);

  const gridWidth = layoutColumns * (dynamicCellSize + CELL_GAP) - CELL_GAP;
  const gridHeight = 7 * (dynamicCellSize + CELL_GAP) - CELL_GAP;

  // 年份按钮降序（最新年在顶部）；当前选中不在列表也并入（防 core 回退口径漂移）
  const sortedYears = useMemo(() => {
    const set = new Set(years);
    set.add(year);
    return [...set].sort((a, b) => b - a);
  }, [years, year]);

  return (
    <>
      {/* 年份列固定在右侧、不参与横向滚动：窄窗口下网格走横滚时，年份按钮
          不会被推出可视区（此前整行一起滚，2023 这类靠后的年份会滚到屏幕外）。
          滚动条走全局 index.css 标准（10px 透明轨道主题色圆角滑块）；
          不可设 scrollbar-width——非 auto 值会禁用 webkit 自定义退化为系统原生条 */}
      <div className="flex w-full items-start" style={{ gap: FLEX_GAP }}>
      <div ref={setBlockEl} className="min-w-0 flex-1 overflow-x-auto pb-1">
      {/* 子项全部 shrink-0：行宽自然 = 内容宽，窄卡片时溢出由本层横滚承接 */}
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
                gridTemplateColumns: `repeat(${layoutColumns}, ${dynamicCellSize}px)`,
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
      </div>

      {/* 右侧年份按钮（outline + 选中态 border-primary/bg-primary/5）。
          不设高度上限、不内滚：年份数量跟着历史数据长（本次示例数据就有 4 个年份），
          一旦 maxHeight 低于按钮总高，最后一个年份会被裁掉一半且没有滚动条提示
          （隐藏滚动条是既定口径），所以这里让列自然撑高、由卡片容纳。 */}
      <div className="flex shrink-0 flex-col items-stretch gap-1">
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
                // h-6：4–5 个年份能在网格高度内排下，不至于把卡片撑得太高
                "h-6 w-14 px-2 py-0 text-[11px] leading-none tabular-nums",
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

      {/* 悬停 tooltip：Portal 渲染到 body，避免卡片 overflow 裁剪；
          bg-primary 白字对齐 ui/tooltip.tsx 原语口径（全项目悬浮提示统一主题色底） */}
      {hovered &&
        typeof document !== "undefined" &&
        createPortal(
          <div
            className="pointer-events-none fixed z-50 rounded-md bg-primary px-2 py-1 text-xs text-primary-foreground shadow-md"
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
