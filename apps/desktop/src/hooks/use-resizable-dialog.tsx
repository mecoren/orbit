import * as React from "react";

import { cn } from "@/lib/utils";

// ============================================================
// 可拖拽/缩放弹窗状态管理
// 从 dialog.tsx 抽取，供自定义弹窗复用
// ============================================================

export type Size = { width: number; height: number };
export type Position = { x: number; y: number };
export type ResizeDirection = "n" | "s" | "e" | "w" | "ne" | "nw" | "se" | "sw";

export interface ResizableOptions {
  defaultSize?: Partial<Size>;
  minSize?: Partial<Size>;
  maxSize?: Partial<Size>;
  disabled?: boolean;
}

export const DEFAULT_MIN_SIZE: Size = { width: 600, height: 400 };

export function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

export function getDefaultState(options: ResizableOptions): Size & Position {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const minW = options.minSize?.width ?? DEFAULT_MIN_SIZE.width;
  const minH = options.minSize?.height ?? DEFAULT_MIN_SIZE.height;
  const maxW = options.maxSize?.width ?? vw;
  const maxH = options.maxSize?.height ?? vh;
  const width = clamp(options.defaultSize?.width ?? vw * 0.8, minW, maxW);
  const height = clamp(options.defaultSize?.height ?? vh * 0.8, minH, maxH);
  return {
    width,
    height,
    x: (vw - width) / 2,
    y: (vh - height) / 2,
  };
}

/**
 * 管理弹窗的位置、尺寸、拖拽和缩放状态。
 * 不持久化：每次打开使用默认居中尺寸，但当前显示期间保持用户调整结果。
 */
export function useResizableDialog(options: ResizableOptions) {
  const [state, setState] = React.useState<Size & Position>(() =>
    getDefaultState(options),
  );
  const [dragState, setDragState] = React.useState<{
    startX: number;
    startY: number;
    initialX: number;
    initialY: number;
  } | null>(null);
  const [resizeState, setResizeState] = React.useState<{
    direction: ResizeDirection;
    startX: number;
    startY: number;
    initialSize: Size;
    initialPosition: Position;
  } | null>(null);

  // 打开或配置变化时重置为默认居中
  React.useEffect(() => {
    setState(getDefaultState(options));
  }, [
    options.defaultSize?.width,
    options.defaultSize?.height,
    options.minSize?.width,
    options.minSize?.height,
    options.maxSize?.width,
    options.maxSize?.height,
  ]);

  const startDrag = React.useCallback(
    (e: React.MouseEvent) => {
      if (options.disabled) return;
      e.preventDefault();
      setDragState({
        startX: e.clientX,
        startY: e.clientY,
        initialX: state.x,
        initialY: state.y,
      });
    },
    [options.disabled, state.x, state.y],
  );

  const startResize = React.useCallback(
    (e: React.MouseEvent, direction: ResizeDirection) => {
      if (options.disabled) return;
      e.preventDefault();
      e.stopPropagation();
      setResizeState({
        direction,
        startX: e.clientX,
        startY: e.clientY,
        initialSize: { width: state.width, height: state.height },
        initialPosition: { x: state.x, y: state.y },
      });
    },
    [options.disabled, state.height, state.width, state.x, state.y],
  );

  React.useEffect(() => {
    if (!dragState && !resizeState) return;

    const handleMouseMove = (e: MouseEvent) => {
      if (dragState) {
        const dx = e.clientX - dragState.startX;
        const dy = e.clientY - dragState.startY;
        setState((prev) => ({
          ...prev,
          x: clamp(dragState.initialX + dx, 0, window.innerWidth - prev.width),
          y: clamp(
            dragState.initialY + dy,
            0,
            window.innerHeight - prev.height,
          ),
        }));
      }

      if (resizeState) {
        const dx = e.clientX - resizeState.startX;
        const dy = e.clientY - resizeState.startY;
        const minW = options.minSize?.width ?? DEFAULT_MIN_SIZE.width;
        const minH = options.minSize?.height ?? DEFAULT_MIN_SIZE.height;
        const maxW = options.maxSize?.width ?? window.innerWidth;
        const maxH = options.maxSize?.height ?? window.innerHeight;

        let width = resizeState.initialSize.width;
        let height = resizeState.initialSize.height;
        let x = resizeState.initialPosition.x;
        let y = resizeState.initialPosition.y;

        if (resizeState.direction.includes("e")) {
          width = resizeState.initialSize.width + dx;
        }
        if (resizeState.direction.includes("w")) {
          width = resizeState.initialSize.width - dx;
          x = resizeState.initialPosition.x + dx;
        }
        if (resizeState.direction.includes("s")) {
          height = resizeState.initialSize.height + dy;
        }
        if (resizeState.direction.includes("n")) {
          height = resizeState.initialSize.height - dy;
          y = resizeState.initialPosition.y + dy;
        }

        // 限制在最小/最大尺寸范围内；若被 clamp，需要回推位置保持对边不动
        const clampedWidth = clamp(width, minW, maxW);
        const clampedHeight = clamp(height, minH, maxH);

        if (resizeState.direction.includes("w")) {
          x = resizeState.initialPosition.x + (width - clampedWidth);
        }
        if (resizeState.direction.includes("n")) {
          y = resizeState.initialPosition.y + (height - clampedHeight);
        }

        // 保证缩放后仍不超出视口
        x = clamp(x, 0, window.innerWidth - clampedWidth);
        y = clamp(y, 0, window.innerHeight - clampedHeight);

        setState((prev) => ({
          ...prev,
          width: clampedWidth,
          height: clampedHeight,
          x,
          y,
        }));
      }
    };

    const handleMouseUp = () => {
      setDragState(null);
      setResizeState(null);
    };

    document.addEventListener("mousemove", handleMouseMove);
    document.addEventListener("mouseup", handleMouseUp);
    document.body.style.userSelect = "none";

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
      document.body.style.userSelect = "";
    };
  }, [dragState, options, resizeState]);

  return {
    ...state,
    startDrag,
    startResize,
    isDragging: !!dragState,
    isResizing: !!resizeState,
  };
}

