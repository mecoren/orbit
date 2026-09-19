/**
 * 批量任务写操作（07 报告 §五-P2#17：多选批量）
 *
 * 策略：顺序逐条提交（本地 SQLite 单连接，并发 invoke 无收益且易触碰
 * 同步层写放大）；条目级失败不中断——收集失败数继续后续条目，让调用方
 * 按「部分成功」口径提示（N 条中 M 条失败），已成功条目不回滚。
 */
import { toast } from "sonner";
import { type QueryClient } from "@tanstack/react-query";
import {
  todoTaskComplete,
  todoTaskUpdate,
  todoTaskUpdatePosition,
  todoTaskDelete,
  type TodoTask,
  type TodoTaskUpdateInput,
} from "@/lib/tauri";
import { patchQueriesData } from "@/lib/query-patch";
import { midpoint } from "./position";
import { rescheduleDue } from "./reschedule-due";
import { pushUndo } from "./undo-bridge";

/** 逐条更新；返回失败条数。部分成功弹 warning（措辞由调用方语境补足） */
export async function batchUpdate(
  tasks: TodoTask[],
  makeInput: (t: TodoTask) => TodoTaskUpdateInput,
  failureHint: string,
  qc?: QueryClient,
): Promise<number> {
  // 乐观（D5）：循环前一次性 patch 全部目标行，失败 id 精确回滚
  // （旧口径是整表 invalidate +「已完成的条目不回滚」的粗口径）。
  const plans = tasks.map((t) => ({ task: t, input: makeInput(t) }));
  if (qc) {
    for (const { task: t, input } of plans) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], input);
    }
  }
  let failed = 0;
  for (const { task: t, input } of plans) {
    try {
      await todoTaskUpdate(t.id, input);
    } catch (e) {
      failed++;
      console.error(`批量更新任务 ${t.id} 失败:`, e);
      if (qc) {
        // 精确回滚：把该行本次写入的键位恢复为传入快照
        const rollback = Object.fromEntries(
          Object.keys(input).map((k) => [k, (t as unknown as Record<string, unknown>)[k]]),
        ) as Partial<TodoTask>;
        patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], rollback);
      }
    }
  }
  if (failed > 0) {
    toast.warning(`${failureHint}：${tasks.length} 条中 ${failed} 条失败`);
  }
  return failed;
}

/** 批量完成：逐条走统一完成命令（与单条 completeTask 同一 Rust 入口，
 *  重复任务在单事务内推进下一实例——引擎下沉后批量与单条口径一致）；
 *  取消完成/状态切换仍走普通 update。撤销入口（A5）：恢复 done/status
 *  + 软删引擎克隆的下一实例。 */
export async function batchUpdateStatus(
  tasks: TodoTask[],
  input: TodoTaskUpdateInput,
  qc?: QueryClient,
): Promise<number> {
  const markingDone = input.done === 1;
  if (!markingDone) {
    const failed = await batchUpdate(tasks, () => ({ ...input }), "批量更新状态", qc);
    if (failed < tasks.length) {
      pushUndo({
        label: "批量更新状态",
        count: tasks.length,
        undo: async () => {
          await Promise.allSettled(
            tasks.map((t) => todoTaskUpdate(t.id, { done: t.done, done_at: t.done_at, status: t.status })),
          );
        },
      });
    }
    return failed;
  }
  // 批量完成乐观：先全翻 done，失败 id 精确回滚；克隆实例不追加（D4 同理）
  const targets = tasks.filter((t) => !t.done);
  if (qc) {
    for (const t of targets) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], {
        done: 1,
        done_at: Date.now(),
        status: "done",
      });
    }
  }
  let failed = 0;
  const clones: number[] = []; // 引擎克隆的下一实例 id（撤销时软删）
  for (const t of tasks) {
    if (t.done) continue; // 已完成条目跳过（幂等，不重复推进）
    try {
      const res = await todoTaskComplete(t.id);
      if (res.next_instance) clones.push(res.next_instance.id);
      if (qc && res.task) {
        patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], {
          done: res.task.done,
          done_at: res.task.done_at,
          status: res.task.status,
        });
      }
    } catch (e) {
      failed++;
      console.error(`批量完成任务 ${t.id} 失败:`, e);
      if (qc) {
        patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], {
          done: t.done,
          done_at: t.done_at,
          status: t.status,
        });
      }
    }
  }
  if (failed > 0) {
    toast.warning(`批量更新状态：${tasks.length} 条中 ${failed} 条失败`);
  }
  const completed = tasks.filter((t) => !t.done);
  if (completed.length > failed) {
    pushUndo({
      label: "批量完成任务",
      count: completed.length,
      undo: async () => {
        await Promise.allSettled(
          completed.map((t) => todoTaskUpdate(t.id, { done: 0, done_at: null, status: "pending" })),
        );
        await Promise.allSettled(clones.map((id) => todoTaskDelete(id)));
      },
    });
  }
  return failed;
}

export async function batchUpdatePriority(tasks: TodoTask[], priority: number, qc?: QueryClient): Promise<number> {
  const failed = await batchUpdate(tasks, () => ({ priority }), "批量设置优先级", qc);
  if (failed < tasks.length) {
    pushUndo({
      label: "批量设置优先级",
      count: tasks.length,
      undo: async () => {
        await Promise.allSettled(tasks.map((t) => todoTaskUpdate(t.id, { priority: t.priority })));
      },
    });
  }
  return failed;
}

