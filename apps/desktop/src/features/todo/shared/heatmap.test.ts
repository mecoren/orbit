// 完成热力图纯函数（2026-09-10 对齐 wait-home）：铺格 / 色阶档 / 月份标签过滤
import { describe, expect, it } from "vitest";
import { heatLevel, heatmapDateRange, layoutHeatmap, MIN_MONTH_LABEL_GAP_COLS } from "./heatmap";

/** 固定"今天"= 2026-09-10（周四）——所有断言按此基准推演 */
const NOW = new Date(2026, 8, 10);

describe("heatmapDateRange", () => {
  it("当前年 = 滚动 365 天（今天往前 364 天到今天）", () => {
    const { from, to } = heatmapDateRange(2026, NOW);
    expect(format(from)).toBe("2025-09-11");
    expect(format(to)).toBe("2026-09-10");
  });

  it("历史年 = 完整 1/1 ~ 12/31", () => {
    const { from, to } = heatmapDateRange(2025, NOW);
    expect(format(from)).toBe("2025-01-01");
    expect(format(to)).toBe("2025-12-31");
  });
});

describe("heatLevel", () => {
  it("空值 → 0 档", () => {
    expect(heatLevel(0, 10)).toBe(0);
  });

  it("锚定 max≥4：1/2/3 条各占一档，≥4 按 25/50/75 比例分档", () => {
    // max=2 也不允许 2 条直接吃满最深色（GitHub 语义）
    expect(heatLevel(1, 2)).toBe(1);
    expect(heatLevel(2, 2)).toBe(2);
    // max=4：1→1、2→2、3→3、4→4
    expect(heatLevel(1, 4)).toBe(1);
    expect(heatLevel(2, 4)).toBe(2);
    expect(heatLevel(3, 4)).toBe(3);
    expect(heatLevel(4, 4)).toBe(4);
    // max=8：比例分档（2/8=25%→1、3/8→2、5/8→3、7/8→4）
    expect(heatLevel(2, 8)).toBe(1);
    expect(heatLevel(3, 8)).toBe(2);
    expect(heatLevel(5, 8)).toBe(3);
    expect(heatLevel(7, 8)).toBe(4);
  });
});

describe("layoutHeatmap", () => {
  it("当前年铺 365 格、365 天跨年（含去年尾部）；col/row 以窗口首日星期起铺", () => {
    const { cells, totalColumns } = layoutHeatmap(new Map(), 2026, NOW);
    expect(cells.length).toBe(365);
    // 2025-09-11 是周四 → 首格 row=4（周一=1）
    expect(cells[0]).toMatchObject({ day: "2025-09-11", row: 4, col: 1 });
    // 末日 2026-09-10（周四）所在列 = 总列数
    expect(cells[364].col).toBe(totalColumns);
    // 行到周日换列：第一天起第 4 格到周日（row 7），下一格 row=1 col=2
    expect(cells[3]).toMatchObject({ row: 7, col: 1 });
    expect(cells[4]).toMatchObject({ row: 1, col: 2 });
  });

  it("历史年铺全年格数（2025 = 365 天，首日 1/1 周三）", () => {
    const { cells } = layoutHeatmap(new Map(), 2025, NOW);
    expect(cells.length).toBe(365);
    expect(cells[0]).toMatchObject({ day: "2025-01-01", row: 3 });
  });

  it("月份标签按最小列距过滤 + total 累计窗口内完成数", () => {
    const counts = new Map([
      ["2026-09-10", 2],
      ["2026-09-09", 1],
      // 窗口外（2025 年区间之外的日子塞了也不该计入 total）
      ["2024-01-01", 5],
    ]);
    const { monthLabels, total } = layoutHeatmap(counts, 2026, NOW);
    expect(total).toBe(3);
    // 滚动窗口从 2025-09 跨到 2026-09：首标签 9月，后续月份按 ≥4 列距保留
    expect(monthLabels[0]).toMatchObject({ text: "9月", col: 1 });
    const cols = monthLabels.map((l) => l.col);
    for (let i = 1; i < cols.length; i++) {
      expect(cols[i] - cols[i - 1]).toBeGreaterThanOrEqual(MIN_MONTH_LABEL_GAP_COLS);
    }
    // 12 个月至少保住 12 个标签（365 格 / ~7 列每月，4 列距足够全保）
    expect(monthLabels.length).toBe(12);
  });
});

function format(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
