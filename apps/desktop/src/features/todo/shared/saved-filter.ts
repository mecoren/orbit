/**
 * 保存的筛选器条件应用（#35）
 *
 * 条件 JSON 键（与 Rust saved_filter_api::ALLOWED_CONDITION_KEYS 白名单对齐）：
 * - status: "pending" | "doing" | "done"（状态等值）
 * - priority_min: number（优先级下限，P1–P5 数字 ≥ 此值）
 * - project_ids: number[]（项目集，任一命中）
 * - label_ids: number[]（标签集，任一命中——需任务标签关联数据）
 * - due_within_days: number（截止在 [今天零点, 今天+N 天) 窗口）
 * - due_overdue: true（已逾期：due < 今天零点且未完成）
 * - favorite_only: true（仅收藏）
 * 缺键 = 不过滤；条件 AND 组合。
 */
import type { TodoTask } from "@/lib/tauri";

export interface SavedFilterConditions {
  status?: string;
  priority_min?: number;
  project_ids?: number[];
  label_ids?: number[];
  due_within_days?: number;
  due_overdue?: boolean;
  favorite_only?: boolean;
}

/** 任务携带的标签 id 集（应用侧由 useTodoStore/查询拼装传入） */
export interface TaskLabelIndex {
  /** taskId → labelId[] */
  [taskId: number]: number[];
}

export function applySavedFilter(
  tasks: TodoTask[],
  rawConditions: string,
  labelIndex: TaskLabelIndex,
): TodoTask[] {
  let c: SavedFilterConditions;
  try {
    c = JSON.parse(rawConditions) as SavedFilterConditions;
  } catch {
    return tasks; // 条件损坏不过滤（防御；Rust 端创建时已校验）
  }
  const todayZero = new Date();
  todayZero.setHours(0, 0, 0, 0);
  const T0 = todayZero.getTime();

  return tasks.filter((t) => {
    if (c.status != null && t.status !== c.status) return false;
    if (c.priority_min != null && t.priority < c.priority_min) return false;
    if (c.project_ids != null && !c.project_ids.includes(t.project_id ?? -1)) return false;
    if (c.label_ids != null && c.label_ids.length > 0) {
      const taskLabels = labelIndex[t.id] ?? [];
      if (!c.label_ids.some((lid) => taskLabels.includes(lid))) return false;
    }
    if (c.due_within_days != null) {
      const d = t.due_date;
      if (d == null) return false;
      if (d < T0 || d >= T0 + c.due_within_days * 86_400_000) return false;
    }
    if (c.due_overdue === true) {
      const d = t.due_date;
      if (d == null || d >= T0 || t.done === 1) return false;
    }
    if (c.favorite_only === true && t.is_favorite !== 1) return false;
    return true;
  });
}
