/**
 * ScrollArea —— Radix 滚动区（qraft 同款悬浮滚动条）
 *
 * 与全局滚动条美化（index.css ::-webkit-scrollbar）观感一致：
 * 轨道透明、滑块用 --scrollbar-slider-* token，hover 加深。
 * - 轨道 pointer-events-none：滚动条是「悬浮」在内容之上的 overlay，
 *   鼠标穿透——被滚动条覆盖的边缘内容仍可正常点击；
 * - 滑块 pointer-events-auto：保持可拖拽。
 * index.css 顶层还有 [data-slot="scroll-area-thumb"] 兜底着色规则，
 * 防 Tailwind v4 prod scan 漏掉任意值 utility 时滑块无色。
 */
import * as React from "react";
import * as ScrollAreaPrimitive from "@radix-ui/react-scroll-area";

import { cn } from "@/lib/utils";

function ScrollArea({
  className,
  children,
  viewportRef,
  viewportClassName,
  orientation = "vertical",
  scrollbarClassName,
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive.Root> & {
  /** 转发到内部 Viewport，供外部读取滚动容器（监听 scroll / 主动 scrollTo） */
  viewportRef?: React.Ref<React.ComponentRef<typeof ScrollAreaPrimitive.Viewport>>;
  /** Viewport 额外样式，用于给悬浮滚动条预留空间 */
  viewportClassName?: string;
  /** 内置滚动条方向，默认垂直；横向滚动内容传 "horizontal" */
  orientation?: "vertical" | "horizontal";
  /** 滚动条额外样式（覆盖默认轨道/滑块尺寸），用于细悬浮条等特例 */
  scrollbarClassName?: string;
}) {
  return (
    <ScrollAreaPrimitive.Root
      data-slot="scroll-area"
      className={cn("relative overflow-hidden", className)}
      {...props}
    >
      <ScrollAreaPrimitive.Viewport
        ref={viewportRef}
        data-slot="scroll-area-viewport"
        className={cn(
          "focus-visible:ring-ring/50 size-full rounded-[inherit] transition-[color,box-shadow] outline-none focus-visible:ring-[3px] focus-visible:outline-1",
          viewportClassName,
        )}
      >
        {children}
      </ScrollAreaPrimitive.Viewport>
      <ScrollBar orientation={orientation} className={scrollbarClassName} />
      <ScrollAreaPrimitive.Corner />
    </ScrollAreaPrimitive.Root>
  );
}

function ScrollBar({
  className,
  orientation = "vertical",
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive.ScrollAreaScrollbar>) {
  return (
    <ScrollAreaPrimitive.ScrollAreaScrollbar
      data-slot="scroll-area-scrollbar"
      orientation={orientation}
      // 与全局滚动条美化一致：14px 轨道 + 主题色圆角滑块（2px 内缩）
      className={cn(
        "group flex touch-none select-none transition-colors",
        // 轨道可穿透：悬浮滚动条不拦截下层内容的鼠标交互
        "pointer-events-none",
        orientation === "vertical" && "h-full w-3.5 p-[2px]",
        orientation === "horizontal" && "h-3.5 flex-col p-[2px]",
        className,
      )}
      {...props}
    >
      <ScrollAreaPrimitive.ScrollAreaThumb
        data-slot="scroll-area-thumb"
        className="pointer-events-auto relative flex-1 rounded-full bg-[var(--scrollbar-slider-bg)] transition-colors duration-slow group-hover:bg-[var(--scrollbar-slider-hover-bg)]"
      />
    </ScrollAreaPrimitive.ScrollAreaScrollbar>
  );
}

export { ScrollArea, ScrollBar };
