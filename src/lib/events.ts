/**
 * events — 响应式数据流桥
 *
 * 1. "db-change"：Rust EVENT_BUS 转发的本地写操作事件，使 react-query 缓存失效。
 * 2. "sync-finished"：云同步完成后的事件。云端拉取的合并写入不走 EVENT_BUS
 *    （无 db-change），须在此按 pulled_modules 失效缓存，否则界面不刷新。
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

/** SyncResult 载荷（cloud_sync_cmd run_sync emit） */
export interface SyncFinishedEvent {
  pushed_modules: number;
  pulled_modules: number;
  duration_ms: number;
  skipped: boolean;
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

/** 云同步完成 → 拉取过数据时失效全部业务缓存（skipped/纯推送无需刷新） */
export function useSyncInvalidation() {
  const qc = useQueryClient();
  useEffect(() => {
    const unlistenPromise = listen<SyncFinishedEvent>("sync-finished", (evt) => {
      if (evt.payload.skipped || evt.payload.pulled_modules === 0) return;
      void qc.invalidateQueries();
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}
