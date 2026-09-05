/**
 * 平台检测（运行时）——移植自 qraft src/lib/platform.ts
 *
 * 用于条件渲染自定义标题栏的窗口控制按钮：
 * - Windows / Linux:自绘三按钮（最小化 / 最大化 / 关闭）
 * - macOS:保留原生红绿灯，仅渲染拖拽区域（标题栏左侧留 78px 空位）
 *
 * 检测基于 navigator.userAgent，Tauri WebView 在各平台返回对应 UA。
 * 在 jsdom 测试 / 纯浏览器（Playwright 冒烟 mock IPC）环境中 userAgent
 * 通常为 Windows 或 Linux，走自绘控件路径，由 lib/window.ts 的安全降级
 * 保证调用不报错。
 */

const ua = typeof navigator !== "undefined" ? navigator.userAgent : "";

/** macOS（含 iPhone/iPad，但 Tauri 桌面端仅关注 Mac） */
export const isMac = /Macintosh|iPhone|iPad|iPod/i.test(ua);

/** Windows */
export const isWindows = /Windows/i.test(ua);

/** Linux（排除 Mac，避免旧版 iPad UA 中含 Linux 字样误判） */
export const isLinux = !isMac && !isWindows && /Linux/i.test(ua);

/** 是否使用自绘窗口控制按钮（Windows / Linux）；macOS 用原生红绿灯 */
export const useCustomWindowControls = isWindows || isLinux;

/** 是否有原生窗口材质（Windows Mica / macOS vibrancy）；Linux 走 CSS 回退 */
export const hasNativeMica = isWindows || isMac;

/** 平台 CSS 类名后缀，用于在 <html> 上添加 .platform-{win|mac|linux} */
export const platformClass = isMac
  ? "platform-mac"
  : isWindows
    ? "platform-win"
    : "platform-linux";

/**
 * 在 <html> 根元素添加平台 CSS 类
 *
 * 在 main.tsx 启动时调用一次，使 index.css 的平台规则生效：
 * - .platform-mac .title-bar：左侧留 78px 给原生红绿灯
 * - .platform-linux .title-bar 等：backdrop-filter 模拟窗口材质模糊
 *   （Linux 无原生 Mica/vibrancy，用 CSS 回退避免透明背景露底）
 */
export function applyPlatformClass(): void {
  if (typeof document === "undefined") return;
  document.documentElement.classList.add(platformClass);
}
