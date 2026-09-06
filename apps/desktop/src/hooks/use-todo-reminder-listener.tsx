/**
 * use-todo-reminder-listener — 提醒兜底通道（03 文档 §五）
 *
 * 监听 Rust 轮询守护 emit 的 "todo_reminder:due"，以自定义 sonner
 * toast 展示（含推迟 10 分钟 / 30 分钟 / 1 小时操作，删旧建新语义见
 * reminder-snooze.ts）；系统通知失败时此通道保证用户必达。
 *
 * 桌面端无运行时通知权限概念（移动端已拆分为 Flutter 应用，
 * 其权限流程由 apps/mobile 自行实现）。
 */
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { nextRepeatAt } from "@/features/todo/shared/repeat";
import { snoozeReminder, remindAtClockLabel } from "@/features/todo/shared/reminder-snooze";
import { ReminderToast } from "@/features/todo/shared/reminder-toast";
import {
  todoReminderCreate,
  todoReminderDelete,
  todoTaskGetDetail,
} from "@/lib/tauri";

interface ReminderDuePayload {
  id: number;
  task_id: number;
  title: string;
  remind_at: number;
}

/** Rust 系统通知推迟完成事件（notify-rust action → 删旧建新后 emit） */
interface ReminderSnoozedPayload {
  reminder_id: number;
  task_id: number;
  remind_at: number;
  title: string;
}

/** reminder.id → in-app toast id（snoozed 事件到达时按源 id 关对应 toast） */
const reminderToastIds = new Map<number, number | string>();

export function useTodoReminderListener() {
  const qc = useQueryClient();
  useEffect(() => {
    // 系统通知（右下角弹窗）点推迟按钮后：Rust 已删旧建新并广播。
    // 前端三件事：按 reminder_id 关闭对应 in-app toast（duration Infinity
    // 常驻，不关会一直挂着，且其引用的提醒行已被删——再点它会建出
    // 平行提醒）+ 弹与站内推迟同款确认 + 失效详情缓存刷新提醒区块
    const unlistenSnoozed = listen<ReminderSnoozedPayload>(
      "todo_reminder:snoozed",
      (event) => {
        const { reminder_id, task_id, remind_at, title } = event.payload;
        const toastId = reminderToastIds.get(reminder_id);
        if (toastId != null) {
          toast.dismiss(toastId);
          reminderToastIds.delete(reminder_id);
        }
        toast.success(`已推迟到 ${remindAtClockLabel(remind_at)}`, {
          description: title,
          duration: 4_000,
        });
        void qc.invalidateQueries({ queryKey: ["todo-task-detail", task_id] });
      },
    );
    const unlistenPromise = listen<ReminderDuePayload>("todo_reminder:due", (event) => {
      const r = event.payload;
      // toast.custom 支持 jsx 内容（sonner 单 action 按钮装不下三个推迟档）
      toast.custom(
        (id) => {
          reminderToastIds.set(r.id, id);
          return (
            <ReminderToast
              title={r.title}
              remindAt={r.remind_at}
              onSnooze={(minutes) =>
                snoozeReminder(r.id, r.task_id, r.remind_at, minutes, qc)
              }
              onDone={() => {
                reminderToastIds.delete(r.id);
                toast.dismiss(id);
              }}
            />
          );
        },
        // 不自动消失：推迟/关闭都由按钮驱动；避免超时关闭后用户失去入口
        { duration: Infinity },
      );
      // 重复提醒：任务带 repeat 规则时删旧建新排下一次（失败不影响本次提醒）。
      // 防雪球守卫：到期行触发续排前若任务已存在其他未来提醒（推迟产物或
      // 用户手排的），说明本行不再是唯一排程——只清理不克隆，避免
      // 「原系列 + 推迟系列」平行滚动；同时续排锚点固定为 r.remind_at
      // 原始系列时间，不受推迟漂移影响。
      void (async () => {
        try {
          const detail = await todoTaskGetDetail(r.task_id);
          const task = detail;
          if (task.done) {
            // P1#10：真引擎接管后，已完成实例不再续排提醒；
            // 顺手清理该僵尸提醒行，避免 24h 窗口内（含重启后）对归档实例再响一次
            try {
              await todoReminderDelete(r.id);
              void qc.invalidateQueries({ queryKey: ["todo-task-detail", r.task_id] });
            } catch {
              /* 清理失败静默 */
            }
            return;
          }
          const next = nextRepeatAt(r.remind_at, task.repeat_mode, task.repeat_after, Date.now());
          if (next == null) return;
          const hasOtherFuture = detail.reminders.some(
            (m) => m.id !== r.id && !m.is_deleted && m.remind_at > Date.now(),
          );
          // 删除单独容错：行不存在（用户刚在 toast 上推迟过、或并发清理）
          // 时抛错不应中断续排——删旧失败仍建新，宁可多提醒不漏提醒
          try {
            await todoReminderDelete(r.id);
          } catch {
            /* 行已消失：跳过删除 */
          }
          if (!hasOtherFuture) {
            await todoReminderCreate({ task_id: r.task_id, remind_at: next });
          }
          void qc.invalidateQueries({ queryKey: ["todo-task-detail", r.task_id] });
        } catch {
          /* 重复调度失败静默 */
        }
      })();
      // 提醒触发不改变数据，无需失效查询
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
      unlistenSnoozed.then((unlisten) => unlisten());
    };
  }, [qc]);
}
