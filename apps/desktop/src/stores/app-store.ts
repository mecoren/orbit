import { create } from "zustand";

interface AppState {
  commandOpen: boolean;
  setCommandOpen: (open: boolean) => void;
  toggleCommand: () => void;
  /**
   * 「新建任务」意图计数器（07 报告 §五-P1#8）：
   * 命令面板挂在 AppShell 壳层，而新建表单状态在 list-page 内部——
   * 用递增计数器跨层传递动作意图，页面 effect 监听增量后打开表单。
   */
  taskFormIntent: number;
  bumpTaskFormIntent: () => void;
  /** 「切换视图」意图计数器（list ⇄ kanban），机制同上 */
  viewToggleIntent: number;
  bumpViewToggleIntent: () => void;
}

export const useAppStore = create<AppState>((set) => ({
  commandOpen: false,
  setCommandOpen: (open) => set({ commandOpen: open }),
  toggleCommand: () => set((s) => ({ commandOpen: !s.commandOpen })),
  taskFormIntent: 0,
  bumpTaskFormIntent: () => set((s) => ({ taskFormIntent: s.taskFormIntent + 1 })),
  viewToggleIntent: 0,
  bumpViewToggleIntent: () => set((s) => ({ viewToggleIntent: s.viewToggleIntent + 1 })),
}));
