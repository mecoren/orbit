import { create } from "zustand";

interface AppState {
  commandOpen: boolean;
  setCommandOpen: (open: boolean) => void;
  toggleCommand: () => void;
  /**
   * 「新建任务」意图计数器（07 报告 §五-P1#8）：
   * 命令面板挂在 AppShell 壳层，而新建表单状态在 list-page 内部——
   * 用递增计数器跨层传递动作意图，页面 effect 监听增量后打开表单。
   * 消费即归零（评审 C1）：防止历史意图在页面重挂载时被重放。
   */
  taskFormIntent: number;
  bumpTaskFormIntent: () => void;
  consumeTaskFormIntent: () => void;
  /** 「切换视图」意图计数器（list ⇄ kanban），机制同上 */
  viewToggleIntent: number;
  bumpViewToggleIntent: () => void;
  consumeViewToggleIntent: () => void;
  /** 全局搜索对话框开关（Ctrl+K，07 §五-P1#9） */
  searchOpen: boolean;
  setSearchOpen: (open: boolean) => void;
  /** 快捷键帮助面板开关（? 呼出，快捷键 discoverability（全仓审计高价值缺口）） */
  shortcutHelpOpen: boolean;
  setShortcutHelpOpen: (open: boolean) => void;
  /**
   * 「快速新建」意图计数器（07 §16 托盘菜单）：托盘层（壳）与
   * QuickAddBar（页面内）跨层传递，机制同 taskFormIntent；
   * 消费即归零防重放。
   */
  quickAddIntent: number;
  bumpQuickAddIntent: () => void;
  consumeQuickAddIntent: () => void;
}

export const useAppStore = create<AppState>((set) => ({
  commandOpen: false,
  setCommandOpen: (open) => set({ commandOpen: open }),
  toggleCommand: () => set((s) => ({ commandOpen: !s.commandOpen })),
  taskFormIntent: 0,
  bumpTaskFormIntent: () => set((s) => ({ taskFormIntent: s.taskFormIntent + 1 })),
  consumeTaskFormIntent: () => set({ taskFormIntent: 0 }),
  viewToggleIntent: 0,
  bumpViewToggleIntent: () => set((s) => ({ viewToggleIntent: s.viewToggleIntent + 1 })),
  consumeViewToggleIntent: () => set({ viewToggleIntent: 0 }),
  searchOpen: false,
  setSearchOpen: (open) => set({ searchOpen: open }),
  shortcutHelpOpen: false,
  setShortcutHelpOpen: (open) => set({ shortcutHelpOpen: open }),
  quickAddIntent: 0,
  bumpQuickAddIntent: () => set((s) => ({ quickAddIntent: s.quickAddIntent + 1 })),
  consumeQuickAddIntent: () => set({ quickAddIntent: 0 }),
}));
