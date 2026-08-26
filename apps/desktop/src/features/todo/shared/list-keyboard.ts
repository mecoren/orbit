// apps/desktop/src/features/todo/shared/list-keyboard.ts
/**
 * 任务列表键盘导航语义（07 报告 §五-P1#8）
 *
 * j/k 或 ↑/↓ 移动焦点（滚动跟随由调用方 scrollToIndex 实现）；
 * Enter/Space 激活当前行（打开详情抽屉）。纯函数便于 node 环境单测。
 */
export type ListNavDirection = "up" | "down";

export function listNavDirection(key: string): ListNavDirection | null {
  if (key === "j" || key === "ArrowDown") return "down";
  if (key === "k" || key === "ArrowUp") return "up";
  return null;
}

export function isListActivationKey(key: string): boolean {
  return key === "Enter" || key === " ";
}
