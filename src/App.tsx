import { useEffect, useState } from "react";
import { RouterProvider } from "react-router";

import { router } from "@/router";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { UnlockPage } from "@/pages/unlock-page";
import { SyncIndicator } from "@/components/layout/sync-indicator";
import { useDbInvalidation, useSyncInvalidation } from "@/lib/events";
import { isMobilePlatform } from "@/lib/platform";
import { useTodoReminderListener } from "@/hooks/use-todo-reminder-listener";
import { useStartupSync } from "@/hooks/use-startup-sync";
import {
  dbInitEncrypted,
  dbInitPlaintext,
  dbSetDeviceId,
  masterAuthHas,
} from "@/lib/tauri";

/**
 * App — 根组件：启动门控（03 文档 §四 数据库打开流程）。
 *
 * checking → masterAuthHas()
 *   ├─ false → dbInitPlaintext() → ready（免密模式）
 *   └─ true  → unlock → masterAuthUnlock(pw) → dbInitEncrypted(hex) → ready
 *
 * DB 就绪后写入进程级 device_id（generic_repo 写操作自动填充依赖此值）。
 */
type BootState = "checking" | "unlock" | "ready";

async function ensureDeviceId() {
  const key = "orbit_device_id";
  let id = localStorage.getItem(key);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(key, id);
  }
  await dbSetDeviceId(id).catch(() => {});
}

/** 主界面壳：挂载 db-change / sync-finished 全局失效（须在 DB 就绪后渲染） */
function ReadyShell() {
  useDbInvalidation();
  useSyncInvalidation();
  useTodoReminderListener();
  // M3：静默恢复同步会话 + 启动时一次 pull_then_push（未配置/未解锁自动跳过）
  useStartupSync();

  return (
    <TooltipProvider>
      <RouterProvider router={router} />
      {/* sonner：top-right（04 文档 §六 Toast 规格）；移动端贴底居中（05 §五）。
          不开 richColors：对齐 shadcn 示例观感——popover 卡片底 + 彩色类型图标 */}
      <Toaster position={isMobilePlatform() ? "bottom-center" : "top-right"} />
      {/* M3：后台自动同步悬浮指示器（仅响应 origin=background） */}
      <SyncIndicator />
    </TooltipProvider>
  );
}

export default function App() {
  const [boot, setBoot] = useState<BootState>("checking");
  const [bootError, setBootError] = useState<string | null>(null);

  // M4：平台标记注入（index.css 移动 token 段按 html[data-platform] 生效）
  useEffect(() => {
    document.documentElement.dataset.platform = isMobilePlatform() ? "mobile" : "desktop";
  }, []);

  useEffect(() => {
    (async () => {
      try {
        if (await masterAuthHas()) {
          setBoot("unlock");
        } else {
          await dbInitPlaintext();
          await ensureDeviceId();
          setBoot("ready");
        }
      } catch (err) {
        setBootError(err instanceof Error ? err.message : String(err));
      }
    })();
  }, []);

  const handleUnlocked = async (dbKeyHex: string) => {
    await dbInitEncrypted(dbKeyHex);
    await ensureDeviceId();
    setBoot("ready");
  };

  if (boot === "checking") {
    return (
      <div className="flex h-screen items-center justify-center bg-background">
        {bootError ? (
          <p className="text-sm text-destructive">{bootError}</p>
        ) : (
          <EqualizerLoader />
        )}
      </div>
    );
  }

  if (boot === "unlock") {
    return <UnlockPage onUnlocked={handleUnlocked} />;
  }

  return <ReadyShell />;
}
