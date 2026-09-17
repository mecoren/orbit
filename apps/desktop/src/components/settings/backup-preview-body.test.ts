import { describe, expect, it } from "vitest";

import {
  formatPreviewDate,
  orderedTableCounts,
  priorityLabel,
  statusLabel,
  tableLabel,
} from "./backup-preview-body";

describe("tableLabel", () => {
  it("已知表返回中文标签", () => {
    expect(tableLabel("todo_tasks")).toBe("任务");
    expect(tableLabel("todo_projects")).toBe("项目");
    expect(tableLabel("todo_templates")).toBe("模板");
  });

  it("未知表回落原名", () => {
    expect(tableLabel("future_table")).toBe("future_table");
  });
});

describe("orderedTableCounts", () => {
  it("过滤零计数并按固定顺序排列", () => {
    const rows = orderedTableCounts({
      todo_comments: 3,
      todo_tasks: 10,
      todo_projects: 0,
      todo_labels: 5,
    });
    expect(rows).toEqual([
      ["todo_tasks", 10],
      ["todo_labels", 5],
      ["todo_comments", 3],
    ]);
  });

  it("未知表追加在后", () => {
    const rows = orderedTableCounts({ future_table: 1, todo_tasks: 2 });
    expect(rows).toEqual([
      ["todo_tasks", 2],
      ["future_table", 1],
    ]);
  });

  it("全零返回空数组", () => {
    expect(orderedTableCounts({ todo_tasks: 0 })).toEqual([]);
  });
});

describe("statusLabel", () => {
  it("完成态优先", () => {
    expect(statusLabel("done", false)).toBe("已完成");
    expect(statusLabel("pending", true)).toBe("已完成");
  });

  it("进行中与待办", () => {
    expect(statusLabel("doing", false)).toBe("进行中");
    expect(statusLabel("pending", false)).toBe("待办");
    expect(statusLabel("whatever", false)).toBe("待办");
  });
});

describe("priorityLabel", () => {
  it("0 与越界返回 null（不展示）", () => {
    expect(priorityLabel(0)).toBeNull();
    expect(priorityLabel(9)).toBeNull();
  });

  it("1–5 返回中文档位", () => {
    expect(priorityLabel(1)).toBe("低");
    expect(priorityLabel(3)).toBe("高");
    expect(priorityLabel(5)).toBe("立即处理");
  });
});

describe("formatPreviewDate", () => {
  it("空返回无截止", () => {
    expect(formatPreviewDate(null)).toBe("无截止");
  });

  it("时间戳按本地 M/D 展示", () => {
    const d = new Date(2026, 8, 17, 12, 0, 0);
    expect(formatPreviewDate(d.getTime())).toBe("9/17");
  });
});
