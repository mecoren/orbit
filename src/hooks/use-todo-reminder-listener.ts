/**
 * use-todo-reminder-listener — 提醒兜底通道（03 文档 §五）
 *
 * 监听 Rust 轮询守护 emit 的 "todo_reminder:due"，以 sonner warning
 * toast 展示（duration 10s）；系统通知失败时此通道保证用户必达。
 *
 * 移动端附加（ADR 0002 · R2 决策）：初始化时探测通知权限，
 * 被拒则 waitToast.destructive 降级提示一次；桌面端无运行时权限
 * 概念，整个探测分支被 isMobilePlatform() 短路，行为与此前一致。
 */
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { isPermissionGranted, requestPermission } from "@tauri-apps/plugin-notification";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { isMobilePlatform } from "@/lib/platform";
import { waitToast } from "@/components/mobile/wait-toast";

interface ReminderDuePayload {
  id: number;
  task_id: number;
  title: string;
  remind_at: number;
}

/** 权限拒绝降级提示每会话至多一次（模块级：StrictMode 双挂载也不重复） */
let permissionFallbackShown = false;

async function ensurePermissionOrFallbackToast(): Promise<void> {
  try {
    let granted = await isPermissionGranted();
    if (!granted) {
      granted = (await requestPermission()) === "granted";
    }
    if (!granted && !permissionFallbackShown) {
      permissionFallbackShown = true;
      waitToast.destructive("通知权限未授予", "提醒将在应用内展示");
    }
  } catch {
    // 探测失败静默：todo_reminder:due 事件兜底通道不受影响
  }
}

export function useTodoReminderListener() {
  const qc = useQueryClient();
  useEffect(() => {
    if (isMobilePlatform()) {
      void ensurePermissionOrFallbackToast();
    }
    const unlistenPromise = listen<ReminderDuePayload>("todo_reminder:due", (event) => {
      const r = event.payload;
      toast.warning(r.title, {
        description: `待办提醒 · ${new Date(r.remind_at).toLocaleString("zh-CN", {
          hour: "2-digit",
          minute: "2-digit",
        })}`,
        duration: 10_000,
      });
      // 提醒触发不改变数据，无需失效查询
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}
