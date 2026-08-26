/**
 * use-todo-reminder-listener — 提醒兜底通道（03 文档 §五）
 *
 * 监听 Rust 轮询守护 emit 的 "todo_reminder:due"，以 sonner warning
 * toast 展示（duration 10s）；系统通知失败时此通道保证用户必达。
 *
 * 桌面端无运行时通知权限概念（移动端已拆分为 Flutter 应用，
 * 其权限流程由 apps/mobile 自行实现）。
 */
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  todoReminderCreate,
  todoReminderDelete,
  todoTaskGet,
} from "@/lib/tauri";
import { nextRepeatAt } from "@/features/todo/shared/repeat";

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
      // 重复提醒：任务带 repeat 规则时删旧建新排下一次（失败不影响本次提醒）
      void (async () => {
        try {
          const task = await todoTaskGet(r.task_id);
          if (task.done) return; // P1#10：真引擎接管后，已完成实例不再续排提醒
          const next = nextRepeatAt(r.remind_at, task.repeat_mode, task.repeat_after, Date.now());
          if (next != null) {
            await todoReminderDelete(r.id);
            await todoReminderCreate({ task_id: r.task_id, remind_at: next });
            void qc.invalidateQueries({ queryKey: ["todo-task-detail", r.task_id] });
          }
        } catch {
          /* 重复调度失败静默 */
        }
      })();
      // 提醒触发不改变数据，无需失效查询
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}
