/**
 * 侧边栏选中入口导航兜底口径（2026-09-08 用户报告：回收站/统计面板下
 * 点侧边栏其他菜单无反应，须先点右上角「待办」才能恢复）。
 * 根因：快捷视图/项目点击只改壳层 state 不跳路由，嵌套子面板
 * （/todo/trash、/todo/stats）下 TaskPanel 未挂载，state 改动不可见。
 */
import { describe, expect, it } from "vitest";
import { needsTodoIndexNav, TODO_INDEX_PATH } from "./sidebar-nav";

describe("needsTodoIndexNav 侧边栏选中入口导航兜底", () => {
  it("任务面板路由（/todo）不需要导航——点击直接生效于已挂载的 TaskPanel", () => {
    expect(needsTodoIndexNav("/todo")).toBe(false);
  });

  it("回收站面板路由（/todo/trash）需要先导航回 /todo（用户报告失灵路径）", () => {
    expect(needsTodoIndexNav("/todo/trash")).toBe(true);
  });

  it("统计面板路由（/todo/stats）需要先导航回 /todo（用户报告失灵路径）", () => {
    expect(needsTodoIndexNav("/todo/stats")).toBe(true);
  });

  it("非 /todo 前缀的异常路由也判需要（防御口径）", () => {
    expect(needsTodoIndexNav("/settings")).toBe(true);
  });

  it("兜底目标常量为 /todo（与壳层 index 子路由一致）", () => {
    expect(TODO_INDEX_PATH).toBe("/todo");
  });
});
