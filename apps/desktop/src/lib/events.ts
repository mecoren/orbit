/**
 * events — 响应式数据流桥
 *
 * 1. "db-change"：Rust EVENT_BUS 转发的本地写操作事件，使 react-query 缓存失效。
 *    按事件 table 精确失效（db-invalidation.ts 映射表）——写一条任务不再
 *    全量重拉 9+ 路查询（含三路万行列表）；未知表回退全量（宁多拉不漏刷）。
 * 2. "sync-finished"：云同步完成后的事件。云端拉取的合并写入不走 EVENT_BUS
 *    （无 db-change），须在此按 pulled_modules 失效缓存，否则界面不刷新。
 */
import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";

import { invalidateByTable } from "./db-invalidation";

/**
 * Rust EVENT_BUS 经桌面事件泵转发的精简载荷（A3）：只有表名与操作类型，
 * 整行 JSON（`DbEvent.payload`）不再过 IPC。`table: "*"` 是哨兵——事件落后
 * （Lagged）或全量备份恢复时发它，本文件按未知表回退全量失效。
 */
export interface DbChangeEvent {
  table: string;
  op?: string;
  /** 哨兵来源（lagged / import），仅诊断用 */
  kind?: string;
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
    const unlistenPromise = listen<DbChangeEvent>("db-change", (evt) => {
      // mock 桥（浏览器/e2e）发的 table="mock"，走全量回退
      if (invalidateByTable(qc, evt.payload.table) === null) {
        void qc.invalidateQueries();
      }
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
