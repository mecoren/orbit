import * as React from "react";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { XIcon } from "lucide-react";

import { cn } from "@/lib/utils";
import { useResizableDialog, ResizeHandle } from "@/hooks/use-resizable-dialog";

function Dialog(props: React.ComponentProps<typeof DialogPrimitive.Root>) {
  return <DialogPrimitive.Root data-slot="dialog" {...props} />;
}

function DialogTrigger(
  props: React.ComponentProps<typeof DialogPrimitive.Trigger>,
) {
  return <DialogPrimitive.Trigger data-slot="dialog-trigger" {...props} />;
}

function DialogPortal(
  props: React.ComponentProps<typeof DialogPrimitive.Portal>,
) {
  return <DialogPrimitive.Portal data-slot="dialog-portal" {...props} />;
}

function DialogClose(props: React.ComponentProps<typeof DialogPrimitive.Close>) {
  return <DialogPrimitive.Close data-slot="dialog-close" {...props} />;
}

function DialogOverlay({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      data-slot="dialog-overlay"
      className={cn(
        // R3 修复：移除 animate-in/animate-out/fade-in-0/fade-out-0。
        // 原因：tailwindcss-animate 的 @keyframes enter 在 from 状态设置
        // transform: translate3d(0,0,0) scale3d(1,1,1) rotate(0)，
        // 在 Tailwind v4 + @plugin 加载方式下，animation-fill-mode 行为异常，
        // 导致动画结束后 transform 保持在 from 状态，覆盖 DialogContent 的
        // -translate-x-1/2 -translate-y-1/2，使内容偏移到视口外。
        // 改用纯 CSS transition 实现淡入淡出，不依赖 tailwindcss-animate。
        "fixed inset-0 z-50 bg-black/50 transition-opacity duration-base data-[state=open]:opacity-100 data-[state=closed]:opacity-0",
        className,
      )}
      {...props}
    />
  );
}

interface DialogContentProps
  extends React.ComponentProps<typeof DialogPrimitive.Content> {
  /** 是否启用标题栏拖拽，默认 false 以保持与现有弹窗兼容 */
  draggable?: boolean;
  /** 是否启用边缘缩放，默认 false 以保持与现有弹窗兼容 */
  resizable?: boolean;
  /** 是否显示右上角关闭按钮，默认 true */
  showCloseButton?: boolean;
}

function DialogContent({
  className,
  children,
  draggable = false,
  resizable = false,
  showCloseButton = true,
  ...props
}: DialogContentProps) {
  const { width, height, x, y, startDrag, startResize } = useResizableDialog({
    disabled: !resizable && !draggable,
  });

  const isInteractive = draggable || resizable;

  return (
    <DialogPortal data-slot="dialog-portal">
      <DialogOverlay />
      <DialogPrimitive.Content
        data-slot="dialog-content"
        className={cn(
          // R3 修复：移除所有 animate-in/animate-out/fade-in-0/fade-out-0 类，
          // 避免 tailwindcss-animate 的 keyframes 覆盖定位类。
          "bg-background z-50 flex flex-col gap-4 rounded-lg border shadow-lg transition-all duration-base data-[state=open]:opacity-100 data-[state=open]:scale-100 data-[state=closed]:opacity-0 data-[state=closed]:scale-95",
          // 未启用交互时使用默认居中定位
          // Fix-37：增加视口高度约束 + 纵向滚动兜底，长内容弹窗不再溢出视口且不可滚
          !isInteractive &&
            "fixed top-1/2 left-1/2 w-full max-w-[calc(100%-2rem)] max-h-[calc(100vh-4rem)] overflow-y-auto -translate-x-1/2 -translate-y-1/2 p-6 sm:max-w-lg",
          // 启用交互时尺寸/位置由 inline style 控制
          isInteractive && "fixed overflow-hidden",
          className,
        )}
        style={
          isInteractive
            ? { left: x, top: y, width, height }
            : undefined
        }
        {...props}
      >
        {isInteractive && draggable && (
          <div
            data-slot="dialog-drag-handle"
            className="absolute top-0 right-10 left-0 z-50 h-8 cursor-move"
            onMouseDown={startDrag}
          />
        )}
        {children}
        {showCloseButton && (
          <DialogPrimitive.Close className="ring-offset-background focus:ring-ring data-[state=open]:bg-accent data-[state=open]:text-muted-foreground absolute top-4 right-4 z-50 rounded-xs opacity-70 transition-opacity hover:opacity-100 focus:ring-2 focus:ring-offset-2 focus:outline-none disabled:pointer-events-none [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([data-icon])]:size-4">
            <XIcon />
            <span className="sr-only">关闭</span>
          </DialogPrimitive.Close>
        )}
        {isInteractive && resizable && (
          <>
            <ResizeHandle direction="n" onMouseDown={startResize} />
            <ResizeHandle direction="s" onMouseDown={startResize} />
            <ResizeHandle direction="e" onMouseDown={startResize} />
            <ResizeHandle direction="w" onMouseDown={startResize} />
            <ResizeHandle direction="ne" onMouseDown={startResize} />
            <ResizeHandle direction="nw" onMouseDown={startResize} />
            <ResizeHandle direction="se" onMouseDown={startResize} />
            <ResizeHandle direction="sw" onMouseDown={startResize} />
          </>
        )}
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}

function DialogHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-header"
      className={cn("flex flex-col gap-2 text-center sm:text-left", className)}
      {...props}
    />
  );
}

function DialogFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn(
        "flex flex-col-reverse gap-2 sm:flex-row sm:justify-end",
        className,
      )}
      {...props}
    />
  );
}

function DialogTitle(
  props: React.ComponentProps<typeof DialogPrimitive.Title>,
) {
  return (
    <DialogPrimitive.Title
      data-slot="dialog-title"
      className={cn("text-lg leading-none font-semibold", props.className)}
      {...props}
    />
  );
}

function DialogDescription(
  props: React.ComponentProps<typeof DialogPrimitive.Description>,
) {
  return (
    <DialogPrimitive.Description
      data-slot="dialog-description"
      className={cn("text-muted-foreground text-sm", props.className)}
      {...props}
    />
  );
}

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogOverlay,
  DialogPortal,
  DialogTitle,
  DialogTrigger,
};
