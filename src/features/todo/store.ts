/**
 * features/todo/store — 待办模块轻量 zustand 状态
 *
 * §7-③ 规范化决策：命令面板点击任务 → 写入 selectedTaskId 并导航 /todo，
 * 详情抽屉监听该状态打开；不做 :id 路由（修复 wait-home 死链问题）。
 */
import { create } from "zustand";

interface TodoStore {
  /** 当前详情抽屉展示的任务 id（null = 关闭） */
  selectedTaskId: number | null;
  setSelectedTaskId: (id: number | null) => void;
}

export const useTodoStore = create<TodoStore>((set) => ({
  selectedTaskId: null,
  setSelectedTaskId: (id) => set({ selectedTaskId: id }),
}));
