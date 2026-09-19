/**
 * 乐观写入口径（D3）：桌面写路径可先 patch 缓存提前 paint。
 *
 * 形状钉死三条（A2 换行类型时调用点不动，只改类型参数）：
 * - 只改**已存在行**的字段，绝不增删行、绝不重排；
 * - db-change 失效链仍是真值收敛者，此处只是提前 paint，不替代重拉；
 * - 派生新行的场景（重复任务完成等）禁止在此复刻引擎规则，另见 D4。
 *
 * 覆盖两种缓存形态：["todo_tasks", ...] 数组行，以及
 * ["todo-task-detail", id] 单对象详情。
 */
import { type QueryClient } from "@tanstack/react-query";

export function patchQueriesData<T extends { id: number }>(
  qc: QueryClient,
  keyPrefix: readonly unknown[],
  ids: number[],
  patch: Partial<T>,
): void {
  if (ids.length === 0) return;
  const idSet = new Set(ids);
  const queries = qc.getQueriesData<unknown>({ queryKey: [...keyPrefix] });
  for (const [key, data] of queries) {
    // 数组形态：命中行浅合并，其余行原引用（memo 不炸）
    if (Array.isArray(data)) {
      let touched = false;
      const next = (data as T[]).map((row) => {
        if (row == null || typeof row !== "object" || !idSet.has((row as T).id)) return row;
        touched = true;
        return { ...row, ...patch };
      });
      if (touched) qc.setQueryData(key, next);
      continue;
    }
    // 单对象形态（详情）：id 命中即浅合并
    if (
      data != null &&
      typeof data === "object" &&
      "id" in data &&
      idSet.has((data as T).id)
    ) {
      qc.setQueryData(key, { ...(data as T), ...patch });
    }
  }
}
