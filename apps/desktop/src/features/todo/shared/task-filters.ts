/**
 * 待办任务共享过滤/排序逻辑（M4 Task 10，从 desktop/list-page.tsx 原样搬移）
 *
 * 语义（04 §四）：互斥目标 ungrouped > projectId > quickView；
 * 快捷视图与状态/优先级筛选仅在非项目目标下生效；
 * 排序固定 position 升序 → created_at 降序。
 */
import { type TodoTask } from "@/lib/tauri";
import { type QuickViewKey } from "./constants";

export type TaskStatusFilter = "all" | "pending" | "doing" | "done" | "undone";

export interface TaskFilterInput {
  quickView?: QuickViewKey | null;
  projectId?: number | null;
  ungrouped?: boolean;
  keyword?: string | null; // title+description 大小写不敏感包含
  statusFilter?: TaskStatusFilter;
  priorityFilter?: number | null;
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

export function sortTasks(tasks: TodoTask[]): TodoTask[] {
  return [...tasks].sort((a, b) => {
    const pa = a.position ?? 0;
    const pb = b.position ?? 0;
    if (pa !== pb) return pa - pb;
    return b.created_at - a.created_at;
  });
}
