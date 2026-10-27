/**
 * 设置页 —— 左导航 + 右内容布局（对齐 wait-home SettingsPage）
 *
 * 左侧 w-48 导航（安全/同步/主题），右侧 max-w-2xl 内容区按分类渲染分区组件。
 */
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { cn } from "@/lib/utils";
import { syncConflictCount } from "@/lib/tauri";
import { Button } from "@/components/ui/button";
import {
  settingsCategories,
  type SettingsCategoryKey,
} from "@/components/settings/categories";
import { CalendarSection } from "@/components/settings/calendar-section";
import { DiagnosticsSection } from "@/components/settings/diagnostics-section";
import { GeneralSection } from "@/components/settings/general-section";
import { SecuritySection } from "@/components/settings/security-section";
import { SyncSection } from "@/components/settings/sync-section";
import { SyncConflictSection } from "@/components/settings/sync-conflict-section";
import { ThemeSection } from "@/components/settings/theme-section";
import { TodoSection } from "@/components/settings/todo-section";
import { ShortcutsSection } from "@/components/settings/shortcuts-section";
import { TemplatesSection } from "@/components/settings/templates-section";
import { NotificationHistorySection } from "@/components/settings/notification-history-section";
import { TestDataSection } from "@/components/settings/test-data-section";
import { UpdaterSection } from "@/components/settings/updater-section";

export function SettingsPage() {
  const [active, setActive] = useState<SettingsCategoryKey>("security");
  // 未处理冲突角标（#107）：冲突页此前只能点进去才发现有积压。
  // 与冲突列表同前缀 ["sync_conflicts"]，db-change 失效链一并刷新。
  const { data: conflictCount = 0 } = useQuery({
    queryKey: ["sync_conflicts", "count"],
    queryFn: () => syncConflictCount("unresolved"),
    staleTime: 60_000,
  });

  return (
    <div className="flex h-full flex-col">
      {/* 页头 */}
      <header className="border-b px-6 py-4">
        <h1 className="text-lg font-semibold text-foreground">设置</h1>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* 左导航 */}
        {/* 窄窗（900–1023）收窄导航，把宽度让给内容区；宽窗恢复 12rem */}
        <nav className="w-40 shrink-0 space-y-1 overflow-y-auto border-r p-2 xl:w-48 xl:p-3">
          {settingsCategories.map((cat) => (
            <Button
              key={cat.key}
              variant="ghost"
              onClick={() => setActive(cat.key)}
              className={cn(
                "flex w-full items-center justify-start gap-2 px-3 py-2",
                active === cat.key
                  ? "bg-accent text-accent-foreground"
                  : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
              )}
            >
              <cat.icon className="size-4" />
              <span className="truncate">{cat.label}</span>
              {cat.key === "conflicts" && conflictCount > 0 ? (
                <span
                  className="ml-auto rounded-full bg-destructive px-1.5 py-0.5 text-[10px] font-medium leading-none text-white tabular-nums"
                  aria-label={`${conflictCount} 条未处理冲突`}
                >
                  {conflictCount > 99 ? "99+" : conflictCount}
                </span>
              ) : null}
            </Button>
          ))}
        </nav>

        {/* 右内容 */}
        <div className="min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto max-w-2xl p-4 xl:p-6">
            {active === "general" && <GeneralSection />}
            {active === "security" && <SecuritySection />}
            {active === "sync" && <SyncSection />}
            {active === "conflicts" && <SyncConflictSection />}
            {active === "theme" && <ThemeSection />}
            {active === "todo" && <TodoSection />}
            {active === "calendar" && <CalendarSection />}
            {active === "shortcuts" && <ShortcutsSection />}
            {active === "templates" && <TemplatesSection />}
            {active === "notifications" && <NotificationHistorySection />}
            {active === "diagnostics" && <DiagnosticsSection />}
            {/* DEV 门禁：release 构建里该分支被常量折叠掉，入口也不渲染 */}
            {import.meta.env.DEV && active === "test-data" && <TestDataSection />}
            {active === "updater" && <UpdaterSection />}
          </div>
        </div>
      </div>
    </div>
  );
}
