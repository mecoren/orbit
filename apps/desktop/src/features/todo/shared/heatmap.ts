/**
 * 完成热力图纯函数域（2026-09-10 对齐 wait-home 活动热力图）
 *
 * 布局口径（与 wait-home activity-calendar 完全一致）：
 * - 网格从窗口首日按其实际星期几开始铺（不做周一对齐补格），
 *   列以「周一为新列首」划分，首列前置行由 cell 显式 col/row 定位自然留空；
 * - 行 = 周一(1)..周日(7)，列 = 周；
 * - 月份标签取该月第一个日期所在列，最小 4 列距防重叠；
 * - 色阶锚定 max≥4：1→1 档、2→2 档、3→3 档、≥4 按相对比例（GitHub 语义：
 *   少量记录映射浅色档，避免"仅 1~2 条却最深色"）。
 */

/** 热力图窗口（本地日期）：当前年 = 滚动 365 天；历史年 = 完整年 */
export function heatmapDateRange(year: number, now = new Date()): { from: Date; to: Date } {
  if (year === now.getFullYear()) {
    const from = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    from.setDate(from.getDate() - 364);
    return { from, to: new Date(now.getFullYear(), now.getMonth(), now.getDate()) };
  }
  return { from: new Date(year, 0, 1), to: new Date(year, 11, 31) };
}

function formatDateKey(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** 月份缩写（与 wait-home / GitHub 风格一致） */
function monthAbbreviation(month: number): string {
  const names = ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"];
  return names[month];
}

/** count → 色阶档（0 = 空；1-4 = 强调色 alpha 22/45/68/90%） */
export function heatLevel(value: number, maxValue: number): number {
  if (value <= 0 || maxValue <= 0) return 0;
  // 锚定最大档（4 级）至少对应 4 条记录：少量记录映射到浅色档
  const effectiveMax = Math.max(maxValue, 4);
  const ratio = value / effectiveMax;
  if (ratio <= 0.25) return 1;
  if (ratio <= 0.5) return 2;
  if (ratio <= 0.75) return 3;
  return 4;
}

export interface HeatmapCellLayout {
  /** 本地日期 YYYY-MM-DD */
  day: string;
  /** 当日完成数 */
  value: number;
  /** 色阶档（0 = 空，1-4 = 填充） */
  level: number;
  /** CSS Grid 列索引（自 1 开始） */
  col: number;
  /** CSS Grid 行索引（自 1 开始；周一=1，周日=7） */
  row: number;
}

export interface HeatmapMonthLabel {
  col: number;
  text: string;
}

/** 月份标签最小列间距（wait-home 同款，防 10 月/11 月文字重叠） */
export const MIN_MONTH_LABEL_GAP_COLS = 4;

/**
 * 铺格：窗口首日 → 末日逐日推进，行到周日(7)换新列。
 * 返回 cells + 月份标签（已按最小列距过滤）+ 总列数。
 */
export function layoutHeatmap(
  counts: Map<string, number>,
  year: number,
  now = new Date(),
): { cells: HeatmapCellLayout[]; monthLabels: HeatmapMonthLabel[]; totalColumns: number; total: number } {
  const { from, to } = heatmapDateRange(year, now);
  // 首列起始行：getDay 周日=0..周六=6 → 周一=1..周日=7
  const fromRow = from.getDay() === 0 ? 7 : from.getDay();

  const cells: HeatmapCellLayout[] = [];
  const rawLabels: HeatmapMonthLabel[] = [];
  let lastMonth = -1;
  let col = 1;
  let row = fromRow;
  let total = 0;
  const cursor = new Date(from);

  while (cursor <= to) {
    const key = formatDateKey(cursor);
    const value = counts.get(key) ?? 0;
    total += value;

    // 月份标签：该月第一个日期所在列
    if (cursor.getMonth() !== lastMonth) {
      rawLabels.push({ col, text: monthAbbreviation(cursor.getMonth()) });
      lastMonth = cursor.getMonth();
    }

    cells.push({ day: key, value, level: 0, col, row });

    if (row === 7) {
      row = 1;
      col++;
    } else {
      row++;
    }
    cursor.setDate(cursor.getDate() + 1);

    if (cells.length > 400) break; // 安全边界：一年最多 371 格
  }

  // 过滤重叠月份标签（最小列距）
  const monthLabels: HeatmapMonthLabel[] = [];
  let lastKeptCol = -MIN_MONTH_LABEL_GAP_COLS;
  for (const label of rawLabels) {
    if (label.col - lastKeptCol >= MIN_MONTH_LABEL_GAP_COLS) {
      monthLabels.push(label);
      lastKeptCol = label.col;
    }
  }

  const maxValue = Math.max(0, ...counts.values());
  return {
    cells: cells.map((c) => ({ ...c, level: heatLevel(c.value, maxValue) })),
    monthLabels,
    totalColumns: col,
    total,
  };
}
