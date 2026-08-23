/**
 * 通用右键菜单基元（04 文档 §3.7 ⚖ 重写）
 *
 * 蓝本是两套手写 fixed 定位 div；统一重写为 Radix DropdownMenu 的
 * 受控触发模式：拦截 contextmenu 记录坐标，将透明哨兵元素钉在鼠标位置
 * 作为 DropdownMenuTrigger 锚点。视觉基线沿用 shadcn 内容样式。
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
}: {
  /** 右键目标元素（行/卡片等） */
  children: ReactNode;
  /** 菜单内容；close 用于子项点击后收起 */
  menu: (close: () => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState({ x: 0, y: 0 });
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

      {/* 哨兵锚点：钉在右键坐标上 */}
      <span
        aria-hidden
        style={{
          position: "fixed",
          left: pos.x,
          top: pos.y,
          width: 1,
          height: 1,
          pointerEvents: open ? "auto" : "none",
        }}
      >
        <DropdownMenu open={open} onOpenChange={setOpen} modal>
          <DropdownMenuTrigger asChild>
            <span tabIndex={-1} className="block size-full" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" sideOffset={2} className="min-w-[200px]">
            {menu(close)}
          </DropdownMenuContent>
        </DropdownMenu>
      </span>
    </>
  );
}
