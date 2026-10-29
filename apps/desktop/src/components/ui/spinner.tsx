import * as React from "react";

import { cn } from "@/lib/utils";

// ── 几何比例（与移动端 `orbit_spinner.dart` / 参考实现 PiggyCount 同源）──
// 全部按环半径 / 边长比例表达，任意 size 下观感一致；禁止改成裸数字。
/** 环描边宽度 / 边长。 */
const STROKE_RATIO = 0.08;
/** 点心到圆心的距离 / 环半径。 */
const ORBIT_RATIO = 0.42;
/** 点半径 / 环半径。 */
const DOT_RATIO = 0.34;
/** 轨道（环）相对前景色的透明度；点用实色，两者拉开层次。 */
const TRACK_ALPHA = 0.28;
/** viewBox 基准边长：内部几何按此算，实际尺寸靠 width/height 等比缩放。 */
const VIEW = 24;

const RADIUS = (VIEW - VIEW * STROKE_RATIO) / 2;

/**
 * 组件几何（viewBox 坐标系；外部尺寸由 width/height 等比缩放，比例与 size 无关）。
 * 抽成纯数据便于单测锁定口径，防止几何常量被"顺手调一下"。
 */
export const SPINNER_GEOMETRY = {
  viewBox: VIEW,
  /** 环描边宽度 */
  strokeWidth: VIEW * STROKE_RATIO,
  /** 轨道透明度 */
  trackAlpha: TRACK_ALPHA,
  /** 绕行点半径 */
  dotRadius: RADIUS * DOT_RATIO,
  /** 绕行点圆心的 y（12 点方向） */
  dotCenterY: VIEW / 2 - RADIUS * ORBIT_RATIO,
} as const;

interface SpinnerProps
  extends Omit<React.ComponentProps<"svg">, "width" | "height"> {
  /** 方形边长（px），默认 16。按钮内 12~14，内容区 20~24，遮罩 32~40。 */
  size?: number;
  /** 无障碍标签，默认「加载中」；传 null 不注入 role / aria。 */
  label?: string | null;
}

/**
 * 加载指示器（设计系统原语层）：静止的细环 + 一个沿环内轨道匀速绕行的实心点。
 *
 * - 与 `Loader2 + animate-spin` 的区别是**不画进度弧** —— 环只作轨道，动效全在点上；
 *   它只能表达「在动」，无法表达「完成了多少」（语义进度继续用带 `value` 的进度条）；
 * - 颜色走 `currentColor`：按钮内自动继承文字色（含 `text-primary-foreground`），
 *   无需逐处传色；环的透明度已内置，不要在外面再叠 `opacity-*`；
 * - 组件自带方形占位（`shrink-0`），调用方直接替换图标即可，无需再包 `SizedBox` 尺寸。
 *
 * ```tsx
 * <Spinner />                       // 按钮内（12~16）
 * <Spinner size={24} />             // 内容区居中
 * <Spinner size={12} className="mr-1" />  // 与文字并排（沿用原图标间距类）
 * ```
 */
function Spinner({
  size = 16,
  label = "加载中",
  className,
  ...props
}: SpinnerProps) {
  return (
    <svg
      data-slot="spinner"
      width={size}
      height={size}
      viewBox={`0 0 ${VIEW} ${VIEW}`}
      fill="none"
      role={label ? "status" : undefined}
      aria-label={label ?? undefined}
      className={cn("animate-orbit-spin origin-center shrink-0", className)}
      {...props}
    >
      {/* 轨道：低透明度细环，不画进度弧 */}
      <circle
        cx={SPINNER_GEOMETRY.viewBox / 2}
        cy={SPINNER_GEOMETRY.viewBox / 2}
        r={RADIUS}
        stroke="currentColor"
        strokeOpacity={SPINNER_GEOMETRY.trackAlpha}
        strokeWidth={SPINNER_GEOMETRY.strokeWidth}
      />
      {/* 绕行点：12 点方向起、顺时针匀速（整圆旋转，环为均匀描边看不出转动） */}
      <circle
        cx={SPINNER_GEOMETRY.viewBox / 2}
        cy={SPINNER_GEOMETRY.dotCenterY}
        r={SPINNER_GEOMETRY.dotRadius}
        fill="currentColor"
      />
    </svg>
  );
}

export { Spinner };
