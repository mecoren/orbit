/**
 * use-todo-reminder-listener — 提醒兜底通道（03 文档 §五）
 *
 * 监听 Rust 轮询守护 emit 的 "todo_reminder:due"，以 sonner warning
 * toast 展示（duration 10s）；系统通知失败时此通道保证用户必达。
 */
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

interface ReminderDuePayload {
  id: number;
  task_id: number;
  title: string;
  remind_at: number;
}

export function useTodoReminderListener() {
  const qc = useQueryClient();
  useEffect(() => {
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
