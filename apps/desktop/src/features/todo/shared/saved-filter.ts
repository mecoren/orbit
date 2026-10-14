/**
 * 保存的筛选器条件应用（#35；#71 起 14 键）
 *
 * 条件 JSON 键（与 Rust saved_filter_api::ALLOWED_CONDITION_KEYS 白名单对齐）：
 * - status: "pending" | "doing" | "done"（状态等值）
 * - priority_min: number（优先级下限，P1–P5 数字 ≥ 此值）
 * - project_ids: number[]（项目集，任一命中）
 * - label_ids: number[]（标签集，任一命中——需任务标签关联数据）
 * - due_within_days: number（截止在 [今天零点, 今天+N 天) 窗口）
 * - due_overdue: true（已逾期：due < 今天零点且未完成）
 * - favorite_only: true（仅收藏）
 * - due_from / due_until: number（截止区间绝对 ms，左闭右开；缺键不过滤）
 * - created_from: number（创建时间下限绝对 ms）
 * - done_from: number（完成时间下限绝对 ms；未完成任务恒不命中）
 * - has_reminder / has_attachment / has_open_subtask: boolean
 *   （true = 仅有，false = 仅无；存在集由调用方按投影拼装传入）
 * 缺键 = 不过滤；条件 AND 组合。
 */
import type { TodoTaskListItem } from "@/lib/tauri";

export interface SavedFilterConditions {
  status?: string;
  priority_min?: number;
  project_ids?: number[];
  label_ids?: number[];
  due_within_days?: number;
  due_overdue?: boolean;
  favorite_only?: boolean;
  due_from?: number;
  due_until?: number;
  created_from?: number;
  done_from?: number;
  has_reminder?: boolean;
  has_attachment?: boolean;
  has_open_subtask?: boolean;
}

/** 任务携带的标签 id 集（应用侧由 useTodoStore/查询拼装传入） */
export interface TaskLabelIndex {
  /** taskId → labelId[] */
  [taskId: number]: number[];
}

/** 存在键数据源（调用方按投影拼装；缺省 = 该维度不过滤） */
export interface TaskExistenceIndex {
  /** 有提醒的任务 id 集（提醒投影 task_id 集合） */
  reminderTaskIds?: Set<number>;
  /** 有附件的任务 id 集（task_attachment_flags） */
  attachmentTaskIds?: Set<number>;
  /** 有未完成子任务的任务 id 集（task_open_subtask_flags） */
  openSubtaskTaskIds?: Set<number>;
}

export function applySavedFilter(
  tasks: TodoTaskListItem[],
  rawConditions: string,
  labelIndex: TaskLabelIndex,
  existence: TaskExistenceIndex = {},
): TodoTaskListItem[] {
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
    if (c.due_from != null && (t.due_date == null || t.due_date < c.due_from)) return false;
    if (c.due_until != null && (t.due_date == null || t.due_date >= c.due_until)) return false;
    if (c.created_from != null && t.created_at < c.created_from) return false;
    if (c.done_from != null && (t.done !== 1 || (t.done_at ?? 0) < c.done_from)) return false;
    if (c.has_reminder != null && existence.reminderTaskIds != null) {
      if (existence.reminderTaskIds.has(t.id) !== c.has_reminder) return false;
    }
    if (c.has_attachment != null && existence.attachmentTaskIds != null) {
      if (existence.attachmentTaskIds.has(t.id) !== c.has_attachment) return false;
    }
    if (c.has_open_subtask != null && existence.openSubtaskTaskIds != null) {
      if (existence.openSubtaskTaskIds.has(t.id) !== c.has_open_subtask) return false;
    }
    return true;
  });
}
