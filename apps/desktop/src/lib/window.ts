/**
 * 窗口控制封装（移植自 qraft src/lib/window.ts）
 *
 * 基于 @tauri-apps/api/window 的 getCurrentWindow()，提供：
 * - minimize / toggleMaximize / close 命令式调用
 * - useMaximized 钩子：订阅 resize 事件，返回当前是否最大化，
 *   供窗口控制按钮切换图标（最大化 ↔ 还原）
 *
 * 设计说明：
 * - 不引入新的 Rust IPC 命令，直接调用 Tauri 内置窗口 API
 * - getCurrentWindow() 在函数内调用（非模块顶层），避免在非 Tauri
 *   环境（测试/浏览器 mock IPC）模块加载时报错
 */

import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";

/** 最小化当前窗口 */
export async function minimizeWindow(): Promise<void> {
  await getCurrentWindow().minimize();
}

/** 切换最大化/还原当前窗口 */
export async function toggleMaximizeWindow(): Promise<void> {
  await getCurrentWindow().toggleMaximize();
}

/** 关闭当前窗口 */
export async function closeMainWindow(): Promise<void> {
  await getCurrentWindow().close();
}

/**
 * 订阅窗口最大化状态变化
 *
 * 监听 Tauri 的 onResized 事件（最大化/还原都会触发），事件后查询
 * isMaximized() 更新状态。非 Tauri 环境（测试/浏览器 mock）安全降级：
 * 返回恒 false，不抛错。
 */
export function useMaximized(): boolean {
  const [maximized, setMaximized] = useState(false);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;

    const init = async () => {
      try {
        const win = getCurrentWindow();
        // 初始查询当前最大化状态
        const initial = await win.isMaximized();
        if (cancelled) return;
        setMaximized(initial);
        // 订阅 resize 事件（最大化/还原都会触发）
        unlisten = await win.onResized(async () => {
          try {
            const m = await win.isMaximized();
            if (!cancelled) setMaximized(m);
          } catch {
            // 忽略：窗口可能已销毁
          }
        });
      } catch {
        // 非 Tauri 环境（测试/浏览器 mock），保持默认 false
      }
    };

    void init();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  return maximized;
}
