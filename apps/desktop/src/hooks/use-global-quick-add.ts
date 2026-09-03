/**
 * useGlobalQuickAdd — 全局快速捕捉热键（07 报告 #16）
 *
 * 注册系统级热键 Alt+Shift+O：任意应用前台时按下 →
 * 显示并聚焦 Orbit 主窗 + 触发快速新建意图（QuickAddBar 聚焦输入）。
 *
 * - 热键在壳层 AppShell 挂载时注册一次，卸载时注销；
 * - 注册失败（热键被占用/权限拒绝）静默降级：托盘菜单仍可快速新建；
 * - 窗口显示逻辑用 Tauri window API（getCurrentWindow().show() + setFocus），
 *   不依赖 React 状态——热键回调运行时窗口可能处于隐藏驻留态。
 */
import { useEffect } from "react";

import { useAppStore } from "@/stores/app-store";

/** 全局捕捉热键（Alt+Shift+O：避开常用应用热键与输入法） */
const QUICK_ADD_SHORTCUT = "Alt+Shift+O";

export function useGlobalQuickAdd() {
  const bumpQuickAddIntent = useAppStore((s) => s.bumpQuickAddIntent);

  useEffect(() => {
    let unregister: (() => void) | null = null;
    let disposed = false;

    void (async () => {
      try {
        const plugin = await import("@tauri-apps/plugin-global-shortcut");
        await plugin.register(QUICK_ADD_SHORTCUT, async () => {
          // 唤起主窗（隐藏驻留态 → 显示 + 聚焦），再触发快速新建
          try {
            const { getCurrentWindow } = await import("@tauri-apps/api/window");
            const win = getCurrentWindow();
            await win.show();
            await win.unminimize();
            await win.setFocus();
          } catch {
            // 窗口 API 不可用时仅触发意图（非 Tauri 环境不会走到这里）
          }
          bumpQuickAddIntent();
        });
        unregister = () => void plugin.unregister(QUICK_ADD_SHORTCUT);
        if (disposed) {
          // 竞态兜底：组件在注册完成前已卸载
          unregister();
          unregister = null;
        }
      } catch (err) {
        // 热键被占用等场景：静默降级（托盘菜单快速新建仍可用）
        console.warn("[global-shortcut] 快速捕捉热键注册失败:", err);
      }
    })();

    return () => {
      disposed = true;
      unregister?.();
    };
  }, [bumpQuickAddIntent]);
}
