/**
 * useTaskLabels — 任务→标签映射（列表行 / 看板卡共用）
 *
 * A4：core 侧一次往返的瘦投影（task_labels_projection）替代
 * labels+task_labels 两次万行整表 + 前端 join。只传展示三列
 *（id/title/hex_color），uuid/version/时间戳不出桥。
 * 刷新口径不变：todo_labels / todo_task_labels 写事件经 db-invalidation
 * 精确失效（events.ts），与 tasksQuery 同链。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import {
  taskLabelsProjection,
  type ProjectedTaskLabel,
} from "@/lib/tauri";

export function useTaskLabels(): Map<number, ProjectedTaskLabel[]> {
  const query = useQuery({
    queryKey: ["todo_task_labels", "projection"],
    queryFn: () => taskLabelsProjection(),
    staleTime: 60_000,
    // A1：万行级投影不随全局 10min gcTime 长驻（与 use-task-reminders 同口径）
    gcTime: 10_000,
  });

  return useMemo(() => {
    const map = new Map<number, ProjectedTaskLabel[]>();
    for (const g of query.data ?? []) {
      map.set(g.task_id, g.labels);
    }
    return map;
  }, [query.data]);
}
