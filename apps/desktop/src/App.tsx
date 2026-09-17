import { useEffect, useState } from "react";
import { RouterProvider } from "react-router";

import { router } from "@/router";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { UnlockPage } from "@/pages/unlock-page";
import { useDbInvalidation, useSyncInvalidation } from "@/lib/events";
import { useTodoReminderListener } from "@/hooks/use-todo-reminder-listener";
import { useStartupSync } from "@/hooks/use-startup-sync";
import { useExitSyncMask } from "@/hooks/use-exit-sync";
import { UndoStackProvider } from "@/hooks/use-undo-stack";
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
  // 进入应用强制同步（静默恢复会话 + 忽略自动同步开关，未配置/未解锁自动跳过）
  useStartupSync();
  // 退出同步遮罩：托盘退出时 Rust 侧先 emit sync-exit-start，再阻塞同步
  const exiting = useExitSyncMask();

  return (
    <TooltipProvider>
      {/* A5：通用撤销栈（Ctrl+Z）——在 Router 内外层皆可，此处包住全部页面 */}
      <UndoStackProvider>
        <RouterProvider router={router} />
      </UndoStackProvider>
      {/* 退出同步遮罩：进程即将结束，展示进度并阻止用户继续操作 */}
      {exiting ? (
        <div className="fixed inset-0 z-[100] flex flex-col items-center justify-center gap-3 bg-background/80 backdrop-blur-sm">
          <EqualizerLoader />
          <p className="text-sm text-muted-foreground">正在同步云端数据…</p>
        </div>
      ) : null}
      {/* sonner：top-right（04 文档 §六 Toast 规格）。
          不开 richColors：对齐 shadcn 示例观感——popover 卡片底 + 彩色类型图标 */}
      <Toaster position="top-right" />
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
