/**
 * 看板分组纯函数（docs/07 #70，对标 TickTick 自定义分组）。
 *
 * 五档：project（按项目）/ status（按状态）/ priority（按优先级）/
 * label（按标签）/ due（按截止日期）。分列 + 归属键 + 跨列落位代表时刻
 * 全部纯函数化（同目录 .test.ts 覆盖），组件只负责渲染与写库。
 *
 * 口径：
 * - project：全部项目各一列（标题排序，空列保留——历史口径）+ 末列未分组；
 *   归档/已删项目的任务回落未分组（与旧内联实现一致）。
 * - status：pending→doing→done 固定三列（含空列）；脏 status 回落待办
 *   （旧实现 `map.get("ungrouped")!` 会抛异常，此处收敛为有效回落）。
 * - priority：P5→P0 固定六列（标题/颜色取 PRIORITY_LABELS/COLOR 全显口径，
 *   与卡片顶部优先级条同源）；脏值回落 P0。
 * - label：有任务的标签各一列（标题排序，空标签列不出——移动端横滑噪音
 *   口径）+ 末列未贴标签；多标签任务按**最小 label id**单归属陈列
 *   （列间无重复卡，拖拽语义 = 换主标签：删源挂目，其余标签不动）。
 * - due：逾期 / 今天 / 本周 / 以后 / 无截止日期五桶（含空桶，状态列同口径）；
 *   done 任务同样按 due 落桶（不单列——看板展示的是可见任务全集）。
 *   跨列拖拽 = 改期到桶代表时刻（见 dueBucketRepresentative），各代表时刻
 *   恒落自家桶（单测按周一~周日逐日锁定），拖后卡片不跳桶。
 */

import { PRIORITY_COLOR, PRIORITY_LABELS, STATUS_COLOR, TODO_ACCENT } from "./constants";
import { startOfDay } from "@/lib/date-utils";
import { atViewDueHour } from "./view-create-defaults";
import type {
  ProjectedTaskLabel,
  TodoProject,
  TodoTask,
} from "@/lib/tauri";

export type KanbanGroupBy = "project" | "status" | "priority" | "label" | "due";

/** 分组中文名（工具栏回显；移动端 KanbanGroupByMeta.label 同源文案） */
export const KANBAN_GROUP_LABEL: Record<KanbanGroupBy, string> = {
  project: "按项目",
  status: "按状态",
  priority: "按优先级",
  label: "按标签",
  due: "按截止日期",
};

export interface KanbanColumnDef {
  key: string;
  title: string;
  color: string;
}

/** 截止分桶 */
export type DueBucket = "overdue" | "today" | "week" | "later" | "none";

export const DUE_BUCKET_META: Record<DueBucket, { title: string; color: string }> = {
  overdue: { title: "逾期", color: PRIORITY_COLOR[4] },
  today: { title: "今天", color: TODO_ACCENT },
  week: { title: "本周", color: PRIORITY_COLOR[3] },
  later: { title: "以后", color: PRIORITY_COLOR[1] },
  none: { title: "无截止日期", color: PRIORITY_COLOR[0] },
};

/** 桶序（分列用，固定展示顺序） */
const DUE_BUCKET_ORDER: DueBucket[] = ["overdue", "today", "week", "later", "none"];

const DAY_MS = 86_400_000;

/**
 * 截止 → 分桶（纯日期口径；与 due_within_days 窗口语义不同源——
 * 此处是互斥五分桶，不是谁的子集）。
 */
export function dueBucketOf(dueMs: number | null | undefined, nowMs = Date.now()): DueBucket {
  if (dueMs == null || !Number.isFinite(dueMs)) return "none";
  const t0 = startOfDay(new Date(nowMs)).getTime();
  if (dueMs < t0) return "overdue";
  if (dueMs < t0 + DAY_MS) return "today";
  if (dueMs < t0 + 7 * DAY_MS) return "week";
  return "later";
}

/**
 * 桶代表时刻（跨列拖拽改期用；null = 清除截止）。
 *
 * 逾期→昨天 18:00 / 今天→今天 18:00（atViewDueHour 口径）/
 * 本周→今天起第 3 天 18:00（恒落本周；刻意不用 weekDefaultDueMs——
 * 周五/周日的代表时刻会落进今天桶，拖后卡片跳桶）/
 * 以后→14 天后 18:00（恒落以后）/ 无日期→null。
 */
