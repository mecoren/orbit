/**
 * 日历网格构造（月 6×7 / 周 1×7）
 *
 * 从月历组件抽出为纯函数模块（G1 周视图）：网格是与视觉无关的纯日期计算，
 * 独立成模块后可被 vitest 直接覆盖（组件层为 jsdom 无关的 node 环境，
 * 不挂载组件，见 vitest.config.ts）。
 *
 * 统一口径：周一为首日（与 `WEEKDAY_LABELS` 列序一致）。
 */
import { addDays, startOfWeek } from "./date-utils";

/** 网格列数（周一→周日） */
export const GRID_COLS = 7;
/** 月网格固定行数：28/30/31 天的月份行数一致，切换月份不跳动 */
export const MONTH_GRID_ROWS = 6;

/**
 * 构造月网格：恒 6×7 = 42 格，含前后月补位
 *
 * 固定 42 格（而非按需 5/6 行）使不同月份网格高度恒定，月历 fillHeight
 * 下 6 行等分剩余高度、跨月切换不跳高。
 */
export function buildMonthGrid(year: number, month: number): Date[] {
  const first = new Date(year, month, 1);
  const offset = (first.getDay() + 6) % 7;
  const start = new Date(year, month, 1 - offset);
  return Array.from({ length: GRID_COLS * MONTH_GRID_ROWS }, (_, i) => {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    return d;
  });
}

/**
 * 构造周网格：锚点所在周的 7 天（周一→周日）
 *
 * 锚点语义为「选中日」——周档翻页即选中日 ±7 天，与月档「右栏跟随视图月、
 * 选中日高亮定位」保持同一心智模型。跨月/跨年周原样返回 7 天，不裁剪。
 */
export function buildWeekGrid(anchor: Date): Date[] {
  const start = startOfWeek(anchor);
  return Array.from({ length: GRID_COLS }, (_, i) => addDays(start, i));
}
