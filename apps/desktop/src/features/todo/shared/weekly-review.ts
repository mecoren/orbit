/**
 * weekly-review — 引导式周回顾的清单层（纯函数，G5）
 *
 * GTD 方法论把周回顾列为成败关键，但品类普遍只有「完成统计」没有「回顾
 * 向导」——用户要自己逐个清单翻。本模块把周回顾的三类待处置对象按口径
 * 归集：逾期（要不要顺延）、无日期（要不要排期）、停滞（要不要唤醒），
 * 供向导逐步引导处理。纯函数无副作用，双端可镜像。
 *
 * 口径：
 * - 三组只收「未完成」任务（已完成不进回顾）；
 * - 三组可重叠（同一任务既是逾期又停滞 = 最需要唤醒的），组内按任务
 *   原序去重（同一 id 不重复出现）；
 * - 逾期以「今天零点」为界（今天到期不算逾期，与列表置顶口径同源）；
 * - 停滞 = updated_at 距今超 [REVIEW_STALL_DAYS] 天。
 */
import { type TodoTaskListItem } from "@/lib/tauri";

/** 停滞阈值：超过该天数未更新即列入唤醒候选 */
export const REVIEW_STALL_DAYS = 7;

/** 周回顾三组清单 */
export interface WeeklyReviewBuckets {
  /** 逾期未完成（需处置：顺延/改期/放弃） */
  overdue: TodoTaskListItem[];
  /** 无截止日的未完成（需处置：排期/清出清单） */
  undated: TodoTaskListItem[];
  /** 停滞未完成（需唤醒：最近动过或关闭） */
  stalled: TodoTaskListItem[];
}

/** 本地今日零点（毫秒）；与 capacity/task-filters 同口径 */
function localDayStartMs(nowMs: number): number {
  const d = new Date(nowMs);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 归集周回顾三组清单（详见模块头口径） */
export function collectWeeklyReview(
  tasks: TodoTaskListItem[],
  nowMs = Date.now(),
): WeeklyReviewBuckets {
  const dayStart = localDayStartMs(nowMs);
  const stallCutoff = nowMs - REVIEW_STALL_DAYS * 86_400_000;

  const overdue: TodoTaskListItem[] = [];
  const undated: TodoTaskListItem[] = [];
  const stalled: TodoTaskListItem[] = [];

  for (const t of tasks) {
    if (t.done) continue;
    if (t.due_date != null && t.due_date < dayStart) overdue.push(t);
    if (t.due_date == null) undated.push(t);
    if (t.updated_at < stallCutoff) stalled.push(t);
  }
  return { overdue, undated, stalled };
}