export function dueBucketRepresentative(
  bucket: DueBucket,
  nowMs = Date.now(),
): number | null {
  const t0 = startOfDay(new Date(nowMs)).getTime();
  switch (bucket) {
    case "overdue":
      return atViewDueHour(t0 - DAY_MS);
    case "today":
      return atViewDueHour(t0);
    case "week":
      return atViewDueHour(t0 + 3 * DAY_MS);
    case "later":
      return atViewDueHour(t0 + 14 * DAY_MS);
    case "none":
      return null;
  }
}

/** 任务主标签 id（多标签取最小 id；无标签 null） */
export function primaryLabelId(
  labels: ProjectedTaskLabel[] | undefined,
): number | null {
  if (!labels || labels.length === 0) return null;
  let min = labels[0].id;
  for (const l of labels) if (l.id < min) min = l.id;
  return min;
}

/**
 * 分列（列头定义；任务归属见 kanbanColumnKey）。
 *
 * label 档需要「任务→标签」映射（卡片已有 labelsByTask，同源传入）；
 * tasks 仅用于 label 档收集「有任务的标签」集合。
 */
export function kanbanColumns(
  groupBy: KanbanGroupBy,
  projects: TodoProject[],
  labelsByTask: Map<number, ProjectedTaskLabel[]>,
  tasks: TodoTask[],
): KanbanColumnDef[] {
  switch (groupBy) {
    case "status":
      return [
        { key: "pending", title: "待办", color: STATUS_COLOR.pending },
        { key: "doing", title: "进行中", color: STATUS_COLOR.doing },
        { key: "done", title: "已完成", color: STATUS_COLOR.done },
      ];
    case "priority":
      return [5, 4, 3, 2, 1, 0].map((lv) => ({
        key: `pri:${lv}`,
        title: PRIORITY_LABELS[lv] ?? `P${lv}`,
        color: PRIORITY_COLOR[lv] ?? TODO_ACCENT,
      }));
    case "label": {
      const seen = new Map<number, ProjectedTaskLabel>();
      for (const t of tasks) {
        for (const l of labelsByTask.get(t.id) ?? []) {
          if (!seen.has(l.id)) seen.set(l.id, l);
        }
      }
      const cols = [...seen.values()]
        .sort((a, b) => a.title.localeCompare(b.title))
        .map((l) => ({
          key: `lbl:${l.id}`,
          title: l.title,
          color: l.hex_color || TODO_ACCENT,
        }));
      cols.push({ key: "lbl:none", title: "未贴标签", color: TODO_ACCENT });
      return cols;
    }
    case "due":
      return DUE_BUCKET_ORDER.map((b) => ({
        key: `due:${b}`,
        title: DUE_BUCKET_META[b].title,
        color: DUE_BUCKET_META[b].color,
      }));
    case "project":
    default: {
      const cols: KanbanColumnDef[] = [...projects]
        .sort((a, b) => a.title.localeCompare(b.title))
        .map((p) => ({
          key: String(p.id),
          title: p.title,
          color: p.hex_color || TODO_ACCENT,
        }));
      cols.push({ key: "ungrouped", title: "未分组", color: TODO_ACCENT });
      return cols;
    }
  }
}

/** 归属键非法/脏值时的回落列（各档恒有效，旧 status 实现会抛异常） */
export function kanbanFallbackKey(groupBy: KanbanGroupBy): string {
  switch (groupBy) {
    case "status":
      return "pending";
    case "priority":
      return "pri:0";
    case "label":
      return "lbl:none";
    case "due":
      return "due:none";
    case "project":
    default:
      return "ungrouped";
  }
}

/** 任务 → 归属列键（nowMs 仅 due 档用，单测注入固定输入） */
export function kanbanColumnKey(
  groupBy: KanbanGroupBy,
  task: TodoTask,
  labelsByTask: Map<number, ProjectedTaskLabel[]>,
  nowMs = Date.now(),
): string {
  switch (groupBy) {
    case "status":
      return task.status === "doing" || task.status === "done" ? task.status : "pending";
    case "priority":
      return task.priority >= 0 && task.priority <= 5 ? `pri:${task.priority}` : "pri:0";
    case "label": {
      const id = primaryLabelId(labelsByTask.get(task.id));
      return id == null ? "lbl:none" : `lbl:${id}`;
    }
    case "due":
      return `due:${dueBucketOf(task.due_date, nowMs)}`;
    case "project":
    default:
      return task.project_id != null ? String(task.project_id) : "ungrouped";
  }
}
