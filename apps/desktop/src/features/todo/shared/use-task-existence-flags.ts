/**
 * useTaskAttachmentIds / useTaskOpenSubtaskIds — 任务存在旗标集合（#71）
 *
 * core 侧一次往返的瘦投影（task_attachment_flags / task_open_subtask_flags）——
 * 只传有行的 task_id，缺位即 false。筛选器 has_attachment / has_open_subtask
 * 键的数据源；与 use-task-dependencies 同刷新口径（gcTime 短驻 + db-change
 * 表级精确失效，见 lib/db-invalidation.ts）。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import { taskAttachmentFlags, taskDescriptionFlags, taskOpenSubtaskFlags } from "@/lib/tauri";

function useFlagSet(
  queryKey: string[],
  queryFn: () => Promise<Array<{ task_id: number }>>,
): Set<number> {
  const query = useQuery({
    queryKey,
    queryFn,
    staleTime: 60_000,
    // 万行级投影不随全局 10min gcTime 长驻（与 use-task-labels 同口径）
    gcTime: 10_000,
  });

  return useMemo(() => {
    const set = new Set<number>();
    for (const f of query.data ?? []) set.add(f.task_id);
    return set;
  }, [query.data]);
}

/** 有附件的任务 id 集（筛选器 has_attachment 数据源） */
export function useTaskAttachmentIds(): Set<number> {
  return useFlagSet(["todo_task_attachments", "flags"], taskAttachmentFlags);
}

/** 有未完成子任务的任务 id 集（筛选器 has_open_subtask 数据源） */
export function useTaskOpenSubtaskIds(): Set<number> {
  return useFlagSet(["todo_subtasks", "open-flags"], taskOpenSubtaskFlags);
}

/**
 * 有描述的任务 id 集（列表通道裁剪 description 后的行内图标数据源）。
 * 失效走 todo_tasks 前缀匹配（该键挂在 ["todo_tasks"] 下）。
 */
export function useTaskDescriptionIds(): Set<number> {
  return useFlagSet(["todo_tasks", "description-flags"], taskDescriptionFlags);
}
