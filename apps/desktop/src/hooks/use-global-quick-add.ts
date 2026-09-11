/**
 * useGlobalQuickAdd — 全局快速捕捉热键（07 报告 #16）
 *
 * 注册系统级热键 Alt+Shift+O：任意应用前台时按下 →
 * 显示并聚焦 Orbit 主窗 + 触发快速新建意图（QuickAddBar 聚焦输入）。
 *
 * - 热键在壳层 AppShell 挂载时注册一次，卸载时注销；
 * - 注册失败（热键被占用/权限拒绝）静默降级：托盘菜单仍可快速新建；
 * - 唤起走 show_main_window_cmd 命令而非前端窗口 API：驻留超时回收
 *   会销毁主窗，getCurrentWindow() 在窗口销毁后无兜底（销毁期热键
 *   由壳层 Rust 侧 global_hotkey_fallback 兜底，重建后此 hook 重新注册）。
 */
import { useEffect } from "react";

import { showMainWindow } from "@/lib/tauri";
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
          // 唤起主窗（隐藏驻留 → 显示聚焦；被回收 → 重建），再触发快速新建
          await showMainWindow().catch(() => {});
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
