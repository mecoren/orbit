import { memo, useEffect, useRef, type ReactNode, type RefObject } from "react";
import { MaterialIcon } from "./material-icon";
import { GlassHighlight } from "./glass-highlight";
import { pickGlassStrategy, type GlassStrategy } from "./glass-strategy";

interface LiquidGlassTitleBarProps {
  title: string;
  actions?: ReactNode;
  onBack?: () => void;
  /**
   * 联动的滚动容器；offset>0 时显示渐变模糊层。
   * 契约：ref.current 必须与标题栏在同一次 commit 内完成赋值（同屏条件渲染），
   * 否则 effect 空跑且不重连，模糊层不启用。
   */
  scrollRef?: RefObject<HTMLElement | null>;
}

/** mask 能力探测运行期不变，提为模块常量（避免每次渲染重算 + memo prop 结构性稳定） */
const SUPPORTS_MASK =
  typeof CSS !== "undefined" &&
  (CSS.supports("-webkit-mask-image", "linear-gradient(black, transparent)") ||
    CSS.supports("mask-image", "linear-gradient(black, transparent)"));

/**
 * 滚动淡入模糊层（05 §三性能纪律）：独立 memo 组件（对应蓝本 RepaintBoundary）。
 * mask 策略 = blur(20px)+tint+-webkit-mask-image 垂直渐变；
 * segmented 策略（WKWebView 无 mask 支持）降级为 blur(8px)+线性渐变背景。
 * 不持有任何 state——opacity/display 由父级 useEffect 经 ref 直写，禁止 setState。
 */
const ScrollFadeBlur = memo(function ScrollFadeBlur({ strategy }: { strategy: GlassStrategy }) {
  return (
    <div
      data-scroll-fade
      className="pointer-events-none absolute inset-0 opacity-0"
      style={
        strategy === "mask"
          ? {
              backdropFilter: "blur(20px)",
              WebkitBackdropFilter: "blur(20px)",
              background: "var(--m-glass-tint)",
              WebkitMaskImage: "linear-gradient(to bottom, black 30%, transparent)",
              maskImage: "linear-gradient(to bottom, black 30%, transparent)",
            }
          : {
              backdropFilter: "blur(8px)",
              WebkitBackdropFilter: "blur(8px)",
              background: "linear-gradient(to bottom, var(--m-glass-tint), transparent)",
            }
      }
    />
  );
});

/**
 * 液态玻璃标题栏（05 §三/§4.1）：
 * - sticky top-0 z-40 + 安全区顶部 padding（m-safe-top）；单行高度 TITLE_BAR_ROW1=56（h-14）；
 * - 玻璃三件套：常驻 tint 底层（无 blur）+ ScrollFadeBlur 强模糊层 + GlassHighlight 底缘高光线；
 * - 滚动 offset=0 时模糊层 display:none + opacity:0（ref 直写 + passive 监听，整页零重渲）；
 * - showSecondRow 双行模式 MVP 固定不实现（05 §4.1 仅单行）。
 */
export function LiquidGlassTitleBar({ title, actions, onBack, scrollRef }: LiquidGlassTitleBarProps) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const strategy = pickGlassStrategy(SUPPORTS_MASK);

  useEffect(() => {
    const el = scrollRef?.current;
    const wrap = wrapRef.current;
    if (!el || !wrap) return;
    const fade = wrap.querySelector<HTMLElement>("[data-scroll-fade]");
    const apply = () => {
      if (!fade) return;
      const scrolled = el.scrollTop > 0;
      fade.style.opacity = scrolled ? "1" : "0";
      // offset=0 必须移除模糊层（05 §三性能纪律：display:none 使 backdrop-filter 完全失效）
      fade.style.display = scrolled ? "" : "none";
    };
    el.addEventListener("scroll", apply, { passive: true });
    apply();
    return () => el.removeEventListener("scroll", apply);
  }, [scrollRef]);

  return (
    <div ref={wrapRef} className="sticky top-0 z-40 m-safe-top">
      <div className="relative h-14">
        {/* 基础层：常驻 tint（无 blur，保证 offset=0 时画面干净） */}
        <div className="absolute inset-0" style={{ background: "var(--m-glass-tint)" }} />
        {/* 滚动后才出现的强模糊层 */}
        <ScrollFadeBlur strategy={strategy} />
        <GlassHighlight position="bottom" />
        <div className="relative z-10 flex h-full items-center gap-1 px-1">
          {onBack && (
            <button onClick={onBack} className="grid h-12 w-12 shrink-0 place-items-center text-[var(--m-text)]" aria-label="返回">
              <MaterialIcon name="arrow_back_rounded" size={24} />
            </button>
          )}
          <h1 className="flex-1 truncate px-2 text-[22px] font-medium text-[var(--m-text)]">{title}</h1>
          <div className="flex items-center pr-1">{actions}</div>
        </div>
      </div>
    </div>
  );
}
