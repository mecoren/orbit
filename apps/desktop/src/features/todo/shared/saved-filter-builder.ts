/**
 * 保存筛选器的可视化构建器模型（#35 升级：裸 JSON 手填 → 表单化；#71 起 14 键）
 *
 * 表单态与条件 JSON 双向映射：表单控件（下拉/多选/日期/开关）↔ SavedFilterConditions
 * 十四键白名单（与 Rust saved_filter_api::ALLOWED_CONDITION_KEYS 对齐）。
 * 纯函数无 React 依赖，可单测；对话框组件消费产出 conditions 字符串。
 */
import type { SavedFilterConditions } from "./saved-filter";

/**
 * 存在三态：null = 不过滤，true = 仅有，false = 仅无
 * （对话框以三段 chips 表达；JSON 只存非 null 键）
 */
export type ExistenceTriState = boolean | null;

/** 表单态：null/undefined/空数组 = 该维度不过滤 */
export interface FilterFormState {
  /** 状态等值：all = 不过滤 */
  status: string | null;
  /** 优先级下限（P1–P5 数字）；null = 不过滤 */
  priorityMin: number | null;
  /** 项目 id 集；空数组 = 不过滤 */
  projectIds: number[];
  /** 标签 id 集；空数组 = 不过滤 */
  labelIds: number[];
  /** 截止窗口天数；null = 不过滤 */
  dueWithinDays: number | null;
  /** 仅逾期 */
  overdueOnly: boolean;
  /** 仅收藏 */
  favoriteOnly: boolean;
  /** 截止区间（绝对 ms；YYYY-MM-DD 对话框输入转零点 ms） */
  dueFrom: number | null;
  dueUntil: number | null;
  /** 创建时间下限（绝对 ms） */
  createdFrom: number | null;
  /** 完成时间下限（绝对 ms） */
  doneFrom: number | null;
  /** 存在三态：有提醒 / 有附件 / 有未完成子任务 */
  hasReminder: ExistenceTriState;
  hasAttachment: ExistenceTriState;
  hasOpenSubtask: ExistenceTriState;
}

export const EMPTY_FILTER_FORM: FilterFormState = {
  status: null,
  priorityMin: null,
  projectIds: [],
  labelIds: [],
  dueWithinDays: null,
  overdueOnly: false,
  favoriteOnly: false,
  dueFrom: null,
  dueUntil: null,
  createdFrom: null,
  doneFrom: null,
  hasReminder: null,
  hasAttachment: null,
  hasOpenSubtask: null,
};

/** 条件 JSON → 表单态（缺键/损坏回退空表单——与 applySavedFilter 防御同口径） */
export function parseConditions(raw: string): FilterFormState {
  let c: SavedFilterConditions;
  try {
    c = JSON.parse(raw) as SavedFilterConditions;
  } catch {
    return { ...EMPTY_FILTER_FORM, projectIds: [], labelIds: [] };
  }
  return {
    status: c.status ?? null,
    priorityMin: c.priority_min ?? null,
    projectIds: c.project_ids ?? [],
    labelIds: c.label_ids ?? [],
    dueWithinDays: c.due_within_days ?? null,
    overdueOnly: c.due_overdue === true,
    favoriteOnly: c.favorite_only === true,
    dueFrom: c.due_from ?? null,
    dueUntil: c.due_until ?? null,
    createdFrom: c.created_from ?? null,
    doneFrom: c.done_from ?? null,
    hasReminder: c.has_reminder ?? null,
    hasAttachment: c.has_attachment ?? null,
    hasOpenSubtask: c.has_open_subtask ?? null,
  };
}

/**
 * 表单态 → 条件 JSON 字符串。空维度不落键（缺键 = 不过滤语义），
 * 全空表单产出 "{}"（Rust 端接受——空条件 = 万能视图，仅按名字归档）。
 */
export function buildConditions(f: FilterFormState): string {
  const c: SavedFilterConditions = {};
  if (f.status != null) c.status = f.status;
  if (f.priorityMin != null) c.priority_min = f.priorityMin;
  if (f.projectIds.length > 0) c.project_ids = f.projectIds;
  if (f.labelIds.length > 0) c.label_ids = f.labelIds;
  if (f.dueWithinDays != null) c.due_within_days = f.dueWithinDays;
  if (f.overdueOnly) c.due_overdue = true;
  if (f.favoriteOnly) c.favorite_only = true;
  if (f.dueFrom != null) c.due_from = f.dueFrom;
  if (f.dueUntil != null) c.due_until = f.dueUntil;
  if (f.createdFrom != null) c.created_from = f.createdFrom;
  if (f.doneFrom != null) c.done_from = f.doneFrom;
  if (f.hasReminder != null) c.has_reminder = f.hasReminder;
  if (f.hasAttachment != null) c.has_attachment = f.hasAttachment;
  if (f.hasOpenSubtask != null) c.has_open_subtask = f.hasOpenSubtask;
  return JSON.stringify(c);
}

/** 工具栏筛选状态 → 表单态（「存为视图」预填：面板当前筛选一键固化） */
export function toolbarToForm(input: {
  statusFilter: string | null;
  priorityFilter: number | null;
  favoriteOnly: boolean;
}): FilterFormState {
  return {
    ...EMPTY_FILTER_FORM,
    // 工具栏状态档 all → null（不过滤）；undone 档无对应白名单键，丢弃（提示层说明）
    status: input.statusFilter && input.statusFilter !== "all" && input.statusFilter !== "undone"
      ? input.statusFilter
      : null,
    priorityMin: input.priorityFilter,
    favoriteOnly: input.favoriteOnly,
  };
}
