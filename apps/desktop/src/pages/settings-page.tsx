/**
 * 设置页 —— 左导航 + 右内容布局（对齐 wait-home SettingsPage）
 *
 * 左侧 w-48 导航（安全/同步/主题），右侧 max-w-2xl 内容区按分类渲染分区组件。
 */
import { useState } from "react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  settingsCategories,
  type SettingsCategoryKey,
} from "@/components/settings/categories";
import { GeneralSection } from "@/components/settings/general-section";
import { SecuritySection } from "@/components/settings/security-section";
import { SyncSection } from "@/components/settings/sync-section";
import { SyncConflictSection } from "@/components/settings/sync-conflict-section";
import { ThemeSection } from "@/components/settings/theme-section";
import { TodoSection } from "@/components/settings/todo-section";
import { ShortcutsSection } from "@/components/settings/shortcuts-section";
import { TemplatesSection } from "@/components/settings/templates-section";
import { NotificationHistorySection } from "@/components/settings/notification-history-section";
import { UpdaterSection } from "@/components/settings/updater-section";

export function SettingsPage() {
  const [active, setActive] = useState<SettingsCategoryKey>("security");

  return (
    <div className="flex h-full flex-col">
      {/* 页头 */}
      <header className="border-b px-6 py-4">
        <h1 className="text-lg font-semibold text-foreground">设置</h1>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* 左导航 */}
        <nav className="w-48 shrink-0 space-y-1 overflow-y-auto border-r p-3">
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
              {cat.label}
            </Button>
          ))}
        </nav>

        {/* 右内容 */}
        <div className="min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto max-w-2xl p-6">
            {active === "general" && <GeneralSection />}
            {active === "security" && <SecuritySection />}
            {active === "sync" && <SyncSection />}
            {active === "conflicts" && <SyncConflictSection />}
            {active === "theme" && <ThemeSection />}
            {active === "todo" && <TodoSection />}
            {active === "shortcuts" && <ShortcutsSection />}
            {active === "templates" && <TemplatesSection />}
            {active === "notifications" && <NotificationHistorySection />}
            {active === "updater" && <UpdaterSection />}
          </div>
        </div>
      </div>
    </div>
  );
}
