// apps/desktop/src/features/todo/store.test.ts
// §7-③ 编排测试：openTaskFromReminder（提醒 toast「查看任务」入口动作）。
// openTaskFromReminder 是 ReminderToast onViewTask 的接线实现——
// 写 selectedTaskId + 由调用方导航 /todo；store 状态语义不回归。
import { beforeEach, describe, expect, it } from "vitest";

import { useTodoStore } from "./store";
import { openTaskFromReminder } from "./shared/reminder-nav";

describe("openTaskFromReminder", () => {
  beforeEach(() => {
    useTodoStore.setState({ selectedTaskId: null });
  });

  it("写入传入任务 id 到 selectedTaskId（详情抽屉打开）", () => {
    openTaskFromReminder(42);
    expect(useTodoStore.getState().selectedTaskId).toBe(42);
  });

  it("返回导航目标 /todo（抽屉常驻跨面板，由调用方 navigate）", () => {
    expect(openTaskFromReminder(42)).toBe("/todo");
  });

  it("多次调用以最后一次为准（连发两条提醒点最新一条）", () => {
    openTaskFromReminder(1);
    openTaskFromReminder(2);
    expect(useTodoStore.getState().selectedTaskId).toBe(2);
  });
});
