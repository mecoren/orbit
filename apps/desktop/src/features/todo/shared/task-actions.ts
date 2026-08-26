/**
 * 任务操作共享助手
 *
 * completeTask — 全应用统一的完成/取消完成编排入口（07 报告 §五-P1#10）：
 * - 取消完成：回 pending 并清 done_at（历史语义不变）。
 * - 普通任务完成：done=1 + done_at=now + status="done"。
 * - 重复任务完成（repeat_mode>0 且有 due_date）：先按规则创建下一实例
 *   （克隆字段 + 平移 start/end + 复制未完成子任务），成功后标记本实例。
 *   create 失败 → 中止完成（宁可没完成，不可丢排程）；create 成功后的
 *   子任务复制失败 → 非致命（warning 提示，继续标记），避免"半生成实例 +
 *   旧实例未标记"的重试双生窗口（评审 I1-a）。最终标记单独捕获（评审 I1-b，
 *   不再静默失败）。in-flight 守卫防双击竞态（评审 I1-c）。
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
    if (task.repeat_mode && task.due_date != null) {
      let plan: ReturnType<typeof planNextRecurringInstance> = null;
      try {
        const detail = await todoTaskGetDetail(task.id);
        plan = planNextRecurringInstance(task, Date.now());
        if (plan) {
          const created = await todoTaskCreate(plan.input);
          let partial = false;
          for (const s of subtasksToClone(detail.subtasks)) {
            try {
              await todoSubtaskCreate({ task_id: created.id, title: s.title, position: s.position });
            } catch (e) {
              partial = true;
              console.error("复制子任务到下一实例失败:", s.title, e);
            }
          }
          if (partial) {
            toast.warning("下一实例已创建，但部分子任务复制失败");
          }
        }
      } catch (e) {
        console.error("生成下一重复实例失败:", e);
        toast.error("生成下一重复实例失败，本次未标记完成");
        return;
      }
    }
    try {
      await todoTaskUpdate(task.id, { done: 1, done_at: Date.now(), status: "done" });
    } catch (e) {
      console.error("标记完成失败:", e);
      toast.error("标记完成失败，请重试");
    }
  } finally {
    completing.delete(task.id);
  }
}
