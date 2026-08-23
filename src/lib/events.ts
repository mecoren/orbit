/**
 * events — 响应式数据流桥
 *
 * 监听 Rust 侧 "db-change" 事件（EVENT_BUS 转发，载荷为 DbEvent：
 * { table, op, record_id, record_uuid, payload, device_id, timestamp }），
 * 使 react-query 缓存失效并重新拉取。
 *
 * 当前采用粗粒度全量失效（M1 补遗）；后续可按 event.table 映射到具体
 * queryKey 实现细粒度失效（对齐 wait-home dashboard-query-invalidation 模式）。
 */
import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";

/** Rust DbEvent 载荷（snake_case 直传） */
export interface DbChangeEvent {
  table: string;
  op: string;
  record_id?: number;
  record_uuid?: string;
  device_id?: string;
  timestamp: number;
}

export function useDbInvalidation() {
  const qc = useQueryClient();
  useEffect(() => {
    const unlistenPromise = listen<DbChangeEvent>("db-change", () => {
      void qc.invalidateQueries();
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}
