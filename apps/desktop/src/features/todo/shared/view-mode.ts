/**
 * 五档视图顺序与循环切换语义（桌面「切换视图」单钮 + 命令面板意图共用）
 *
 * 顺序即钮面左键的遍历序：list → kanban → calendar → table → matrix → list。
 * 2026-10-30 前 task-panel 的意图消费与 toolbar-menus 的 VIEW_TABS 各持一份顺序
 * （前者是链式三元，后者是菜单排布），加档时必然漂移——本文件收成唯一真相源，
 * 纯函数无 React 依赖，便于单测。
 *
 * 菜单项全名（列表视图/看板视图…）留在 UI 层 VIEW_TABS：e2e 选择器依赖它；
 * 本文件只给提示语用的短名。
 */

/** 视图顺序（唯一真相源） */
export const VIEW_MODE_ORDER = ["list", "kanban", "calendar", "table", "matrix"] as const;

export type ViewMode = (typeof VIEW_MODE_ORDER)[number];

/** 短名（tooltip「列表 → 看板」用） */
export const VIEW_MODE_SHORT_LABEL: Record<ViewMode, string> = {
  list: "列表",
  kanban: "看板",
  calendar: "日历",
  table: "表格",
  matrix: "矩阵",
};

/** 下一档（末档回到首档）；脏值按首档兜底，保证钮面永远有合法目标 */
export function nextViewMode(mode: ViewMode): ViewMode {
  const i = VIEW_MODE_ORDER.indexOf(mode);
  return VIEW_MODE_ORDER[(i + 1) % VIEW_MODE_ORDER.length] ?? VIEW_MODE_ORDER[0];
}
