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
        list = list.filter(
          (t) => t.due_date != null && t.due_date >= todayStart.getTime() && t.due_date < todayEnd,
        );
        break;
      case "week":
        list = list.filter(
          (t) => t.due_date != null && t.due_date >= todayStart.getTime() && t.due_date < weekEnd,
        );
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
