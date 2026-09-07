/**
 * reminder-nav — 提醒场景的任务详情入口动作（§7-③）
 *
 * 与全局搜索/命令面板同范式：写 selectedTaskId + 导航 /todo，
 * 详情抽屉监听 store 打开。独立成模块供 toast 回调与测试直接引用
 * （组件内联闭包无法在 node 单测环境验证）。
 */
import { useTodoStore } from "../store";

/** 打开指定任务详情；返回导航目标（调用方 navigate 用） */
export function openTaskFromReminder(taskId: number): string {
  useTodoStore.getState().setSelectedTaskId(taskId);
  return "/todo";
}
