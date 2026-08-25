/**
 * 移动端长按 hook（05 §六 换算速查：pointerdown 起 500ms 定时器 + contextmenu preventDefault）
 *
 * 从 sidebar-screen.tsx 抽取共享（Task 12）；后续详情屏长按交互复用。
 * 位移 >10px 或抬起/取消即中止；长按触发后的合成 click 必须吞掉，
 * 否则导航卸载当前屏、弹层流程被打断。
 */
import { useEffect, useRef } from "react";
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent } from "react";

export function useLongPress(onLongPress: () => void, enabled = true) {
  const timer = useRef<number | null>(null);
  const origin = useRef<{ x: number; y: number } | null>(null);
  // 长按已触发标记：抬指后的合成 click 必须吞掉，否则导航卸载当前屏、删除流程被打断
  const firedRef = useRef(false);
  const clear = () => {
    if (timer.current != null) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
    origin.current = null;
  };
  useEffect(() => clear, []); // 卸载兜底清计时器

  return {
    onPointerDown: (e: ReactPointerEvent) => {
      if (!enabled || e.button !== 0 || !e.isPrimary) return;
      origin.current = { x: e.clientX, y: e.clientY };
      firedRef.current = false;
      timer.current = window.setTimeout(() => {
        clear();
        firedRef.current = true;
        onLongPress();
      }, 500);
    },
    onPointerMove: (e: ReactPointerEvent) => {
      const o = origin.current;
      if (o && Math.hypot(e.clientX - o.x, e.clientY - o.y) > 10) clear();
    },
    onPointerUp: clear,
    onPointerCancel: clear,
    /** 抑制长按弹出的系统右键菜单 */
    onContextMenu: (e: ReactMouseEvent) => e.preventDefault(),
    /** 长按触发后吞掉同元素的合成 click（capture 先于 bubble，stopPropagation 拦截同元素 onClick） */
    onClickCapture: (e: ReactMouseEvent) => {
      if (firedRef.current) {
        firedRef.current = false;
        e.stopPropagation();
      }
    },
  };
}
