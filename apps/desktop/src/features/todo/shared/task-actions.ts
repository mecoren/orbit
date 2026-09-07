/**
 * 任务操作共享助手
 *
 * completeTask — 全应用统一的完成/取消完成入口（引擎已下沉 orbit-core，
 * 07 报告 §五-P1#10 三端统一）：
 * - 取消完成：回 pending 并清 done_at（历史语义不变，走普通 update）。
 * - 完成：单命令 todo_tasks_complete（Rust 单事务内「创建下一重复实例
 *   （含克隆子任务）+ 标记本实例完成」，原子性取代旧的前端两步 IPC 编排）。
 * UI 刷新依赖 db-change 事件的全量失效（events.ts），此处不做局部缓存操作。
 * in-flight 守卫防双击竞态（评审 I1-c 沿革）。
 */
import {
  todoTaskComplete,
  todoTaskUpdate,
  type TodoTask,
} from "@/lib/tauri";

/** 同一任务的完成编排进行中守卫（双击/连点只生效一次） */
const completing = new Set<number>();

export async function completeTask(task: TodoTask): Promise<void> {
  if (completing.has(task.id)) return;
  // 取消完成
  if (task.done) {
    await todoTaskUpdate(task.id, { done: 0, done_at: null, status: "pending" });
    return;
  }
  completing.add(task.id);
  try {
    await todoTaskComplete(task.id);
  } finally {
    completing.delete(task.id);
  }
}
