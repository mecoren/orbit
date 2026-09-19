/**
 * useTaskReminders — 任务→行内提醒映射（列表行/看板卡/日历行共用）
 *
 * A4：core 侧一次往返的瘦投影（task_reminders_projection）替代万行提醒
 * 整表 + 前端 join。组内已按 remind_at 升序（displayReminder 的选取前提），
 * is_deleted 恒 0 由 SQL 过滤保证（TaskReminderMeta 字段填 0 对齐）。
 * 刷新口径不变：todo_reminders 写事件经 db-invalidation 精确失效——完成/
 * 推迟/续排/云同步的任何写入都会触发重拉，与 useTaskLabels 同链。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import { taskRemindersProjection } from "@/lib/tauri";

import type { TaskReminderMeta } from "./reminder-meta";

export function useTaskReminders(): Map<number, TaskReminderMeta[]> {
  const query = useQuery({
    queryKey: ["todo_reminders", "projection"],
    queryFn: () => taskRemindersProjection(),
    staleTime: 60_000,
    // A1：万行级投影不随全局 10min gcTime 长驻（多视图切换会各留一份）
    gcTime: 10_000,
  });

  return useMemo(() => {
    const map = new Map<number, TaskReminderMeta[]>();
    for (const g of query.data ?? []) {
      map.set(
        g.task_id,
        g.reminders.map((r) => ({ id: r.id, remind_at: r.remind_at, is_deleted: 0 })),
      );
    }
    return map;
  }, [query.data]);
}
