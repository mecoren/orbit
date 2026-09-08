/**
 * 侧边栏选中入口的导航兜底（2026-09-08 用户报告修复）
 *
 * 背景：快捷视图/项目/未分组的点击只改壳层 state 不跳路由；回收站/统计
 * 是嵌套路由面板（/todo/trash、/todo/stats），激活时中间区渲染的是
 * TrashPanel/StatsPanel，TaskPanel 未挂载——此时点侧边栏其他菜单
 * state 静默变化、界面无反应，须先点右上角「待办」navigate("/todo")
 * 才能恢复。壳层三个 onSelect 回调以此函数兜底：非任务面板路由时
 * 先导航回 /todo。
 */

/** /todo 嵌套壳层的任务面板路由（index 子路由） */
export const TODO_INDEX_PATH = "/todo";

/**
 * 当前壳层路由是否停在嵌套子面板（trash/stats）——
 * 此时选中入口点击需要先 navigate("/todo") 才能落到可见的 TaskPanel。
 */
export function needsTodoIndexNav(pathname: string): boolean {
  return pathname !== TODO_INDEX_PATH;
}