export async function batchUpdateFavorite(tasks: TodoTask[], favorite: boolean, qc?: QueryClient): Promise<number> {
  const failed = await batchUpdate(tasks, () => ({ is_favorite: favorite ? 1 : 0 }), "批量更新收藏", qc);
  if (failed < tasks.length) {
    pushUndo({
      label: "批量更新收藏",
      count: tasks.length,
      undo: async () => {
        await Promise.allSettled(tasks.map((t) => todoTaskUpdate(t.id, { is_favorite: t.is_favorite })));
      },
    });
  }
  return failed;
}

/** 批量加入/移出我的一天：加入写「今天本地零点」，移出写 null（视图按日判断） */
export async function batchUpdateMyDay(tasks: TodoTask[], join: boolean, qc?: QueryClient): Promise<number> {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const failed = await batchUpdate(
    tasks,
    () => ({ my_day_date: join ? today.getTime() : null }),
    join ? "批量加入我的一天" : "批量移出我的一天",
    qc,
  );
  if (failed < tasks.length) {
    pushUndo({
      label: join ? "批量加入我的一天" : "批量移出我的一天",
      count: tasks.length,
      undo: async () => {
        await Promise.allSettled(tasks.map((t) => todoTaskUpdate(t.id, { my_day_date: t.my_day_date ?? null })));
      },
    });
  }
  return failed;
}

/** 批量移动项目：project_id 变更 + position 置于目标项目现有任务尾位之后
 *  （取中值保证不与既有 position 冲突，03 文档 §一排序口径）。
 *  撤销入口（A5）：恢复原 project_id + 原 position 双字段。 */
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
  const moved: TodoTask[] = [];
  for (const t of tasks) {
    try {
      await todoTaskUpdate(t.id, { project_id: projectId });
      await todoTaskUpdatePosition(t.id, midpoint(maxPos));
      moved.push(t);
    } catch (e) {
      failed++;
      console.error(`批量移动任务 ${t.id} 到项目失败:`, e);
    }
  }
  if (failed > 0) {
    toast.warning(`批量移动项目：${tasks.length} 条中 ${failed} 条失败`);
  }
  if (moved.length > 0) {
    pushUndo({
      label: "批量移动项目",
      count: moved.length,
      undo: async () => {
        await Promise.allSettled([
          ...moved.map((t) => todoTaskUpdate(t.id, { project_id: t.project_id })),
          ...moved.map((t) => todoTaskUpdatePosition(t.id, t.position)),
        ]);
      },
    });
  }
}

/** 批量改期目标档位（多选工具条下拉点选即执行；对齐 Linear 批量整理口径） */
export type BatchDuePreset = "today" | "tomorrow" | "next_monday" | "clear";

/** 档位 → 目标日（本地时区；clear 传 null 清除截止） */
export function batchDuePresetDate(preset: BatchDuePreset, now = new Date()): Date | null {
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  switch (preset) {
    case "today":
      return day;
    case "tomorrow":
      return new Date(day.getTime() + 24 * 3600_000);
    case "next_monday": {
      // 周一起始周（与周视图同口径）：周一~周日都锚下一周一
      const offset = (8 - day.getDay()) % 7 || 7;
      return new Date(day.getTime() + offset * 24 * 3600_000);
    }
    case "clear":
      return null;
  }
}

/** 批量改期：按档位换日期。时间语义对齐 rescheduleDue——原截止保留
 *  时分秒（零点/无截止 → 18:00 归一口径）；clear 档写 null 清除截止。
 *  撤销：恢复原 due_date。 */
export async function batchSetDueDate(
  tasks: TodoTask[],
  preset: BatchDuePreset,
  qc?: QueryClient,
): Promise<number> {
  const target = batchDuePresetDate(preset);
  // 先纯算出每行的目标值（跳过幂等行），再一次性乐观 patch
  const plans: { task: TodoTask; next: number | null }[] = [];
  for (const t of tasks) {
    let next: number | null;
    if (target == null) {
      if (t.due_date == null) continue; // 已无截止，幂等跳过
      next = null;
    } else {
      next = rescheduleDue(t.due_date, target);
      if (next == null) continue; // 同日档位无变化，跳过写库
    }
    plans.push({ task: t, next });
  }
  if (qc) {
    for (const { task: t, next } of plans) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], { due_date: next });
    }
  }
  let failed = 0;
  const changed: TodoTask[] = [];
  const newDueById = new Map<number, number | null>();
  for (const { task: t, next } of plans) {
    try {
      await todoTaskUpdate(t.id, { due_date: next });
      changed.push(t);
      newDueById.set(t.id, next);
    } catch (e) {
      failed++;
      console.error(`批量改期任务 ${t.id} 失败:`, e);
      if (qc) {
        patchQueriesData<TodoTask>(qc, ["todo_tasks"], [t.id], { due_date: t.due_date });
      }
    }
  }
  if (failed > 0) {
    toast.warning(`批量改期：${tasks.length} 条中 ${failed} 条失败`);
  }
  if (changed.length > 0) {
    pushUndo({
      label: "批量改期",
      count: changed.length,
      undo: async () => {
        await Promise.allSettled(changed.map((t) => todoTaskUpdate(t.id, { due_date: t.due_date })));
      },
    });
  }
  return failed;
}
