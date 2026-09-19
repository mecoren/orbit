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
  todo_labels: [["todo-label"], ["todo-task-detail"], ["global-search"]],
  todo_task_labels: [["todo_task_label"], ["todo-task-detail"]],
  todo_reminders: [["todo_reminders"], ["todo-task-detail"]],
  todo_comments: [["todo-task-detail"]],
  todo_task_relations: [["todo-task-detail"]],
  todo_task_attachments: [["task-attachments"]],
  todo_templates: [["templates"]],
  todo_saved_filters: [["saved-filters"]],
};

/**
 * 按事件表名失效对应缓存。返回失效的键组（测试断言用）；
 * 未知表返回 null 表示调用方应回退全量失效。
 */
export function invalidateByTable(qc: QueryClient, table: string): string[][] | null {
  const keys = TABLE_QUERY_KEYS[table];
  if (!keys) return null;
  for (const key of keys) {
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
