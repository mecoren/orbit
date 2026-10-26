/**
 * 乐观写入口径（D3）：桌面写路径可先 patch 缓存提前 paint。
 *
 * 形状钉死三条（A2 换行类型时调用点不动，只改类型参数）：
 * - 只改**已存在行**的字段，绝不增删行、绝不重排；
 * - db-change 失效链仍是真值收敛者，此处只是提前 paint，不替代重拉；
 * - 派生新行的场景（重复任务完成等）禁止在此复刻引擎规则，另见 D4。
 *
 * 覆盖三种缓存形态：["todo_tasks", ...] 数组行、分页查询的
 * `{ pages, pageParams }` 无限形态（P1 窗口化后列表走它），以及
 * ["todo-task-detail", id] 单对象详情。
 */
import { type QueryClient } from "@tanstack/react-query";

/**
 * 无限查询缓存形态（useInfiniteQuery 的 data）。
 *
 * 注意 `pages` 的元素**不一定是行数组**：本仓的分页 API 一页是
 * `{ items, next_cursor, has_more }`（`TodoTaskPage`），见
 * [mapPageRows] 的两种形态处理。
 */
interface InfiniteDataShape {
  pages: unknown[];
  pageParams: unknown[];
}

function isInfiniteData(data: unknown): data is InfiniteDataShape {
  return (
    data != null &&
    typeof data === "object" &&
    Array.isArray((data as { pages?: unknown }).pages) &&
    Array.isArray((data as { pageParams?: unknown }).pageParams)
  );
}

/**
 * 对一页的行做 map：兼容「页 = 行数组」与「页 = { items: 行数组 }」两种形态。
 * 返回 null 表示该页不是可识别的行载体（原样返回，不碰）。
 */
function mapPageRows<T extends { id: number }>(page: unknown, fn: (rows: T[]) => T[]): unknown {
  if (Array.isArray(page)) return fn(page as T[]);
  if (
    page != null &&
    typeof page === "object" &&
    Array.isArray((page as { items?: unknown }).items)
  ) {
    const shape = page as { items: T[] };
    const next = fn(shape.items);
    return next === shape.items ? page : { ...shape, items: next };
  }
  return page;
}

/**
 * 从数组型或无限查询缓存里摘除指定行（删除乐观隐藏专用）。
 *
 * 摘除后不重排其它行、不改 `next_cursor`：游标描述的是「上一页最后一行在
 * 排序中的位置」，少一条已加载行不影响下一页从哪里开始。
 */
export function removeRowsFromData<T extends { id: number }>(
  data: unknown,
  ids: ReadonlySet<number>,
): unknown {
  if (Array.isArray(data)) {
    const rows = data as T[];
    return rows.some((r) => ids.has(r.id)) ? rows.filter((r) => !ids.has(r.id)) : data;
  }
  if (isInfiniteData(data)) {
    let touched = false;
    const pages = data.pages.map((page) => {
      const next = mapPageRows<T>(page, (rows) =>
        rows.some((r) => ids.has(r.id)) ? rows.filter((r) => !ids.has(r.id)) : rows,
      );
      if (next !== page) touched = true;
      return next;
    });
    return touched ? { ...data, pages } : data;
  }
  return data;
}

export function patchQueriesData<T extends { id: number }>(
  qc: QueryClient,
  keyPrefix: readonly unknown[],
  ids: number[],
  patch: Partial<T>,
): void {
  if (ids.length === 0) return;
  const idSet = new Set(ids);
  const queries = qc.getQueriesData<unknown>({ queryKey: [...keyPrefix] });
  const mergeRow = (row: T): T => {
    if (row == null || typeof row !== "object" || !idSet.has(row.id)) return row;
    return { ...row, ...patch };
  };
  for (const [key, data] of queries) {
    // 数组形态：命中行浅合并，其余行原引用（memo 不炸）
    if (Array.isArray(data)) {
      const rows = data as T[];
      const next = rows.map(mergeRow);
      if (next.some((row, i) => row !== rows[i])) qc.setQueryData(key, next);
      continue;
    }
    // 分页形态（P1 窗口化）：逐页合并，不改页数/顺序/游标
    if (isInfiniteData(data)) {
      let touched = false;
      const pages = data.pages.map((page) => {
        const next = mapPageRows<T>(page, (rows) => {
          const merged = rows.map(mergeRow);
          if (merged.some((row, i) => row !== rows[i])) touched = true;
          return merged;
        });
        return next;
      });
      if (touched) qc.setQueryData(key, { ...data, pages });
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
