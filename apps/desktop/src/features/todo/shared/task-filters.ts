/**
 * 待办任务共享过滤/排序逻辑（M4 Task 10，从 desktop/list-page.tsx 原样搬移）
 *
 * 语义（04 §四）：互斥目标 ungrouped > projectId > quickView；
 * 快捷视图与状态/优先级筛选仅在非项目目标下生效；
 * 排序默认 position 升序 → created_at 降序（sortKey 可切截止/优先级/标题/创建时间，
 * 07 backlog #26 双端排序选项；非默认档下手动拖拽排序把手由 UI 隐藏）。
 */
import { type TodoTask } from "@/lib/tauri";
import { type QuickViewKey } from "./constants";

export type TaskStatusFilter = "all" | "pending" | "doing" | "done" | "undone";

/** 排序档位（manual = position 拖拽顺序，唯一允许拖拽重排的档位） */
export type TaskSortKey = "manual" | "due" | "priority" | "title" | "created";

export interface TaskFilterInput {
  quickView?: QuickViewKey | null;
  projectId?: number | null;
  ungrouped?: boolean;
  keyword?: string | null; // title+description 大小写不敏感包含
  statusFilter?: TaskStatusFilter;
  priorityFilter?: number | null;
  /** 隐藏已完成（Logbook 治理）：true 时剔除 done 任务；
   *  quickView=done / statusFilter=done 已完成语义下不生效（要看完成集就明确去 done 入口） */
  hideDone?: boolean;
}

/** 「今天」本地零点毫秒（我的一天判定/写入单一口径：
 *  列表/表格/详情/右键菜单/本文件过滤共五处，收编防口径漂移） */
