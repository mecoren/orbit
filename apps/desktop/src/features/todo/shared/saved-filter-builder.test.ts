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
    // 新键缺席回退空维度
    expect(f.dueFrom).toBeNull();
    expect(f.hasReminder).toBeNull();
  });

  it("十四键条件 JSON 全量还原（含区间/时间下限/存在三态）", () => {
    const raw = JSON.stringify({
      due_from: 1000,
      due_until: 2000,
      created_from: 3000,
      done_from: 4000,
      has_reminder: true,
      has_attachment: false,
      has_open_subtask: true,
    });
    const f = parseConditions(raw);
    expect(f.dueFrom).toBe(1000);
    expect(f.dueUntil).toBe(2000);
    expect(f.createdFrom).toBe(3000);
    expect(f.doneFrom).toBe(4000);
    expect(f.hasReminder).toBe(true);
    expect(f.hasAttachment).toBe(false);
    expect(f.hasOpenSubtask).toBe(true);
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
      dueFrom: null,
      dueUntil: null,
      createdFrom: null,
      doneFrom: null,
      hasReminder: null,
      hasAttachment: null,
      hasOpenSubtask: null,
    });
    const c = JSON.parse(out);
    expect(c).toEqual({ status: "doing", priority_min: 2, project_ids: [7], label_ids: [3, 9], due_within_days: 30, favorite_only: true });
    expect(Object.keys(c).sort()).toEqual(["due_within_days", "favorite_only", "label_ids", "priority_min", "project_ids", "status"]);
  });

  it("新维度产出对应键（存在 false 也落键）", () => {
    const out = buildConditions({
      ...EMPTY_FILTER_FORM,
      dueFrom: 1000,
      dueUntil: 2000,
      createdFrom: 3000,
      doneFrom: 4000,
      hasReminder: true,
      hasAttachment: false,
      hasOpenSubtask: null,
    });
    expect(JSON.parse(out)).toEqual({
      due_from: 1000,
      due_until: 2000,
      created_from: 3000,
      done_from: 4000,
      has_reminder: true,
      has_attachment: false,
    });
  });
});

describe("parse ⇄ build 往返", () => {
  it("build → parse 无损", () => {
    const f = { ...EMPTY_FILTER_FORM, status: "pending", priorityMin: 4, dueWithinDays: 7, overdueOnly: true };
    expect(parseConditions(buildConditions(f))).toEqual(f);
  });

  it("新维度往返无损", () => {
    const f = {
      ...EMPTY_FILTER_FORM,
      projectIds: [],
      labelIds: [],
      dueFrom: 1000,
      hasAttachment: false,
    };
    expect(parseConditions(buildConditions(f))).toEqual(f);
  });
});

describe("toolbarToForm（保存为筛选器预填）", () => {
  it("状态/优先级/收藏三档映射；空集与未完成档丢弃", () => {
    const f = toolbarToForm({ statusFilters: ["pending"], priorityFilter: 3, favoriteOnly: false });
    expect(f.status).toBe("pending");
    expect(f.priorityMin).toBe(3);
    expect(f.favoriteOnly).toBe(false);
    expect(toolbarToForm({ statusFilters: [], priorityFilter: null, favoriteOnly: true }).status).toBeNull();
    // 待办+进行中 = 未完成档，条件白名单没有对应键 → 丢弃（提示层说明）
    expect(
      toolbarToForm({ statusFilters: ["pending", "doing"], priorityFilter: null, favoriteOnly: false })
        .status,
    ).toBeNull();
  });

  it("多选跨完成态时也只取单一状态档（条件 JSON 的 status 是等值键）", () => {
    expect(
      toolbarToForm({ statusFilters: ["pending", "done"], priorityFilter: null, favoriteOnly: false })
        .status,
    ).toBeNull();
  });
});
