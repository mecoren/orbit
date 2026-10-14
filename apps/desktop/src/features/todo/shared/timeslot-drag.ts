/**
 * timeslot-drag — 时间轴时段拖拽/改时长的语义纯函数（docs/07 #73）
 *
 * 时间轴的「肌肉记忆交互」缺口（#68 有意不做）：月格拖圆点改日期已有，
 * 时段只能点开详情改。这里把两种手势收敛成纯函数，组件只负责取指针位移、
 * 渲染预览与落库：
 *
 * 1. **移动**（按住块体竖向拖）：`resolveTimeslotMove` —— 位移先吸附到
 *    `SNAP_MINUTES`（15 分钟）网格，再按横向位移换日（跨列落点）。
 *    **落库不得用 clamp 后的可视值**：`layoutTimeBlock` 会把跨零点块贴顶、
 *    跨午夜块截断，可视位置不是真值；真值一律从 `block.startMs` 反算。
 * 2. **改时长**（拖块底边）：`resolveTimeslotResize` —— 只改长度，起点不动；
 *    长度同样吸附 15 分钟并夹到 `[MIN_SLOT_MINUTES, 1440]`（24h 满格）。
 * 3. **跨列落点**：`dayCount` 内的列间移动允许（TickTick 同款），跨周/跨档
 *    不允许——面板列是固定的 `dayCount` 天，越界位移直接夹回边界列。
 *
 * **倒推块的落库口径**（关键）：块的起点有两种来源（见 time-block.ts 头注释）
 * ——显式 `start_date` 带时刻（用户排的最强意图）与由带时刻 `due_date` 倒推
 * （`due − 时长`，块向截止收拢）。拖动倒推块时**改 `due_date` 而非种
 * `start_date`**：种 start 会让任务从「截止向截止收拢」变成「显式排程」，
 * 语义漂移且与详情页显示打架。`timeslotDropPatch` 是这个口径的唯一出口。
 */

import { addDays, hasTimePart, startOfDay } from "@/lib/date-utils";
import type { TodoTaskListItem } from "@/lib/tauri";
import {
  DAY_MS,
  DEFAULT_BLOCK_MINUTES,
  MINUTE_MS,
  type TaskTimeBlock,
} from "./time-block";

/** 拖拽吸附粒度（分钟）——15 分钟是日程软件的事实标准 */
export const SNAP_MINUTES = 15;
/** 最短时段（分钟）：小于此值块高不足 8px，指针无法稳定再抓 */
export const MIN_SLOT_MINUTES = 15;
/** 最长时段（分钟）：24 小时满格（跨日排程请用多列表达，不靠超长块） */
export const MAX_SLOT_MINUTES = 24 * 60;

/** 纵向像素位移（正 = 向下 = 更晚）→ 吸附后的分钟增量 */
export function snapMinutesDelta(deltaPx: number, hourPx: number): number {
  if (!Number.isFinite(deltaPx) || !Number.isFinite(hourPx) || hourPx <= 0) return 0;
  const raw = (deltaPx / hourPx) * 60;
  return Math.round(raw / SNAP_MINUTES) * SNAP_MINUTES;
}

/** 横向像素位移（正 = 向右 = 更晚的日）→ 列偏移（吸附到整列） */
export function snapDayDelta(
  deltaPx: number,
  columnWidthPx: number,
  dayCount: number,
  fromDayIndex: number,
): number {
  if (
    !Number.isFinite(deltaPx) ||
    !Number.isFinite(columnWidthPx) ||
    columnWidthPx <= 0 ||
    !Number.isInteger(dayCount) ||
    dayCount <= 0
  ) {
    return 0;
  }
  const cols = Math.round(deltaPx / columnWidthPx);
  // 夹在「原列」与「面板边界」之间：跨周/跨档不提供落点
  return Math.min(Math.max(fromDayIndex + cols, 0), dayCount - 1) - fromDayIndex;
}

export interface TimeslotMoveResult {
  /** 新块起点（本地时刻真值） */
  startMs: number;
  /** 落点列的日 0 点 */
  dayStartMs: number;
  /** 落点列序（0 基） */
  dayIndex: number;
  /** 块长不变（移动不改时长；改时长走 resolveTimeslotResize） */
  durationMin: number;
}

/**
 * 移动落点：块 + 指针位移 + 网格几何 → 新起点（已吸附、已夹到落点列内）。
 *
 * 夹取语义：起点不早于落点列 00:00，且 `起点 + 时长 ≤ 落点列 24:00`——
 * 保证块完整落在可视列内（跨日排程由多列表达，不做超长块）。
 */
