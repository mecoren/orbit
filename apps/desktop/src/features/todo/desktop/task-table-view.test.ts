import { describe, expect, it } from "vitest";
import { TABLE_COLUMNS } from "./task-table-view";

describe("表格视图列模型", () => {
  it("固定六列：完成/标题/项目/标签/截止/优先级（顺序即展示序）", () => {
    expect(TABLE_COLUMNS.map((c) => c.key)).toEqual([
      "done",
      "title",
      "project",
      "labels",
      "due",
      "priority",
    ]);
  });

  it("每列有中文名与 >0 的相对宽度权重", () => {
    expect(TABLE_COLUMNS.every((c) => c.label.length > 0 && c.weight > 0)).toBe(true);
  });

  it("grid 模板串按权重生成（表头与数据行共享同一模板保证对齐）", () => {
    expect(gridTemplateOf(TABLE_COLUMNS)).toBe(
      "minmax(2.5rem,0.6fr) minmax(10rem,2.4fr) minmax(2.5rem,1fr) minmax(2.5rem,1fr) minmax(2.5rem,1fr) minmax(2.5rem,0.8fr)",
    );
  });
});

/** 权重 → grid 模板列（从组件导出同名纯函数验证） */
import { gridTemplateOf } from "./task-table-view";
