/**
 * useTaskLabels — 任务→标签映射（列表行 / 看板卡共用）
 *
 * 拉取全量标签与任务-标签关联，前端 join 出 Map<task_id, TodoLabel[]>。
 * 刷新依赖 db-change 事件全量失效（events.ts），与 tasksQuery 同口径。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import {
  todoLabelList,
  todoTaskLabelList,
  type TodoLabel,
} from "@/lib/tauri";

export function useTaskLabels(): Map<number, TodoLabel[]> {
  const labelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
    staleTime: 60_000,
  });
  const relQuery = useQuery({
    queryKey: ["todo_task_label", "list"],
    queryFn: () => todoTaskLabelList({ page: 1, page_size: 10000 }),
    staleTime: 60_000,
  });

  return useMemo(() => {
    const labelById = new Map(
      (labelsQuery.data ?? []).map((l) => [l.id, l]),
    );
    const map = new Map<number, TodoLabel[]>();
    for (const rel of relQuery.data ?? []) {
      if (rel.is_deleted) continue;
      const label = labelById.get(rel.label_id);
      if (!label || label.is_deleted) continue;
      const list = map.get(rel.task_id);
      if (list) list.push(label);
      else map.set(rel.task_id, [label]);
    }
    return map;
  }, [labelsQuery.data, relQuery.data]);
}