export function resolveTimeslotMove(
  block: TaskTimeBlock,
  fromDayIndex: number,
  dayCount: number,
  deltaPx: { x: number; y: number },
  grid: { hourPx: number; columnWidthPx: number },
): TimeslotMoveResult {
  const dayDelta = snapDayDelta(deltaPx.x, grid.columnWidthPx, dayCount, fromDayIndex);
  const dayIndex = fromDayIndex + dayDelta;
  // 日偏移用日历日推进（DST 下 epoch 加减 N 天会漂 1 小时）
  const dayStartDate = startOfDay(addDays(new Date(block.startMs), dayDelta));
  const dayStartMs = dayStartDate.getTime();

  // 日内时刻 = 原时刻 + 吸附后的分钟增量（同样走日历日推进保 DST 时钟面）
  const minutes = snapMinutesDelta(deltaPx.y, grid.hourPx);
  const moved = new Date(block.startMs);
  moved.setDate(moved.getDate() + dayDelta);
  if (minutes !== 0) moved.setTime(moved.getTime() + minutes * MINUTE_MS);

  const dayEndMs = dayStartMs + DAY_MS;
  let startMs = moved.getTime();
  if (startMs < dayStartMs) startMs = dayStartMs;
  const latest = dayEndMs - block.durationMin * MINUTE_MS;
  if (startMs > latest) startMs = latest;

  return { startMs, dayStartMs, dayIndex, durationMin: block.durationMin };
}

export interface TimeslotResizeResult {
  /** 块长（分钟，已吸附、已夹边界） */
  durationMin: number;
}

/** 改时长：块底边纵向位移 → 新块长（起点不动） */
export function resolveTimeslotResize(
  block: TaskTimeBlock,
  deltaPx: number,
  hourPx: number,
): TimeslotResizeResult {
  const minutes = snapMinutesDelta(deltaPx, hourPx);
  const raw = block.durationMin + minutes;
  return {
    durationMin: Math.min(Math.max(raw, MIN_SLOT_MINUTES), MAX_SLOT_MINUTES),
  };
}

/** 落库载荷（键与 `todoTaskUpdate` 输入一一对应） */
export interface TimeslotPatch {
  start_date?: number;
  due_date?: number;
  duration_minutes?: number;
}

/**
 * 拖拽结果 → 写库字段。三种块来源各走各的口径（见文件头「倒推块的落库口径」）：
 * - **显式排程**（`start_date` 带时刻）：写 `start_date` + `duration_minutes`；
 * - **截止倒推**（`due_date` 带时刻）：只写 `due_date`（= 起点 + 时长）与
 *   `duration_minutes`——起点与时长的任一变化都要经 due 表达，**不种 start**；
 * - **纯日期任务**（无任何带时刻字段）：不渲染块，拖拽路径到不了这里；
 *   防御起见只落时长，绝不臆造时刻。
 * 无变化（起点与时长都未动）返回 null，调用方直接跳过写库。
 */
export function timeslotDropPatch(
  task: TodoTaskListItem,
  next: { startMs: number; durationMin: number },
): TimeslotPatch | null {
  const explicitStart = hasTimePart(task.start_date);
  const derivedFromDue = !explicitStart && hasTimePart(task.due_date);
  const durationChanged = task.duration_minutes !== next.durationMin;
  const blockStart = taskTimeBlockStartOf(task);
  const startChanged = blockStart == null || blockStart !== next.startMs;

  const patch: TimeslotPatch = {};
  if (durationChanged) patch.duration_minutes = next.durationMin;

  if (derivedFromDue) {
    if (!durationChanged && !startChanged) return null;
    // 起点与时长共同决定 due；时长变了 due 必须跟着平移，否则块起点会跳
    patch.due_date = next.startMs + next.durationMin * MINUTE_MS;
    return patch;
  }
  if (!durationChanged && !startChanged) return null;
  if (explicitStart && startChanged) patch.start_date = next.startMs;
  return Object.keys(patch).length > 0 ? patch : null;
}

/**
 * 任务当前块起点（与 time-block.taskTimeBlock 同口径的轻量版——拖拽路径已
 * 持有块，不必再遍历字段推导；无带时刻的 start/due 返回 null）。
 */
function taskTimeBlockStartOf(task: TodoTaskListItem): number | null {
  const durationMin =
    task.duration_minutes != null && task.duration_minutes > 0
      ? task.duration_minutes
      : DEFAULT_BLOCK_MINUTES;
  if (hasTimePart(task.start_date)) return task.start_date;
  if (hasTimePart(task.due_date)) return task.due_date! - durationMin * MINUTE_MS;
  return null;
}
