// apps/desktop/src/features/todo/shared/template-apply.ts
/**
 * 任务模板套用预填（纯函数）——payload JSON → 新增表单初始字段
 *
 * 模板 payload 键（与 Rust ALLOWED_PAYLOAD_KEYS 同口径）：
 * - title / notes / priority / due_offset_days / subtasks
 * 套用语义：按存在键预填（缺键 = 不预填，保持表单默认）；
 * due_offset_days 以套用当天为基准偏移（0=今天）。
 * 优先级/截止与视图默认（#39）的合并顺序：模板 > 日历右键 > 视图默认 ——
 * 模板是用户显式选择，语义最强。
 */
import { formatYmd } from "./lunar";

export interface TemplatePayload {
  title?: string;
  notes?: string;
  priority?: number;
  due_offset_days?: number;
  subtasks?: string[];
}

/** 解析模板 payload JSON；非法/超纲键时返回 null（套用侧静默跳过该键） */
export function parseTemplatePayload(payload: string): TemplatePayload | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  const obj = parsed as Record<string, unknown>;
  const out: TemplatePayload = {};
  if (typeof obj.title === "string" && obj.title.trim()) out.title = obj.title;
  if (typeof obj.notes === "string") out.notes = obj.notes;
  if (typeof obj.priority === "number") out.priority = obj.priority;
  if (typeof obj.due_offset_days === "number") {
    out.due_offset_days = obj.due_offset_days;
  }
  if (Array.isArray(obj.subtasks) && obj.subtasks.every((s) => typeof s === "string")) {
    out.subtasks = obj.subtasks as string[];
  }
  return out;
}

/** 截止偏移 → YYYY-MM-DD（套用当天 + N 天；本地时区日界） */
export function templateDueDate(offsetDays: number): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return formatYmd(d);
}
