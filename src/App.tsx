import { useEffect, useState } from "react";
import { RouterProvider } from "react-router";
import { Toaster } from "sonner";

import { router } from "@/router";
import { TooltipProvider } from "@/components/ui/tooltip";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { UnlockPage } from "@/pages/unlock-page";
import { SyncIndicator } from "@/components/layout/sync-indicator";
import { useDbInvalidation } from "@/lib/events";
import { useTodoReminderListener } from "@/hooks/use-todo-reminder-listener";
import {
  dbInitEncrypted,
  dbInitPlaintext,
  dbSetDeviceId,
  masterAuthHas,
  syncCryptoRestoreSession,
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

/** 主界面壳：挂载 db-change 全局失效（须在 DB 就绪后渲染） */
function ReadyShell() {
  useDbInvalidation();
  useTodoReminderListener();

  // M3：DB 就绪后尝试用钥匙串缓存的同步密码静默恢复会话（失败静默）
  useEffect(() => {
    void syncCryptoRestoreSession().catch(() => {});
  }, []);

  return (
    <TooltipProvider>
      <RouterProvider router={router} />
      {/* sonner：richColors + top-right（04 文档 §六 Toast 规格） */}
      <Toaster richColors position="top-right" />
      {/* M3：后台自动同步悬浮指示器（仅响应 origin=background） */}
      <SyncIndicator />
    </TooltipProvider>
  );
}

export default function App() {
  const [boot, setBoot] = useState<BootState>("checking");
  const [bootError, setBootError] = useState<string | null>(null);

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
