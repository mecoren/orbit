import type { CSSProperties } from "react";
import { useFontReady } from "./use-font-ready";

interface MaterialIconProps {
  /** ligature 名，如 search_rounded / chevron_right_rounded */
  name: string;
  size?: number;
  fill?: 0 | 1;
  weight?: 400 | 500 | 600;
  color?: string;
  className?: string;
  style?: CSSProperties;
}

/**
 * Material Symbols Rounded 图标。
 * 兜底行为（05 §2.3）：字体加载失败时渲染同尺寸半透明占位圆点，不破版式。
 */
export function MaterialIcon({ name, size = 22, fill = 0, weight = 400, color, className, style }: MaterialIconProps) {
  const ready = useFontReady();
  if (!ready) {
    return (
      <span
        aria-hidden
        className={className}
        style={{ display: "inline-block", width: size, height: size, borderRadius: "50%", background: "currentColor", color, opacity: 0.25, flexShrink: 0, ...style }}
      />
    );
  }
  return (
    <span
      aria-hidden
      className={`msr ${className ?? ""}`}
      style={{ fontSize: size, width: size, height: size, overflow: "hidden", color, fontVariationSettings: `"FILL" ${fill}, "wght" ${weight}, "GRAD" 0, "opsz" ${size}`, ...style }}
    >
      {name}
    </span>
  );
}
