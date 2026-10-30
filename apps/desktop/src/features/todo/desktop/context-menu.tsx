/**
 * 通用右键菜单基元（04 文档 §3.7 ⚖ 重写）
 *
 * 蓝本是两套手写 fixed 定位 div；统一重写为 Radix DropdownMenu 的
 * 受控触发模式：拦截 contextmenu 记录坐标，将透明哨兵元素钉在鼠标位置
 * 作为 DropdownMenuTrigger 锚点。视觉基线沿用 shadcn 内容样式。
 *
 * 懒挂载（2026-10-30 滚动流畅度治理）：Radix DropdownMenu 的 Root 即使
 * 处于关闭态也要建一套 Provider/Trigger/Popper 上下文——列表虚拟化每帧
 * 重建可视行时，这些「关闭态菜单」把滚动脚本耗时翻了一倍多（实测 25 行
 * 窗口：ScriptDuration 2049ms → 718ms，p95 帧间隔 33ms → 16.7ms）。
 * 因此菜单树只在**真正右键打开时**才挂载：关闭态只剩一个 `display: contents`
 * 的事件壳，没有常驻 fixed 哨兵，也没有 Radix Root。
 */
import { useState, type ReactNode } from "react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export function ContextMenuBase({
  children,
  menu,
  onOpenChange,
}: {
  /** 右键目标元素（行/卡片等） */
  children: ReactNode;
  /** 菜单内容；close 用于子项点击后收起（只在打开时构造） */
  menu: (close: () => void) => ReactNode;
  /** 菜单开合回调：调用方据此重置菜单内的临时态（如内联确认区） */
  onOpenChange?: (open: boolean) => void;
}) {
  const [open, setOpenState] = useState(false);
  const [pos, setPos] = useState({ x: 0, y: 0 });
  const setOpen = (next: boolean) => {
    setOpenState(next);
    onOpenChange?.(next);
  };
  const close = () => setOpen(false);

  return (
    <>
      {/* 捕获右键，不阻止内部其他交互 */}
      <span
        className="contents"
        onContextMenu={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setPos({ x: e.clientX, y: e.clientY });
          setOpen(true);
        }}
      >
        {children}
      </span>

      {open && (
        // 哨兵锚点：钉在右键坐标上（仅打开期存在，关闭态零常驻节点）
        <span
          aria-hidden
          style={{
            position: "fixed",
            left: pos.x,
            top: pos.y,
            width: 1,
            height: 1,
          }}
        >
          <DropdownMenu defaultOpen onOpenChange={setOpen} modal>
            <DropdownMenuTrigger asChild>
              <span tabIndex={-1} className="block size-full" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" sideOffset={2} className="min-w-[200px]">
              {menu(close)}
            </DropdownMenuContent>
          </DropdownMenu>
        </span>
      )}
    </>
  );
}
