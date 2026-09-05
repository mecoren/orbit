/**
 * 提醒推迟（snooze）——到期提醒 toast 的「推迟 10 分钟 / 30 分钟 / 1 小时」
 *
 * 语义沿用全库「删旧建新」惯例（todo_reminders 无 update 路径）：
 * 删除到期行 → 以「原 remind_at + 偏移」新建。锚点取原时间而非 now，
 * 保证「定了 10:00 的提醒被推迟 3 次」仍落在整点后第 n 个偏移，而非
 * 从每次点击时刻滚雪球。
 */
import type { useQueryClient } from "@tanstack/react-query";

import {
  todoReminderCreate,
  todoReminderDelete,
  type TodoReminder,
} from "@/lib/tauri";

export const SNOOZE_PRESETS = [
  { minutes: 10, label: "10 分钟" },
  { minutes: 30, label: "30 分钟" },
  { minutes: 60, label: "1 小时" },
] as const;

/** 推迟后的新 remind_at（= 原 remind_at + N 分钟），纯函数便于单测 */
export function snoozeRemindAt(remindAt: number, minutes: number): number {
  return remindAt + minutes * 60_000;
}

type QueryClientLike = ReturnType<typeof useQueryClient>;

/**
 * 删旧建新推迟一条提醒；失败静默（返回 false），调用方据此回退提示。
 * 成功后失效任务详情缓存，让详情抽屉提醒区块立即显示新时间。
 *
 * 删除失败（重复任务的系列续排已先行删过此行）不阻断推迟——
 * 用户意图是「到点再提醒我一次」，新建行无论如何都要落地；
 * 系列续排的防雪球守卫在 use-todo-reminder-listener 续排路径上，
 * 推迟产物行到期时不会克隆出平行系列。
 */
export async function snoozeReminder(
  reminderId: number,
  taskId: number,
  remindAt: number,
  minutes: number,
  qc: QueryClientLike,
): Promise<boolean> {
  const nextAt = snoozeRemindAt(remindAt, minutes);
  try {
    try {
      await todoReminderDelete(reminderId);
    } catch {
      /* 行已被续排引擎删除则跳过，继续新建 */
    }
    await todoReminderCreate({ task_id: taskId, remind_at: nextAt });
    void qc.invalidateQueries({ queryKey: ["todo-task-detail", taskId] });
    return true;
  } catch {
    return false;
  }
}

/** 提醒时间 → toast 副标题时间串（HH:mm），抽离便于复用与测试 */
export function remindAtClockLabel(remindAt: number): string {
  return new Date(remindAt).toLocaleString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** 未来时间 → 相对标签（「n 分钟后」「HH:mm」），推迟按钮 hover 提示用 */
export function snoozeTargetLabel(remindAt: number, minutes: number): string {
  const target = snoozeRemindAt(remindAt, minutes);
  const deltaMin = Math.round((target - Date.now()) / 60_000);
  return deltaMin >= 1 ? `${deltaMin} 分钟后` : remindAtClockLabel(target);
}

export type { TodoReminder };
