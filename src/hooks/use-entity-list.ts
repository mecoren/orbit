import { useQuery } from "@tanstack/react-query";

import { businessCount } from "@/lib/tauri";

/**
 * 实体列表查询参数
 *
 * - `keyword`/`page`/`pageSize` 会参与 queryKey，确保任一变化触发重新请求
 * - `fetcher` 闭包内应捕获这些参数并传给后端
 */
export interface UseEntityListOptions<T> {
  /** 表名（用于 businessCount 统计总数） */
  table: string;
  /** 数据拉取函数（应包含 keyword/page/pageSize 参数） */
  fetcher: () => Promise<T[]>;
  /** 当前搜索关键词（参与 queryKey，null/undefined 视为空） */
  keyword?: string | null;
  /** 当前页码（1-based，参与 queryKey） */
  page?: number;
  /** 每页大小（参与 queryKey） */
  pageSize?: number;
  /** 是否启用总数查询（默认 true，关闭时 total 为 0） */
  enableCount?: boolean;
}

/**
 * 实体列表 + 总数 Hook
 *
 * - `items`: 当前 fetcher 返回的数据
 * - `total`: 数据库中 `is_deleted=0` 的真实记录数（来自 `business_count` 命令）
 * - `queryKey` 包含 `[table, keyword, page, pageSize]`，参数变化自动重新请求
 *
 * 缓存策略：
 * - `staleTime: 2min` — 列表数据变更频率低，2 分钟内复用缓存避免重复请求
 * - `gcTime: 5min` — 离开页面后缓存保留 5 分钟，返回时秒开
 *
 * 示例：
 * ```ts
 * const { items, total, loading, refetch } = useEntityList({
 *   table: "rec_movies",
 *   fetcher: () => movieList({ keyword, page, page_size: pageSize }),
 *   keyword,
 *   page,
 *   pageSize,
 * });
 * ```
 */
export function useEntityList<T>(options: UseEntityListOptions<T>) {
  const {
    table,
    fetcher,
    keyword = null,
    page = 1,
    pageSize = 50,
    enableCount = true,
  } = options;

  // queryKey 包含所有影响请求结果的参数
  const query = useQuery({
    queryKey: [table, keyword, page, pageSize],
    // 搜索/翻页时保留上一份列表，避免整页骨架屏闪现
    placeholderData: (prev) => prev,
    queryFn: async () => {
      performance.mark(`fetcher-${table}-start`);
      const start = performance.now();
      const result = await fetcher();
      const ms = performance.now() - start;
      performance.mark(`fetcher-${table}-end`);
      performance.measure(`fetcher-${table}`, `fetcher-${table}-start`, `fetcher-${table}-end`);
      if (typeof window !== "undefined") {
        (window as unknown as Record<string, unknown>).__timingLogs ??= [] as unknown[];
        ((window as unknown as Record<string, unknown[]>).__timingLogs).push({ table, type: "fetcher", ms: Math.round(ms), items: result.length, at: new Date().toLocaleTimeString() });
      }
      console.log(`[useEntityList] fetcher(${table}) took ${ms.toFixed(1)}ms, items=${result.length}`);
      return result;
    },
    staleTime: 2 * 60 * 1000,
  });

  // 并行查询总数（仅过滤 is_deleted=0），queryKey 与列表查询关联以便失效时同步刷新
  const countQuery = useQuery({
    queryKey: ["count", table, keyword],
    queryFn: async () => {
      performance.mark(`count-${table}-start`);
      const start = performance.now();
      const result = await businessCount(table);
      const ms = performance.now() - start;
      performance.mark(`count-${table}-end`);
      performance.measure(`count-${table}`, `count-${table}-start`, `count-${table}-end`);
      if (typeof window !== "undefined") {
        (window as unknown as Record<string, unknown>).__timingLogs ??= [] as unknown[];
        ((window as unknown as Record<string, unknown[]>).__timingLogs).push({ table, type: "count", ms: Math.round(ms), result, at: new Date().toLocaleTimeString() });
      }
      console.log(`[useEntityList] businessCount(${table}) took ${ms.toFixed(1)}ms, result=${result}`);
      return result;
    },
    enabled: enableCount,
    staleTime: 2 * 60 * 1000,
  });

  return {
    items: query.data ?? [],
    total: countQuery.data ?? 0,
    loading: query.isLoading,
    error: query.error,
    refetch: () => {
      void query.refetch();
      void countQuery.refetch();
    },
  };
}
