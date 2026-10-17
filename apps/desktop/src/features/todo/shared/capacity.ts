/**
 * capacity — 今日工作量容量（G4：今天「装得下」多少任务）
 *
 * 品类普遍缺口：My Day 类建议只回答「做什么」，不回答「做得完吗」。本模块
 * 把「今日排程量 vs 每日预算」量化为三档容量判定，供列表/今日视图做超载
 * 预警。纯函数无副作用，双端可镜像。
 *
 * 口径：
 * - 今日排程量 = 今日截止且未完成任务的 duration_minutes 之和（未设/非正
 *   时长不计；逾期任务不计——归 G1 顺延处置面）；
 * - 每日预算 = 用户配置的可用分钟数（null/非正 = 未设，不做超载判定）；
 * - 档位：充足 ok < 80% tight < 100% over（≥100% 即「排满/超出」警示档）。
 */
import { type TodoTaskListItem } from "@/lib/tauri";

/** 默认每日预算：8 小时工作日 */
export const DEFAULT_CAPACITY_MINUTES = 480;

/** 偏紧阈值：≥ 80% 预算即提示「偏紧」 */
const TIGHT_RATIO = 0.8;

/** 容量档位：充足 / 偏紧 / 超载 / 未设（unknown） */
export type CapacityLevel = "ok" | "tight" | "over" | "unknown";

/** 容量判定结果 */
export interface CapacityStatus {
  level: CapacityLevel;
  /** 超出预算的分钟数（仅 over 档为正） */
  overBy: number;
}

/** 本地今日零点（毫秒）；与 task-filters.todayStartMs 同口径 */
function localDayStartMs(nowMs: number): number {
  const d = new Date(nowMs);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * 今日排程量（分钟）：只累计「今日截止（due 落今日窗口）且未完成」的
 * duration_minutes；未设/非正时长跳过。逾期不计（due < 今日零点）。
 */
export function todayLoadMinutes(tasks: TodoTaskListItem[], nowMs = Date.now()): number {
  const dayStart = localDayStartMs(nowMs);
  const dayEnd = dayStart + 86_400_000;
  let sum = 0;
  for (const t of tasks) {
    if (t.done || t.due_date == null) continue;
    if (t.due_date < dayStart || t.due_date >= dayEnd) continue;
    const m = t.duration_minutes ?? 0;
    if (m > 0) sum += m;
  }
  return sum;
}

/**
 * 容量判定：load vs budgetMinutes（null/非正 = 未设预算 → unknown，
 * 只报已排量不做超载判定）。≥100%（含恰好排满）归 over 警示档——
 * 真实日程需要缓冲，排满即风险；overBy 仅在确实超出时为正。
 */
export function capacityStatus(loadMinutes: number, budgetMinutes: number | null): CapacityStatus {
  if (budgetMinutes == null || budgetMinutes <= 0) {
    return { level: "unknown", overBy: 0 };
  }
  const ratio = loadMinutes / budgetMinutes;
  if (loadMinutes >= budgetMinutes) {
    return { level: "over", overBy: Math.max(0, loadMinutes - budgetMinutes) };
  }
  return { level: ratio >= TIGHT_RATIO ? "tight" : "ok", overBy: 0 };
}

/** 分钟 → 短文案（480→"8h"，510→"8h30m"，45→"45m"；负值归 0m） */
export function formatMinutesShort(minutes: number): string {
  const m = Math.max(0, Math.round(minutes));
  const h = Math.floor(m / 60);
  const rest = m % 60;
  if (h === 0) return `${rest}m`;
  return rest === 0 ? `${h}h` : `${h}h${rest}m`;
}

/** 容量提示文案（双端同一措辞单一真相源）：
 *  超载 → 「今日已排 X · 超出 Y」；偏紧/充足 → 「今日已排 X / 预算 Y」；
 *  未设预算 → 只报已排量「今日已排 X」。 */
export function capacityHint(loadMinutes: number, budgetMinutes: number | null): string {
  const load = formatMinutesShort(loadMinutes);
  const status = capacityStatus(loadMinutes, budgetMinutes);
  if (status.level === "unknown") return `今日已排 ${load}`;
  if (status.level === "over") {
    return status.overBy > 0
      ? `今日已排 ${load} · 超出 ${formatMinutesShort(status.overBy)}`
      : `今日已排 ${load} · 已排满`;
  }
  return `今日已排 ${load} / 预算 ${formatMinutesShort(budgetMinutes!)}`;
}
