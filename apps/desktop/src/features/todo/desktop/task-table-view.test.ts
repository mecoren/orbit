import { describe, expect, it } from "vitest";
import { COLUMN_SORT_KEY, gridTemplateOf, TABLE_COLUMNS } from "./task-table-view";

describe("表格视图列模型", () => {
  it("固定七列：完成/标题/项目/标签/开始/截止/时长（顺序即展示序）", () => {
    expect(TABLE_COLUMNS.map((c) => c.key)).toEqual([
      "done",
      "title",
      "project",
      "labels",
      "start",
      "due",
      "duration",
    ]);
  });

  it("优先级不单设列：由完成框描边承载，排序键挂在完成列表头", () => {
    expect(TABLE_COLUMNS.some((c) => (c.key as string) === "priority")).toBe(false);
    expect(COLUMN_SORT_KEY.done).toBe("priority");
  });

  it("开始/截止两列都可点表头排序（与工具栏同源）", () => {
    expect(COLUMN_SORT_KEY.start).toBe("start");
    expect(COLUMN_SORT_KEY.due).toBe("due");
  });

  it("每列有中文名与 >0 的相对宽度权重", () => {
    expect(TABLE_COLUMNS.every((c) => c.label.length > 0 && c.weight > 0)).toBe(true);
  });

  it("grid 模板串按权重生成（表头与数据行共享同一模板保证对齐）", () => {
    expect(gridTemplateOf(TABLE_COLUMNS)).toBe(
      "minmax(2.5rem,0.6fr) minmax(10rem,2.4fr) minmax(2.5rem,1fr) minmax(2.5rem,1fr) minmax(2.5rem,1fr) minmax(2.5rem,1fr) minmax(2.5rem,0.8fr)",
    );
  });
});
