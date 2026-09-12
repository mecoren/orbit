/**
 * 筛选器可视化构建器模型单测：条件⇄表单双向映射 + 工具栏预填
 */
import { describe, expect, it } from "vitest";
import { buildConditions, EMPTY_FILTER_FORM, parseConditions, toolbarToForm } from "./saved-filter-builder";

describe("parseConditions", () => {
  it("七键条件 JSON 全量还原表单态", () => {
    const raw = JSON.stringify({
      status: "pending",
      priority_min: 3,
      project_ids: [1, 2],
      label_ids: [5],
      due_within_days: 7,
      due_overdue: true,
      favorite_only: true,
    });
    const f = parseConditions(raw);
    expect(f.status).toBe("pending");
    expect(f.priorityMin).toBe(3);
    expect(f.projectIds).toEqual([1, 2]);
    expect(f.labelIds).toEqual([5]);
    expect(f.dueWithinDays).toBe(7);
    expect(f.overdueOnly).toBe(true);
    expect(f.favoriteOnly).toBe(true);
  });

  it("缺键回退空表单、损坏 JSON 防御回退", () => {
    expect(parseConditions("{}")).toEqual(EMPTY_FILTER_FORM);
    expect(parseConditions("not-json")).toEqual(EMPTY_FILTER_FORM);
  });
});

describe("buildConditions", () => {
  it("空维度不落键、全空产出 {}", () => {
    expect(buildConditions(EMPTY_FILTER_FORM)).toBe("{}");
    const out = buildConditions({ ...EMPTY_FILTER_FORM, priorityMin: 4 });
    expect(JSON.parse(out)).toEqual({ priority_min: 4 });
  });

  it("完整表单产出七键 JSON（Rust 白名单对齐）", () => {
    const out = buildConditions({
      status: "doing",
      priorityMin: 2,
      projectIds: [7],
      labelIds: [3, 9],
      dueWithinDays: 30,
      overdueOnly: false,
      favoriteOnly: true,
    });
    const c = JSON.parse(out);
    expect(c).toEqual({ status: "doing", priority_min: 2, project_ids: [7], label_ids: [3, 9], due_within_days: 30, favorite_only: true });
    expect(Object.keys(c).sort()).toEqual(["due_within_days", "favorite_only", "label_ids", "priority_min", "project_ids", "status"]);
  });
});

describe("parse ⇄ build 往返", () => {
  it("build → parse 无损", () => {
    const f = { ...EMPTY_FILTER_FORM, status: "pending", priorityMin: 4, dueWithinDays: 7, overdueOnly: true };
    expect(parseConditions(buildConditions(f))).toEqual(f);
  });
});

describe("toolbarToForm（存为视图预填）", () => {
  it("状态/优先级/收藏三档映射；all 与 undone 丢弃", () => {
    const f = toolbarToForm({ statusFilter: "pending", priorityFilter: 3, favoriteOnly: false });
    expect(f.status).toBe("pending");
    expect(f.priorityMin).toBe(3);
    expect(f.favoriteOnly).toBe(false);
    expect(toolbarToForm({ statusFilter: "all", priorityFilter: null, favoriteOnly: true }).status).toBeNull();
    expect(toolbarToForm({ statusFilter: "undone", priorityFilter: null, favoriteOnly: false }).status).toBeNull();
  });
});