export function todayStartMs(now = new Date()): number {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 我的一天切换写值：在「我的一天」→ 移出（null），否则 → 加入（今天零点）。
 *  判定基准与写入值同口径，杜绝「写入 Date.now() 当天即失效且无法移出」类 bug */
export function toggleMyDayValue(myDayDate: number | null, now = new Date()): number | null {
  const today = todayStartMs(now);
  return myDayDate === today ? null : today;
}

export function filterTasks(tasks: TodoTask[], input: TaskFilterInput): TodoTask[] {
  const {
    quickView = null,
    projectId = null,
    ungrouped = false,
    keyword = null,
    statusFilter = "all",
    priorityFilter = null,
    hideDone = false,
  } = input;

  let list = tasks;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayEnd = todayStart.getTime() + 24 * 3600 * 1000;
  const weekEnd = todayEnd + 6 * 24 * 3600 * 1000;

  if (ungrouped) {
    list = list.filter((t) => t.project_id == null);
  } else if (projectId != null) {
    list = list.filter((t) => t.project_id === projectId);
  } else {
    switch (quickView) {
      case "undone":
        list = list.filter((t) => !t.done);
        break;
      case "done":
        list = list.filter((t) => !!t.done);
        break;
      case "today":
        // 今天 = 逾期 + 今日到期（截止 < 明日零点即命中）：逾期未完成仍是
        // 「今天要做的事」，与移动端 today 视图同口径；task-list-view 的
        // 逾期置顶段自然承接渲染
        list = list.filter((t) => t.due_date != null && t.due_date < todayEnd);
        break;
      case "week":
        // 近 7 天 = 逾期 + 未来 7 天到期（同口径去掉下界）
        list = list.filter((t) => t.due_date != null && t.due_date < weekEnd);
        break;
      case "favorite":
        list = list.filter((t) => !!t.is_favorite);
        break;
      case "my_day":
        // 我的一天：只显示「今天」加入的（my_day_date == 今天零点）。
        // 昨天加入未完成的任务自动退出视图（回到原项目可再次加入）——
        // 与微软 To Do 的 My Day 语义一致，数据不删。
        list = list.filter((t) => t.my_day_date === todayStart.getTime());
        break;
      default:
        break;
    }

    // 快捷视图下的状态筛选仍生效；项目视图沿用现版无工具栏语义
    if (statusFilter === "undone") list = list.filter((t) => !t.done);
    if (statusFilter === "pending") list = list.filter((t) => t.status === "pending");
    if (statusFilter === "doing") list = list.filter((t) => t.status === "doing");
    if (statusFilter === "done") list = list.filter((t) => !!t.done || t.status === "done");
    if (priorityFilter != null) {
      list = list.filter((t) => t.priority === priorityFilter);
    }
  }

  // 隐藏已完成（Logbook 治理）：done 快捷视图 / done 状态筛选是明确要看完成集的入口，
  // 此处不剔除（否则开关会把它们清成永久空列表）
  if (hideDone && quickView !== "done" && statusFilter !== "done") {
    list = list.filter((t) => !t.done);
  }

  const kw = keyword?.trim().toLowerCase() ?? "";
  if (kw) {
    list = list.filter(
      (t) =>
        t.title.toLowerCase().includes(kw) ||
        (t.description ?? "").toLowerCase().includes(kw),
    );
  }

  return list;
}

export function sortTasks(tasks: TodoTask[], sortKey: TaskSortKey = "manual"): TodoTask[] {
  const list = [...tasks];
  switch (sortKey) {
    case "due":
      // 无截止排最后，有截止按时间升序（同值落回创建时间降序）
      return list.sort((a, b) => {
        if (a.due_date == null && b.due_date == null) return b.created_at - a.created_at;
        if (a.due_date == null) return 1;
        if (b.due_date == null) return -1;
        if (a.due_date !== b.due_date) return a.due_date - b.due_date;
        return b.created_at - a.created_at;
      });
    case "priority":
      // 优先级大者排前（同值落回拖拽顺序）
      return list.sort((a, b) => {
        if (a.priority !== b.priority) return b.priority - a.priority;
        const pa = a.position ?? 0;
        const pb = b.position ?? 0;
        return pa !== pb ? pa - pb : b.created_at - a.created_at;
      });
    case "title":
      // 标题 localeCompare 升序（中文拼音序）
      return list.sort((a, b) => a.title.localeCompare(b.title, "zh-Hans-CN"));
    case "created":
      // 创建时间降序（最新在前）
      return list.sort((a, b) => b.created_at - a.created_at);
    default:
      return list.sort((a, b) => {
        const pa = a.position ?? 0;
        const pb = b.position ?? 0;
        if (pa !== pb) return pa - pb;
        return b.created_at - a.created_at;
      });
  }
}

/**
 * 逾期置顶分组（性能批次 UX 优化）：未完成且截止时间已过的任务
 * 划入「逾期」区置顶展示，其余落「其余任务」区——Todoist/MS To Do
 * 同款信息层级，逾期项永远先被看见。
 *
 * 判定口径与 task-list-view 行内 overdue 一致：due_date < now 且 !done。
 * 仅在存在逾期任务时分组（无逾期时 second 为全量、避免空区块噪音）；
 * 拖拽重排语义不受影响（逾期区/普通区各自内部维持原顺序，跨区拖拽
 * 依旧按 position 中值落位——dnd 事件照常走 tasks 原数组索引）。
 */
export function groupOverdueFirst(
  tasks: TodoTask[],
  now = Date.now(),
): { overdue: TodoTask[]; rest: TodoTask[] } {
  const overdue: TodoTask[] = [];
  const rest: TodoTask[] = [];
  for (const t of tasks) {
    if (!t.done && t.due_date != null && t.due_date < now) overdue.push(t);
    else rest.push(t);
  }
  return { overdue, rest };
}

/** Logbook 按完成日分组单元（Things Logbook：完成历史按日聚合回看） */
export interface DoneDayGroup {
  /** 本地 YYYY-MM-DD */
  key: string;
  date: Date;
  tasks: TodoTask[];
}

/**
 * 已完成任务按完成日（done_at 本地日）倒序分组——Logbook 视图数据源
 * （Things Logbook 同款「完成历史」语义：最近的成就排最前）。
 *
 * 分组口径：done_at 归本地自然日（本地时区日界，与统计热力图一致）；
 * done_at 缺失的脏行兜底落 created_at 日、再缺失落传入的 fallbackToday。
 * 组间倒序（今天在最上）；组内按 done_at 倒序（同日晚完成的排前）。
 */
export function groupDoneByDay(
  tasks: TodoTask[],
  fallbackToday = new Date(),
): DoneDayGroup[] {
  const byKey = new Map<string, DoneDayGroup>();
  for (const t of tasks) {
    const ts = t.done_at ?? t.created_at ?? fallbackToday.getTime();
    const d = new Date(ts);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    let g = byKey.get(key);
    if (!g) {
      g = { key, date: new Date(d.getFullYear(), d.getMonth(), d.getDate()), tasks: [] };
      byKey.set(key, g);
    }
    g.tasks.push(t);
  }
  const groups = [...byKey.values()];
  groups.sort((a, b) => b.date.getTime() - a.date.getTime());
  for (const g of groups) {
    g.tasks.sort((a, b) => (b.done_at ?? b.created_at ?? 0) - (a.done_at ?? a.created_at ?? 0));
  }
  return groups;
}

// ---------- 四象限分组（Eisenhower Matrix，对标 TickTick 矩阵视图） ----------

/** 四象限桶位（展示顺序即枚举序：先重要后次要，先紧急后不紧急） */
export type EisenhowerQuadrant =
  | "urgentImportant"
  | "importantNotUrgent"
  | "urgentNotImportant"
  | "neither";

/** 四象限展示元数据：行动短语 + 轴文案（格头两行；象限识别色走 Tailwind
 *  语义类，见 matrix-view 的 QUADRANT_TINT——不新增色值） */
export const EISENHOWER_META: Record<
  EisenhowerQuadrant,
  { action: string; axis: string }
> = {
  urgentImportant: { action: "立即做", axis: "紧急 · 重要" },
  importantNotUrgent: { action: "计划做", axis: "不紧急 · 重要" },
  urgentNotImportant: { action: "抽空做", axis: "紧急 · 不重要" },
  neither: { action: "可延后", axis: "不紧急 · 不重要" },
};

/** 四象限分组结果（四键恒在，空桶也要渲染格） */
export type EisenhowerBuckets = Record<EisenhowerQuadrant, TodoTask[]>;

/**
 * 四象限分组纯函数：已完成不入桶（矩阵只承载未完成工作集，完成历史
 * 交给侧栏「已完成」入口）。轴口径与移动端 groupEisenhower 逐字对齐——
 * 重要 = 优先级 ≥ 高(3)；紧急 = 截止在今天 24:00 之前（含逾期，本地时区
 * 日界）。[now] 供测试注入固定时间。组内保持入参顺序（排序在调用方做）。
 */
export function groupEisenhower(
  tasks: TodoTask[],
  now = new Date(),
): EisenhowerBuckets {
  const dayEnd = new Date(now);
  dayEnd.setHours(24, 0, 0, 0);
  const buckets: EisenhowerBuckets = {
    urgentImportant: [],
    importantNotUrgent: [],
    urgentNotImportant: [],
    neither: [],
  };
  for (const t of tasks) {
    if (t.done) continue;
    const urgent = t.due_date != null && t.due_date < dayEnd.getTime();
    const important = t.priority >= 3;
    const q: EisenhowerQuadrant = urgent
      ? important
        ? "urgentImportant"
        : "urgentNotImportant"
      : important
        ? "importantNotUrgent"
        : "neither";
    buckets[q].push(t);
  }
  return buckets;
}
