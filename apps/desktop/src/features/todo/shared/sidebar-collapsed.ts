// apps/desktop/src/features/todo/shared/sidebar-collapsed.ts
// 窄窗侧栏折叠语义（07 报告 #21）：useIsNarrow 断点驱动 + 用户手动覆盖。
//
// 规则（04 §二「<1024 自动折叠」）：
// - 无手动状态：断点决定（窄→折叠，宽→展开）
// - 有手动状态：用户意图优先于断点（窄窗下仍可手动展开，跨断点往返保持）
// 手动状态由调用方持久化（localStorage），本函数保持纯语义便于单测。

export interface SidebarCollapseInput {
  /** 是否窄窗（<lg=1024px，useIsNarrow） */
  isNarrow: boolean;
  /** 用户手动覆盖；null = 从未手动干预 */
  manual: boolean | null;
}

/** 解析侧栏最终折叠态：手动覆盖优先于断点自动折叠 */
export function resolveSidebarCollapsed(input: SidebarCollapseInput): boolean {
  if (input.manual != null) return input.manual;
  return input.isNarrow;
}

/** localStorage 键：侧栏手动折叠状态（三态：缺失=未干预/"1"/"0"） */
export const LS_SIDEBAR_MANUAL_COLLAPSED = "orbit.sidebar.manualCollapsed";

/** 读取持久化的手动状态；从未干预返回 null */
export function loadSidebarManualCollapsed(): boolean | null {
  const v = localStorage.getItem(LS_SIDEBAR_MANUAL_COLLAPSED);
  if (v == null || v === "") return null;
  return v === "1";
}

/** 持久化手动状态（null 清除干预记录，回到断点自动模式） */
export function saveSidebarManualCollapsed(manual: boolean | null): void {
  if (manual == null) localStorage.removeItem(LS_SIDEBAR_MANUAL_COLLAPSED);
  else localStorage.setItem(LS_SIDEBAR_MANUAL_COLLAPSED, manual ? "1" : "0");
}
