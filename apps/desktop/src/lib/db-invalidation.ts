/**
 * db-change 表级失效映射（对齐 wait-home dashboard-query-invalidation 模式）
 *
 * Rust EVENT_BUS 的每条写事件都带 table 名——此前桌面端全量 invalidateQueries()，
 * 勾选一条任务完成 = 9+ 路查询全部标脏重拉（含三路万行级全量列表），
 * 是写路径上最大的固定放大器。此模块按 table 精确失效：
 *
 * - 主表事件只失效直接持有该表数据的 queryKey 前缀 + 强派生键
 *   （todo_tasks 联动角标/统计/全局搜索：读路径跨表聚合）
 * - todo_tasks 上仍有 todo_task_labels/todo_reminders 等子表事件——它们
 *   只影响 detail/子表列表，不碰主列表
 * - 未知表（未来新增/同步引擎内部表）回退全量失效——宁多拉不漏刷
 */
import { type QueryClient } from "@tanstack/react-query";

/** 表名 → 该表数据直接流入的 queryKey 前缀清单 */
const TABLE_QUERY_KEYS: Record<string, string[][]> = {
  todo_tasks: [
    ["todo_tasks"],
    ["todo-task-detail"],
    ["global-search"],
    ["stats"],
    ["trash"],
  ],
  // 历史轨迹：log_activity 落库后自发事件（业务写路径的 todo_tasks 事件
  // 先于轨迹 INSERT，搭车重拉会竞态读旧——不能挂 todo_tasks 下）
  todo_activity_log: [["task-activity"]],
  todo_subtasks: [["todo-task-detail"]],
  todo_projects: [["todo-project"]],
  todo_labels: [
    ["todo-label"],
    ["todo-task-detail"],
    ["global-search"],
    // A4 标签 chips 投影（JOIN 依赖标签表：改名/改色须刷 chips）
    ["todo_task_labels", "projection"],
  ],
  // A4：标签 chips 投影（旧 ["todo_task_label"] 整表键仍被右键菜单消费，保留）
  todo_task_labels: [["todo_task_label"], ["todo_task_labels", "projection"], ["todo-task-detail"]],
  // A4：提醒徽标投影（旧 ["todo_reminders"] 整表键仍被新建表单消费，保留）
  todo_reminders: [["todo_reminders"], ["todo_reminders", "projection"], ["todo-task-detail"]],
  todo_comments: [["todo-task-detail"]],
  todo_task_relations: [["todo-task-detail"]],
  todo_task_attachments: [["task-attachments"]],
  todo_templates: [["templates"]],
  todo_saved_filters: [["saved-filters"]],
};

/**
 * DEV 失效计数（D1 尺子）：每次 invalidateQueries 调用记 +1，挂
 * `window.__orbitPerf.invalidateCalls`，仅 DEV 暴露，供
 * `perf-metrics/interaction.mjs` 读 click 前后增量。生产包零开销。
 */
export function countInvalidateCall(): void {
  try {
    if (
      typeof window !== "undefined" &&
      (import.meta as unknown as { env?: { DEV?: boolean } }).env?.DEV
    ) {
      const w = window as unknown as { __orbitPerf?: { invalidateCalls?: number } };
      w.__orbitPerf ??= {};
      w.__orbitPerf.invalidateCalls = (w.__orbitPerf.invalidateCalls ?? 0) + 1;
    }
  } catch {
    /* 非浏览器/无 DEV 环境静默跳过 */
  }
}

/**
 * 按事件表名失效对应缓存。返回失效的键组（测试断言用）；
 * 未知表返回 null 表示调用方应回退全量失效。
 */
export function invalidateByTable(qc: QueryClient, table: string): string[][] | null {
  const keys = TABLE_QUERY_KEYS[table];
  if (!keys) return null;
  for (const key of keys) {
    countInvalidateCall();
    void qc.invalidateQueries({ queryKey: key });
  }
  return keys;
}

/**
 * 突发合并决策纯函数（D2，events.ts 尾随窗口的收敛规则）：
 * - Lagged 哨兵（table "*" 或 kind "lagged"）立刻全量，不等窗口；
 * - 窗口内出现过 "*" 则吞掉更窄的键，一窗一次全量。
 * 纯函数便于单测，未知表（含 mock 桥 table:"mock"）在 flush 时由
 * invalidateByTable 返回 null 触发全量，一窗同样只一次。
 */
export function isImmediateFullInvalidation(table: string, kind?: string): boolean {
  return table === "*" || kind === "lagged";
}

export function planFlushCoalesced(tables: Iterable<string>): { full: boolean; tables: string[] } {
  const uniq = [...new Set(tables)];
  if (uniq.includes("*")) return { full: true, tables: [] };
  return { full: false, tables: uniq };
}
