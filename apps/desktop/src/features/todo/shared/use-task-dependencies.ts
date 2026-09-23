/**
 * useTaskDependencies — 任务→关联计数旗标映射（C7 列表行「有关联 / 被阻塞」徽标）
 *
 * A4：core 侧一次往返的瘦投影（task_dependency_flags）——只传出边存活行总数与
 * 其中 blocked_by 条数，不拉全量关系表。刷新口径：todo_task_relations 写事件经
 * db-invalidation 精确失效本键（与 task_dependency_flags 同一投影缓存）。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import { taskDependencyFlags, type TaskDependencyFlags } from "@/lib/tauri";

export function useTaskDependencies(): Map<number, TaskDependencyFlags> {
  const query = useQuery({
    queryKey: ["todo_task_relations", "projection"],
    queryFn: () => taskDependencyFlags(),
    staleTime: 60_000,
    // A1：万行级投影不随全局 10min gcTime 长驻（与 use-task-labels 同口径）
    gcTime: 10_000,
  });

  return useMemo(() => {
    const map = new Map<number, TaskDependencyFlags>();
    for (const f of query.data ?? []) {
      map.set(f.task_id, f);
    }
    return map;
  }, [query.data]);
}
