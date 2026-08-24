import type { ReactNode } from "react";
import { GlassHighlight } from "./glass-highlight";

interface GlassFabProps {
  onClick: () => void;
  ariaLabel: string;
  /** 内容强调色；默认 #4E8CFF = themeAccent MVP 固定值（05 §2.1） */
  accentColor?: string;
  children?: ReactNode;
}

/**
 * GlassFab 悬浮按钮（05 §三/§五 玻璃规格）：56px 圆、blur(18px)、tint 底、
 * 内侧底部高光线（玻璃三件套之三）、active:scale-95 按压反馈。
 */
export function GlassFab({ onClick, ariaLabel, accentColor = "#4E8CFF", children }: GlassFabProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel}
      className="relative grid h-14 w-14 place-items-center rounded-full shadow-lg active:scale-95 transition-transform duration-150"
      style={{
        backdropFilter: "blur(18px)",
        WebkitBackdropFilter: "blur(18px)",
        background: "var(--m-glass-tint)",
        border: "1px solid rgba(255,255,255,0.08)",
      }}
    >
      <GlassHighlight position="inner-bottom" />
      <span className="relative z-10" style={{ color: accentColor }}>
        {children}
      </span>
    </button>
  );
}
