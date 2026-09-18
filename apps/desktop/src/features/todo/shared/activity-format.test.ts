/**
 * activity-format 单测：历史行文案格式化（changes 前后值 / 旧行 fields 回退 /
 * 标签动作 / 枚举值口径 / 长文本截断 / 非法 JSON 兜底）
 */
import { describe, expect, it } from "vitest";

import { describeActivity } from "./activity-format";

describe("describeActivity", () => {
  it("update 新行：changes 渲染前后值（优先级中文档位、null=无）", () => {
    const detail = JSON.stringify({
      fields: ["priority", "due_date"],
      changes: [
        { field: "priority", from: 0, to: 4 },
        { field: "due_date", from: null, to: "2026-09-25" },
      ],
    });
    expect(describeActivity("update", detail)).toBe(
      "更新（优先级：无 → 紧急、截止日期：无 → 2026-09-25）",
    );
  });

  it("update 旧行：无 changes 回退字段名清单", () => {
    const detail = JSON.stringify({ fields: ["priority", "project_id"] });
    expect(describeActivity("update", detail)).toBe("更新（优先级、所属项目）");
  });

  it("枚举/布尔/百分比值口径", () => {
    const detail = JSON.stringify({
      changes: [
        { field: "status", from: "pending", to: "doing" },
        { field: "is_favorite", from: 0, to: 1 },
        { field: "percent_done", from: 0, to: 60 },
        { field: "position", from: 1.23, to: 4.56 },
      ],
    });
    expect(describeActivity("update", detail)).toBe(
      "更新（状态：待办 → 进行中、收藏：否 → 是、进度：0% → 60%、顺序：已调整 → 已调整）",
    );
  });

  it("文本值超 30 字截断加省略号", () => {
    const long = "这是一段非常长的任务标题用于验证前端截断逻辑是否生效应该正好超过三十个字符";
    const detail = JSON.stringify({ changes: [{ field: "title", from: "短", to: long }] });
    const out = describeActivity("update", detail);
    expect(out).toContain(`${long.slice(0, 30)}…`);
    expect(out).not.toContain(long);
  });

  it("标签挂/摘动作拼标签名", () => {
    expect(describeActivity("label_add", JSON.stringify({ label: "工作" }))).toBe(
      "添加标签「工作」",
    );
    expect(describeActivity("label_remove", JSON.stringify({ label: "工作" }))).toBe(
      "移除标签「工作」",
    );
  });

  it("从属对象动作统一拼 target（子任务/关联/提醒）", () => {
    expect(describeActivity("subtask_add", JSON.stringify({ target: "写初稿" }))).toBe(
      "添加子任务「写初稿」",
    );
    expect(describeActivity("link_remove", JSON.stringify({ target: "对方任务" }))).toBe(
      "移除关联任务「对方任务」",
    );
    expect(
      describeActivity("reminder_add", JSON.stringify({ target: "2026-09-21 09:00" })),
    ).toBe("添加提醒「2026-09-21 09:00」");
    // target 缺失回退纯动作文案
    expect(describeActivity("comment_delete", "{}")).toBe("删除评论");
  });

  it("repeat_rule 伪字段：六字段快照对象走 repeatLabel 口径", () => {
    const snap = (mode: number, after: number, weekdays = 0) => ({
      mode,
      after,
      weekdays,
      end_type: 0,
      end_param: 0,
      from_done: 0,
    });
    const detail = JSON.stringify({
      changes: [{ field: "repeat_rule", from: snap(0, 0), to: snap(2, 1, 2) }],
    });
    expect(describeActivity("update", detail)).toBe("更新（重复规则：不重复 → 每周二）");
  });

  it("附件与子任务改名动作拼 target", () => {
    expect(describeActivity("attachment_add", JSON.stringify({ target: "报告.pdf" }))).toBe(
      "添加附件「报告.pdf」",
    );
    expect(describeActivity("attachment_delete", JSON.stringify({ target: "报告.pdf" }))).toBe(
      "移除附件「报告.pdf」",
    );
    expect(
      describeActivity("subtask_rename", JSON.stringify({ target: "旧名 → 新名" })),
    ).toBe("子任务改名「旧名 → 新名」");
  });

  it("非 update 动作与非法 JSON 回退动作文案", () => {
    expect(describeActivity("complete", "{}")).toBe("标记为完成");
    expect(describeActivity("create", "not-json")).toBe("创建了任务");
    expect(describeActivity("future_action", "{}")).toBe("future_action");
  });
});
