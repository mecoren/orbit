/**
 * 批量任务写操作（07 报告 §五-P2#17：多选批量）
 *
 * 策略：顺序逐条提交（本地 SQLite 单连接，并发 invoke 无收益且易触碰
 * 同步层写放大）；条目级失败不中断——收集失败数继续后续条目，让调用方
 * 按「部分成功」口径提示（N 条中 M 条失败），已成功条目不回滚。
 */
import { toast } from "sonner";
import {
  todoTaskUpdate,
  todoTaskUpdatePosition,
  type TodoTask,
  type TodoTaskUpdateInput,
} from "@/lib/tauri";
import { midpoint } from "./position";

/** 逐条更新；返回失败条数。部分失败弹 warning（措辞由调用方语境补足） */
export async function batchUpdate(
  tasks: TodoTask[],
  makeInput: (t: TodoTask) => TodoTaskUpdateInput,
  failureHint: string,
): Promise<number> {
  let failed = 0;
  for (const t of tasks) {
    try {
      await todoTaskUpdate(t.id, makeInput(t));
    } catch (e) {
      failed++;
      console.error(`批量更新任务 ${t.id} 失败:`, e);
    }
  }
  if (failed > 0) {
    toast.warning(`${failureHint}：${tasks.length} 条中 ${failed} 条失败`);
  }
  return failed;
}

/** 批量完成（done=1+done_at=now+status="done"，与 completeTask 单条口径一致；
 *  重复任务不在此展开下一实例——批量场景保持轻量，用户可对个别重复任务
 *  单条完成触发） */
export function batchUpdateStatus(tasks: TodoTask[], input: TodoTaskUpdateInput): Promise<number> {
  return batchUpdate(tasks, () => ({ ...input }), "批量更新状态");
}

export function batchUpdatePriority(tasks: TodoTask[], priority: number): Promise<number> {
  return batchUpdate(tasks, () => ({ priority }), "批量设置优先级");
}

export function batchUpdateFavorite(tasks: TodoTask[], favorite: boolean): Promise<number> {
  return batchUpdate(tasks, () => ({ is_favorite: favorite ? 1 : 0 }), "批量更新收藏");
}

/** 批量移动项目：project_id 变更 + position 置于目标项目现有任务尾位之后
 *  （取中值保证不与既有 position 冲突，03 文档 §一排序口径）。 */
export async function batchMoveToProject(
  tasks: TodoTask[],
  projectId: number | null,
  allTasks: TodoTask[],
): Promise<void> {
  const others = allTasks.filter(
    (t) => t.project_id === projectId && !tasks.some((s) => s.id === t.id),
  );
  const maxPos = others.reduce((m, t) => Math.max(m, t.position), 0);
  let failed = 0;
  for (const t of tasks) {
    try {
      await todoTaskUpdate(t.id, { project_id: projectId });
      await todoTaskUpdatePosition(t.id, midpoint(maxPos));
    } catch (e) {
      failed++;
      console.error(`批量移动任务 ${t.id} 到项目失败:`, e);
    }
  }
  if (failed > 0) {
    toast.warning(`批量移动项目：${tasks.length} 条中 ${failed} 条失败`);
  }
}
