/**
 * 时间块（Timeline）布局纯函数——M9 阶段二（docs/07 #67；对标 TickTick 时间轴）。
 *
 * 口径（与移动端/后续实现共享，改这里必须同步 docs）：
 * 1. 块起点：`start_date` 带时刻 → 用它（用户显式排程最强）；否则 `due_date`
 *    带时刻 → 按截止倒推 `due − 时长`（「该时刻要完成」的块向截止收拢）；
 *    两处都无时刻 → 不渲染时间块（这类任务属于月/周档的日格，不属时段）。
 *    带时刻判定用**本地字段**（时分秒非零），与 formatDueShort 同口径——
 *    本地零点在 UTC+8 下对应前日 16:00 epoch，取模判定会误判。
 * 2. 块长度 = `duration_minutes`（>0）；未设时长给默认 30 分钟最小可视块
 *    （有明确时刻的任务也应在时间轴可见可点）。
 * 3. 块渲染在**起点所在日**列；起止 clamp 到该列 [00:00, 24:00]（视觉截断，
 *    完整起止走 hover title）。跨零点倒推的块贴当日 0 点起渲染。
 * 4. 同列重叠分车道（贪心复用最早空闲车道），车道数由调用方取 max+1。
 */

import type { TodoTask } from "@/lib/tauri";

const MINUTE_MS = 60_000;
export const DAY_MS = 86_400_000;
/** 未设时长任务的默认块长（分钟） */
export const DEFAULT_BLOCK_MINUTES = 30;

/** 时间戳是否带本地非零时刻（纯日期落零点 → false） */
export function hasTimePart(ms: number | null | undefined): boolean {
  if (ms == null) return false;
  const d = new Date(ms);
  return d.getHours() !== 0 || d.getMinutes() !== 0 || d.getSeconds() !== 0 || d.getMilliseconds() !== 0;
}

export interface TaskTimeBlock {
  taskId: number;
  title: string;
  /** 块起点（真实时刻，可能早于所在日 0 点） */
  startMs: number;
  /** 块长（分钟，>0） */
  durationMin: number;
  done: boolean;
  /** 渲染所在列的日 0 点（本地时区） */
  dayStartMs: number;
}

/**
 * 任务 → 时间块；不满足时段口径（无任何带时刻的 start/due）返回 null。
 * 完成任务照常出块（渲染层弱化），口径与日历日格一致。
 */
export function taskTimeBlock(t: TodoTask): TaskTimeBlock | null {
  const durationMin = t.duration_minutes != null && t.duration_minutes > 0 ? t.duration_minutes : DEFAULT_BLOCK_MINUTES;
  let startMs: number | null = null;
  if (hasTimePart(t.start_date)) {
    startMs = t.start_date;
  } else if (hasTimePart(t.due_date)) {
    startMs = t.due_date! - durationMin * MINUTE_MS;
  }
  if (startMs == null) return null;
  const dayStart = new Date(startMs);
  return {
    taskId: t.id,
    title: t.title,
    startMs,
    durationMin,
    done: t.done === 1,
    dayStartMs: new Date(dayStart.getFullYear(), dayStart.getMonth(), dayStart.getDate()).getTime(),
  };
}

export interface BlockLayout {
  /** 块顶相对当日高度的 0-1 比例（clamp 后） */
  topRatio: number;
  /** 块高比例（clamp 到当日 [0,1]，最小可视高度由渲染层保证） */
  heightRatio: number;
}

/** 块在某日的渲染比例：起止 clamp 到该日 [00:00, 24:00] */
export function layoutTimeBlock(block: TaskTimeBlock, dayStartMs: number): BlockLayout {
  const relStart = block.startMs - dayStartMs;
  const relEnd = relStart + block.durationMin * MINUTE_MS;
  const top = Math.min(Math.max(relStart, 0), DAY_MS);
  const bottom = Math.min(Math.max(relEnd, top), DAY_MS);
  return { topRatio: top / DAY_MS, heightRatio: (bottom - top) / DAY_MS };
}

/** 块落在周内第几列（0-6）；周外返回 -1（调用方过滤） */
export function blockDayIndex(block: TaskTimeBlock, weekStartMs: number): number {
  const idx = Math.floor((block.dayStartMs - weekStartMs) / DAY_MS);
  return idx >= 0 && idx <= 6 ? idx : -1;
}

/**
 * 同列重叠分车道：按块顶排序，贪心复用「车道尾早于新块顶」的最早车道。
 * 返回与入参同序的车道号数组；车道总数 = max(车道号) + 1（空输入为 0）。
 */
export function assignLanes(blocks: BlockLayout[]): number[] {
  const laneEnds: number[] = [];
  const order = blocks
    .map((b, i) => ({ i, top: b.topRatio }))
    .sort((a, b) => a.top - b.top);
  const lanes = new Array<number>(blocks.length).fill(0);
  for (const { i, top } of order) {
    let lane = laneEnds.findIndex((end) => end <= top);
    if (lane === -1) {
      lane = laneEnds.length;
      laneEnds.push(top);
    }
    laneEnds[lane] = top + blocks[i].heightRatio;
    lanes[i] = lane;
  }
  return lanes;
}
