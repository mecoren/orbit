import { useMediaQuery } from "./use-media-query";

/**
 * Tailwind v4 默认断点（px）
 *
 * 与 index.css 中的 `@theme` 默认断点一致，避免引入自定义断点
 * 导致与现有 Tailwind 类不兼容。
 */
export const BREAKPOINTS = {
  sm: 640,
  md: 768,
  lg: 1024,
  xl: 1280,
  "2xl": 1536,
} as const;

export type Breakpoint = keyof typeof BREAKPOINTS;

/**
 * 当前窗口所属断点
 *
 * 从大到小检查，返回第一个匹配 `min-width` 的断点。
 * 例如窗口宽度 1100px → 返回 "lg"（满足 lg=1024 但不满足 xl=1280）。
 *
 * @returns 当前断点标识，"sm" 表示不满足任何 `min-width` 断点
 *
 * @example
 * ```tsx
 * const bp = useBreakpoint();
 * if (bp === "sm" || bp === "md") {
 *   // 窄屏逻辑
 * }
 * ```
 *
 * 实现说明：
 * - 4 个 `useMediaQuery` 并行订阅（每个断点一个），无需手动管理监听器
 * - 返回值随窗口宽度实时更新
 */
export function useBreakpoint(): Breakpoint {
  const is2xl = useMediaQuery(`(min-width: ${BREAKPOINTS["2xl"]}px)`);
  const isXl = useMediaQuery(`(min-width: ${BREAKPOINTS.xl}px)`);
  const isLg = useMediaQuery(`(min-width: ${BREAKPOINTS.lg}px)`);
  const isMd = useMediaQuery(`(min-width: ${BREAKPOINTS.md}px)`);

  if (is2xl) return "2xl";
  if (isXl) return "xl";
  if (isLg) return "lg";
  if (isMd) return "md";
  return "sm";
}

/**
 * 是否为窄屏（< md=768px）
 *
 * 用于判断是否应渲染移动端布局（如全屏 Sheet 而非 Dialog）。
 *
 * @example
 * ```tsx
 * const isMobile = useIsMobile();
 * return isMobile ? <FullScreenSheet /> : <Dialog />;
 * ```
 */
export function useIsMobile(): boolean {
  return useMediaQuery(`(max-width: ${BREAKPOINTS.md - 1}px)`);
}

/**
 * 是否为窄屏（< lg=1024px）
 *
 * 用于判断是否应折叠 Sidebar。设计文档要求 <1024 自动折叠。
 */
export function useIsNarrow(): boolean {
  return useMediaQuery(`(max-width: ${BREAKPOINTS.lg - 1}px)`);
}
