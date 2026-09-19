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

import {
  countInvalidateCall,
  invalidateByTable,
  isImmediateFullInvalidation,
  planFlushCoalesced,
} from "./db-invalidation";

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
  /** 本轮下载的附件数（附件缓存更新不在同步表白名单，须单独判） */
  downloaded_attachments?: number;
  duration_ms: number;
  skipped: boolean;
  /** 本轮 pull 真正写入的表集合（F42：按表精确失效的依据） */
  changed_tables?: string[];
}

export function useDbInvalidation() {
  const qc = useQueryClient();
  useEffect(() => {
    // 突发合并（D2）：窗口内多条 db-change 合并成一次按表批量失效。
    // N 条写 = N 次 invalidateQueries，每次都可能重拉万行；拖拽/批量/连点
    // 下属纯重复工作量。尾随窗口 150ms，窗口计时从第一条事件起。
    // bounded-by-lifecycle: 每次 flush 后 clear，只存活一个窗口期
    const pending = new Set<string>();
    let timer: ReturnType<typeof setTimeout> | null = null;
    const flush = () => {
      timer = null;
      if (pending.size === 0) return;
      // "*" 语义吞掉更窄的键：哨兵在窗口内出现过即一次全量失效
      const plan = planFlushCoalesced(pending);
      pending.clear();
      if (plan.full) {
        countInvalidateCall();
        void qc.invalidateQueries();
        return;
      }
      let full = false;
      for (const table of plan.tables) {
        if (invalidateByTable(qc, table) === null) {
          full = true;
          break;
        }
      }
      // 未知表（含 mock 桥的 table:"mock"）回退全量，一窗只一次
      if (full) {
        countInvalidateCall();
        void qc.invalidateQueries();
      }
    };
    const unlistenPromise = listen<DbChangeEvent>("db-change", (evt) => {
      const table = evt.payload.table;
      // Lagged 哨兵或 "*" 立刻全量，不等窗口（宁多拉不漏刷）
      if (isImmediateFullInvalidation(table, evt.payload.kind)) {
        if (timer) {
          clearTimeout(timer);
          timer = null;
        }
        pending.clear();
        countInvalidateCall();
        void qc.invalidateQueries();
        return;
      }
      pending.add(table);
      if (timer == null) {
        timer = setTimeout(flush, 150);
      }
    });
    return () => {
      if (timer) clearTimeout(timer);
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}

/**
 * 云同步完成 → 按「真正变更的表」精确失效缓存（skipped/无变更轮次零失效）
 *
 * 云端拉取的合并写入不走 EVENT_BUS（无 db-change），必须在此兜底。F42 起
 * 引擎回报 `changed_tables`（merge 实际写入的表），替代此前「pulled_modules
 * === 0 就整轮不刷」的粗判据——那会漏掉两类轮次：
 * ① `pulled_modules == 0` 但附件有变更（附件缓存不在同步表白名单）；
 * ② 模块计数为 0 但合并实际改了行（计数按桶，桶下载 ≠ 行变更）。
 * 表集合缺失（旧引擎）时有拉取即保守全量；未知表回退全量（宁多拉不漏刷）。
 */
export function useSyncInvalidation() {
  const qc = useQueryClient();
  useEffect(() => {
    const unlistenPromise = listen<SyncFinishedEvent>("sync-finished", (evt) => {
      const payload = evt.payload;
      if (payload.skipped) return;
      const tables = new Set(payload.changed_tables ?? []);
      // 附件下载/占位行写入不进同步表事件，映射到挂载列表与附件键
      if ((payload.downloaded_attachments ?? 0) > 0) {
        tables.add("todo_task_attachments");
      }
      if (tables.size === 0) {
        if (payload.pulled_modules > 0) {
          countInvalidateCall();
          void qc.invalidateQueries();
        }
        return;
      }
      let full = false;
      for (const table of tables) {
        if (invalidateByTable(qc, table) === null) {
          full = true;
          break;
        }
      }
      if (full) {
        countInvalidateCall();
        void qc.invalidateQueries();
      }
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [qc]);
}
