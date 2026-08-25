import { useEffect, useState } from "react";

/**
 * 响应式媒体查询 hook
 *
 * 监听 `window.matchMedia(query)` 的状态变化，自动同步到 React state。
 *
 * @param query CSS media query 字符串，例如 `"(min-width: 1024px)"`
 * @returns 当前是否匹配
 *
 * @example
 * ```tsx
 * const isDesktop = useMediaQuery("(min-width: 1024px)");
 * if (isDesktop) return <DesktopLayout />;
 * return <MobileLayout />;
 * ```
 *
 * 实现说明：
 * - 初始值同步读取 `matchMedia(query).matches`，避免首帧闪烁
 * - useEffect 中订阅 `change` 事件，组件卸载时自动清理
 * - query 变化时重新订阅
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState<boolean>(() => {
    if (typeof window === "undefined") return false;
    return window.matchMedia(query).matches;
  });

  useEffect(() => {
    if (typeof window === "undefined") return;

    const mql = window.matchMedia(query);
    // 同步当前值（query 变化后可能不同步）
    setMatches(mql.matches);

    const handler = (e: MediaQueryListEvent) => setMatches(e.matches);
    mql.addEventListener("change", handler);
    return () => mql.removeEventListener("change", handler);
  }, [query]);

  return matches;
}
