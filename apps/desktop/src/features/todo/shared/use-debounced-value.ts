/**
 * useDebouncedValue — 输入防抖 hook（共享）
 *
 * 高频击键场景（工具栏搜索/全局搜索）停止输入 delayMs 后才更新下游值，
 * 避免每键触发全量过滤/IPC。原实现局部在 global-search-dialog，
 * 工具栏搜索接入后收编共享（同口径 250ms）。
 */
import { useEffect, useState } from "react";

export function useDebouncedValue(value: string, delayMs: number): string {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(id);
  }, [value, delayMs]);
  return debounced;
}
