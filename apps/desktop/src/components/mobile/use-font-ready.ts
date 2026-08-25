import { useEffect, useState } from "react";

let cached: boolean | null = null;

/**
 * Material Symbols 字体就绪探测（ligature 渲染依赖；失败时组件降级为占位圆点）。
 * 结果模块级缓存，多实例共享一次探测；alive 标志防卸载后 setState。
 */
export function useFontReady(): boolean {
  const [ready, setReady] = useState(cached ?? false);
  useEffect(() => {
    if (cached != null) return;
    // 健壮性守卫：老 WebView / 测试环境可能没有 FontFaceSet API
    if (typeof document === "undefined" || !document.fonts?.load) return;
    let alive = true;
    document.fonts
      .load('24px "Material Symbols Rounded"', "search")
      .then(() => document.fonts.check('24px "Material Symbols Rounded"'))
      .then((ok) => {
        cached = ok;
        if (alive) setReady(ok);
      })
      .catch(() => {
        cached = false;
        if (alive) setReady(false);
      });
    return () => {
      alive = false;
    };
  }, []);
  return ready || !!cached;
}