export interface ResizeHandleProps {
  direction: ResizeDirection;
  onMouseDown: (e: React.MouseEvent, direction: ResizeDirection) => void;
}

/**
 * 边缘缩放触发点，覆盖在四边和四角。
 * 尺寸和鼠标样式随方向变化，视觉上完全透明。
 */
export function ResizeHandle({ direction, onMouseDown }: ResizeHandleProps) {
  const cursorMap: Record<ResizeDirection, string> = {
    n: "cursor-n-resize",
    s: "cursor-s-resize",
    e: "cursor-e-resize",
    w: "cursor-w-resize",
    ne: "cursor-ne-resize",
    nw: "cursor-nw-resize",
    se: "cursor-se-resize",
    sw: "cursor-sw-resize",
  };

  const positionClass: Record<ResizeDirection, string> = {
    n: "top-0 left-1/2 -translate-x-1/2 h-1.5 w-8",
    s: "bottom-0 left-1/2 -translate-x-1/2 h-1.5 w-8",
    e: "right-0 top-1/2 -translate-y-1/2 w-1.5 h-8",
    w: "left-0 top-1/2 -translate-y-1/2 w-1.5 h-8",
    ne: "top-0 right-0 w-2 h-2",
    nw: "top-0 left-0 w-2 h-2",
    se: "bottom-0 right-0 w-2 h-2",
    sw: "bottom-0 left-0 w-2 h-2",
  };

  return (
    <div
      data-resize={direction}
      className={cn(
        "absolute z-50 hover:bg-primary/20",
        cursorMap[direction],
        positionClass[direction],
      )}
      onMouseDown={(e) => onMouseDown(e, direction)}
    />
  );
}
