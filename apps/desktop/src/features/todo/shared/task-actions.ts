/**
 * 任务操作共享助手
 *
 * completeTask — 全应用统一的完成/取消完成编排入口（07 报告 §五-P1#10）：
 * - 取消完成：回 pending 并清 done_at（历史语义不变）。
 * - 普通任务完成：done=1 + done_at=now + status="done"。
 * - 重复任务完成（repeat_mode>0 且有 due_date）：先按规则创建下一实例
 *   （克隆字段 + 平移 start/end + 复制未完成子任务），成功后才标记本实例；
 *   创建失败则中止并提示——宁可没完成，不可丢排程。
 * UI 刷新依赖 db-change 事件的全量失效（events.ts），此处不做局部缓存操作。
 */
import { toast } from "sonner";
import {
  todoSubtaskCreate,
  todoTaskCreate,
  todoTaskGetDetail,
  todoTaskUpdate,
  type TodoTask,
} from "@/lib/tauri";
import { planNextRecurringInstance, subtasksToClone } from "./repeat-task";

export async function completeTask(task: TodoTask): Promise<void> {
  // 取消完成
  if (task.done) {
    await todoTaskUpdate(task.id, { done: 0, done_at: null, status: "pending" });
    return;
  }
  // 重复任务：先推进下一实例，成功才标记完成
  if (task.repeat_mode && task.due_date != null) {
    try {
      const detail = await todoTaskGetDetail(task.id);
      const plan = planNextRecurringInstance(task, Date.now());
      if (plan) {
        const created = await todoTaskCreate(plan.input);
        for (const s of subtasksToClone(detail.subtasks)) {
          await todoSubtaskCreate({ task_id: created.id, title: s.title, position: s.position });
        }
      }
    } catch {
      toast.error("生成下一重复实例失败，本次未标记完成");
      return;
    }
  }
  await todoTaskUpdate(task.id, { done: 1, done_at: Date.now(), status: "done" });
}
