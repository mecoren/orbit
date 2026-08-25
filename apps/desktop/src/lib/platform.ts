/**
 * 平台探测：同一份前端产物跑在桌面 WebView 与移动 WebView 上，
 * 以 UA 判定分叉（Tauri Android WebView UA 含 Android；iOS WKWebView 含 iPhone/iPad）。
 */
export function isMobileUA(ua: string): boolean {
  return /Android|iPhone|iPad|iPod/i.test(ua);
}

export function isMobilePlatform(): boolean {
  return typeof navigator !== "undefined" && isMobileUA(navigator.userAgent);
}

/** Android 手势条兜底高度（05 §五：env(safe-area-inset-bottom) 为 0 时兜底 48px） */
export const MOBILE_GESTURE_INSET = 48;
