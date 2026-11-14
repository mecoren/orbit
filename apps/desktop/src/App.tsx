import { useEffect, useState } from "react";
import { RouterProvider } from "react-router";

import { router } from "@/router";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { Spinner } from "@/components/ui/spinner";
import { UnlockPage } from "@/pages/unlock-page";
import { useDbInvalidation, useSyncInvalidation } from "@/lib/events";
import { useTodoReminderListener } from "@/hooks/use-todo-reminder-listener";
import { useStartupSync } from "@/hooks/use-startup-sync";
import { useExitSyncMask } from "@/hooks/use-exit-sync";
import { UndoStackProvider } from "@/hooks/use-undo-stack";
import { ErrorBoundary } from "@/components/error-boundary";
import { markFirstScreenReady } from "@/lib/perf-marker";
import {
  dbGetDeviceId,
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
 *   └─ true  → unlock → masterAuthUnlock(pw)（key 留 Rust 侧）→ dbInitEncrypted() → ready
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
  // device_id 是 generic_repo 写操作自动填充 device_id 列、以及 Lamport
  // 版本号推进的前置条件（context.rs：未设置时调用方回退空串并跳过版本号
  // 写入）。此前 `.catch(() => {})` 把失败彻底吞掉：本地改动照常落库、
  // 界面照常可用，但云同步的 DeviceCheckpoint / 真并发冲突判定静默失真。
  try {
    await dbSetDeviceId(id);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // OnceCell 已写入属于热重载 / 重复启动，幂等且无副作用，放行；
    // 其余失败一律上抛，由启动门控显示成可见错误而非静默降级。
    if (!msg.includes("already set")) {
      throw new Error(
        `设备标识写入失败（${msg}）：本地改动将无法正确参与云同步，请重启应用`,
      );
    }
  }
  // 回读断言：确认 Rust 侧 OnceCell 真的持有非空 id，不能只信一次 Ok
  const actual = await dbGetDeviceId();
  if (!actual) {
    throw new Error("设备标识未生效：本地改动将无法正确参与云同步，请重启应用");
  }
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
          <Spinner size={32} />
          <p className="text-sm text-muted-foreground">正在同步云端数据…</p>
        </div>
      ) : null}
      {/* sonner：top-right（04 文档 §六 Toast 规格）。
          不开 richColors：对齐 shadcn 示例观感——popover 卡片底 + 彩色类型图标 */}
      <Toaster position="top-right" />
    </TooltipProvider>
  );
}

/** 外层崩溃页（D14）：壳本身起不来时只给重载级恢复 + 托盘退出提示 */
function BootCrashFallback({ onRetry }: { onRetry: () => void }) {
  return (
    <div className="flex h-screen flex-col items-center justify-center gap-3 bg-background p-8 text-center">
      <p className="text-sm font-medium">应用壳遇到了问题</p>
      <p className="max-w-sm text-xs text-muted-foreground">
        可重载恢复；若窗口已隐藏到托盘，可从托盘菜单退出后重开。
      </p>
      <div className="flex gap-2">
        <button
          type="button"
          className="rounded-md border px-3 py-1.5 text-sm hover:bg-accent"
          onClick={onRetry}
        >
          重试
        </button>
        <button
          type="button"
          className="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground hover:bg-primary/90"
          onClick={() => window.location.reload()}
        >
          重载应用
        </button>
      </div>
    </div>
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

  // F80：key 留在 Rust 侧（PendingDbKey），解锁成功后无需传参
  const handleUnlocked = async () => {
    try {
      await dbInitEncrypted();
      await ensureDeviceId();
      setBoot("ready");
    } catch (err) {
      // 解锁页没有 Toaster；回到启动门控页用 bootError 呈现，避免变成
      // 未处理的 Promise rejection（用户只看到解锁页卡住）。
      setBootError(err instanceof Error ? err.message : String(err));
      setBoot("checking");
    }
  };

  // 冷启动度量（docs/09 §六）：boot 门控落到持续画面（解锁页/主界面）后
  // 上报「首屏就绪」时刻；ORBIT_PERF_MARKER 未设置时 Rust 侧 no-op
  useEffect(() => {
    if (boot === "checking") return;
    markFirstScreenReady();
  }, [boot]);

  if (boot === "checking") {
    return (
      <div className="flex h-screen items-center justify-center bg-background p-8">
        {bootError ? (
          // 启动门控失败后 useEffect([]) 不会重跑：必须给一个可操作入口，
          // 否则用户只看到一行错误文字却无法重试（device_id 写入失败即此类）。
          <div className="flex max-w-md flex-col items-center gap-3 text-center">
            <p className="text-sm text-destructive">{bootError}</p>
            <button
              type="button"
              className="rounded-md border px-3 py-1.5 text-sm hover:bg-accent"
              onClick={() => window.location.reload()}
            >
              重启应用并重试
            </button>
          </div>
        ) : (
          <Spinner size={32} />
        )}
      </div>
    );
  }

  if (boot === "unlock") {
    return <UnlockPage onUnlocked={handleUnlocked} />;
  }

  // 外层边界（D14）：ReadyShell（含路由/Toaster/全局失效）整体兜底
  return (
    <ErrorBoundary fallback={(_error, retry) => <BootCrashFallback onRetry={retry} />}>
      <ReadyShell />
    </ErrorBoundary>
  );
}
