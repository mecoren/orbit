/**
 * 任务操作共享助手（M4 Task 12）
 *
 * 勾选语义与桌面完全对齐（desktop/task-detail-drawer.tsx / task-list-view.tsx /
 * task-context-menu.tsx 三处同款）：完成写 done=1 + done_at=now + status="done"；
 * 取消一律回 status="pending"（不做 doing 记忆，桌面无此语义）并清空 done_at。
 */
import { type TodoTask, type TodoTaskUpdateInput } from "@/lib/tauri";

/** 勾选/取消勾选 → todoTaskUpdate 的增量输入片段 */
export function applyDoneToggle(task: TodoTask): Partial<TodoTaskUpdateInput> {
  return task.done
    ? { done: 0, done_at: null, status: "pending" }
    : { done: 1, done_at: Date.now(), status: "done" };
}
