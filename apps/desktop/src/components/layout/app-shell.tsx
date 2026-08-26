/**
 * AppShell — 应用壳布局
 *
 * 结构（04 文档 §二 ⚖ 修订）：TitleBar + main + CommandPalette。
 * 壳级 Sidebar 已移除：MVP 单模块下与待办页 ProjectSidebar 形成双侧栏冗余，
 * 设置 / 关于入口移至 TitleBar 右上图标区（命令面板保留跳转）。
 * - Mica 云母材质：mount 时启用，跟随主题模式切换色调
 * - 路由淡入：key 取 pathname 首段，仅跨模块时重放过渡动画
 */
import { Outlet, useLocation } from "react-router";

import { TitleBar } from "@/components/layout/title-bar";
import { CommandPalette } from "@/components/layout/command-palette";
import { GlobalSearchDialog } from "@/components/layout/global-search-dialog";
import { useAppStore } from "@/stores/app-store";
import { useMicaEffect } from "@/hooks/use-mica-effect";

export function AppShell() {
  const commandOpen = useAppStore((s) => s.commandOpen);
  const setCommandOpen = useAppStore((s) => s.setCommandOpen);
  const searchOpen = useAppStore((s) => s.searchOpen);
  const setSearchOpen = useAppStore((s) => s.setSearchOpen);
  useMicaEffect();

  const location = useLocation();

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <TitleBar />
      <main className="flex-1 overflow-y-auto bg-background/60 dark:bg-background/85">
        {/* key 用路由首段：同模块内导航不重挂载，跨模块才重放过渡 */}
        <div
          key={location.pathname.split("/")[1] ?? ""}
          className="page-transition h-full"
        >
          <Outlet />
        </div>
      </main>
      {/* 全局命令面板：提升到 AppShell 层级，避免嵌套在 TitleBar 定位容器中 */}
      <CommandPalette open={commandOpen} onOpenChange={setCommandOpen} />
      {/* 全局搜索（Ctrl+K，07 §五-P1#9）：与命令面板平级的壳层入口 */}
      <GlobalSearchDialog open={searchOpen} onOpenChange={setSearchOpen} />
    </div>
  );
}
