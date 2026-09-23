/**
 * 任务操作共享助手
 *
 * completeTask — 全应用统一的完成/取消完成入口（引擎已下沉 orbit-core，
 * 07 报告 §五-P1#10 三端统一）：
 * - 取消完成：回 pending 并清 done_at（历史语义不变，走普通 update）。
 * - 完成：单命令 todo_tasks_complete（Rust 单事务内「创建下一重复实例
 *   （含克隆子任务）+ 标记本实例完成」，原子性取代旧的前端两步 IPC 编排）。
 * 乐观写入口径（D4，AGENTS.md）：先本地翻 done/status/done_at 提前 paint，
 * 再以命令返回值（CompleteTaskResult.task）复算收敛——绝不在 TS 里复刻
 * 重复规则引擎；next_instance 不追加进缓存（它是否出现在当前视图取决于
 * 该视图谓词，客户端复刻谓词就是第二处引擎复刻，且 A5 截断条幅会说谎），
 * 交给 db-change 失效链带出。失败精确回滚到传入快照。
 * in-flight 守卫防双击竞态（评审 I1-c 沿革）。
 */
import { type QueryClient } from "@tanstack/react-query";

import { toast } from "sonner";

import {
  todoTaskComplete,
  todoTaskDelete,
  todoTaskUpdate,
  type TodoTask,
} from "@/lib/tauri";
import { patchQueriesData } from "@/lib/query-patch";
import { formatCnDate } from "./repeat";
import { pushUndo } from "./undo-bridge";

/** 同一任务的完成编排进行中守卫（双击/连点只生效一次） */
const completing = new Set<number>(); // bounded-by-lifecycle: completeTask 的 finally 分支 delete，只存活进行中的写

export async function completeTask(task: TodoTask, qc?: QueryClient): Promise<void> {
  if (completing.has(task.id)) return;
  // 取消完成
  if (task.done) {
    if (qc) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [task.id], {
        done: 0,
        done_at: null,
        status: "pending",
      });
    }
    try {
      await todoTaskUpdate(task.id, { done: 0, done_at: null, status: "pending" });
    } catch (e) {
      if (qc) {
        patchQueriesData<TodoTask>(qc, ["todo_tasks"], [task.id], {
          done: task.done,
          done_at: task.done_at,
          status: task.status,
        });
      }
      throw e;
    }
    pushUndo({
      label: "取消完成",
      undo: async () => {
        await todoTaskUpdate(task.id, { done: 1, done_at: task.done_at, status: "done" });
      },
    });
    return;
  }
  completing.add(task.id);
  // 乐观翻转：首帧即 done，不等 Rust 事务回包
  if (qc) {
    patchQueriesData<TodoTask>(qc, ["todo_tasks"], [task.id], {
      done: 1,
      done_at: Date.now(),
      status: "done",
    });
  }
  try {
    const res = await todoTaskComplete(task.id);
    // 收敛：以服务端真值为准复算（重复实例的 due/position 由引擎定）；
    // next_instance 故意不追加（见文件头），失效链会带出。
    if (qc) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [task.id], {
        done: res.task.done,
        done_at: res.task.done_at,
        status: res.task.status,
      });
    }
    // 重复任务推进提示：明确告知「列表里多出来的那条」从哪来（不然用户茫然）
    if (res.next_instance?.due_date != null) {
      toast.success(`已完成，已生成下一期：${formatCnDate(res.next_instance.due_date)}`);
    }
    pushUndo({
      label: "完成任务",
      undo: async () => {
        await todoTaskUpdate(task.id, { done: 0, done_at: null, status: "pending" });
        // 重复任务完成时引擎克隆了下一实例——撤销时软删克隆，恢复完成前状态
        if (res.next_instance) await todoTaskDelete(res.next_instance.id);
      },
    });
  } catch (e) {
    if (qc) {
      patchQueriesData<TodoTask>(qc, ["todo_tasks"], [task.id], {
        done: task.done,
        done_at: task.done_at,
        status: task.status,
      });
    }
    throw e;
  } finally {
    completing.delete(task.id);
  }
}
