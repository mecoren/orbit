/**
 * useTaskReminders — 任务→行内提醒映射（列表行/看板卡/日历行共用）
 *
 * 拉取全量提醒行，前端 join 出 Map<task_id, remind_at[]>（仅未删行，
 * remind_at 升序）。刷新依赖 db-change 全量失效（events.ts）——完成/
 * 推迟/续排/云同步对 todo_reminders 的任何写入都会触发重拉，与
 * useTaskLabels 同口径。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import { todoReminderList } from "@/lib/tauri";

import type { TaskReminderMeta } from "./reminder-meta";

export function useTaskReminders(): Map<number, TaskReminderMeta[]> {
  const query = useQuery({
    queryKey: ["todo_reminders", "list"],
    queryFn: () => todoReminderList({ page: 1, page_size: 10000 }),
    staleTime: 60_000,
    // A1：万行整表投影不随全局 10min gcTime 长驻（多视图切换会各留一份）
    gcTime: 10_000,
  });

  return useMemo(() => {
    const map = new Map<number, TaskReminderMeta[]>();
    for (const r of query.data ?? []) {
      if (r.is_deleted) continue;
      const list = map.get(r.task_id);
      if (list) list.push(r);
      else map.set(r.task_id, [r]);
    }
    // 每任务的行按 remind_at 升序（displayReminder 的选取前提）
    for (const list of map.values()) {
      list.sort((a, b) => a.remind_at - b.remind_at);
    }
    return map;
  }, [query.data]);
}
