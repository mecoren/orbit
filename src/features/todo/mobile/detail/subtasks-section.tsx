/**
 * SubtasksSection —— 详情子任务区（05 §4.3 后半；M4 Task 14）
 *
 * 头副标题 doneCount/total(bodySmall)；行 = 22×22 圆 checkbox(border2，
 * 完成填 accent #3B82F6 + check14 白) + 标题 15px(完成 lineThrough + sub@50%) +
 * close(18) 删除（无确认直删——对齐桌面 SubtasksSection 行为，桌面亦无撤销）；
 * 新增 = TextField(hint 子任务标题, autofocus, onSubmitted) + check_rounded 提交钮；
 * 收起态 TextButton.icon(add_rounded 20,"添加子任务")。
 *
 * 失效约定：每次变更（增/勾选/删）后 todoTaskRecalcPercent 回算 percent_done，
 * 再经父级 refreshDetail 统一失效（禁 setQueryData 局部合并）。
 */
import { useState } from "react";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoSubtaskCreate,
  todoSubtaskDelete,
  todoSubtaskToggleDone,
  todoTaskRecalcPercent,
  type TodoTaskDetail,
} from "@/lib/tauri";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

interface SubtasksSectionProps {
  task: TodoTaskDetail;
  /** 统一失效出口：["todo-task-detail", id] + ["todo_tasks"]（detail-screen 下发） */
  refreshDetail: () => Promise<void>;
}

export function SubtasksSection({ task, refreshDetail }: SubtasksSectionProps) {
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");

  const doneCount = task.subtasks.filter((s) => s.done).length;

  /** 变更统一出口：落库 → 回算 percent_done → 统一失效 */
  const mutate = async (action: () => Promise<unknown>) => {
    try {
      await action();
      await todoTaskRecalcPercent(task.id);
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  const submit = async () => {
    const v = draft.trim();
    if (!v) return;
    setDraft("");
    await mutate(() => todoSubtaskCreate({ task_id: task.id, title: v }));
  };

  const collapse = () => {
    setDraft("");
    setAdding(false);
  };

  return (
    <SectionCard title="子任务" subtitle={`${doneCount}/${task.subtasks.length}`}>
      <div className="space-y-1">
        {task.subtasks.map((s) => (
          <div key={s.id} className="flex items-center gap-2 py-0.5">
            {/* 22×22 圆 checkbox：完成填 accent + check14 白（05 §4.3） */}
            <button
              type="button"
              aria-label={s.done ? "标记未完成" : "标记完成"}
              className="grid h-[22px] w-[22px] shrink-0 place-items-center rounded-full border-2 transition-colors"
              style={{
                borderColor: s.done ? TODO_ACCENT : "var(--m-sub)",
                opacity: s.done ? undefined : 0.4,
                background: s.done ? TODO_ACCENT : "transparent",
              }}
              onClick={() => void mutate(() => todoSubtaskToggleDone(s.id, !s.done))}
            >
              {s.done ? <MaterialIcon name="check" size={14} color="#FFFFFF" /> : null}
            </button>

            <span
              className={`min-w-0 flex-1 break-words text-[15px] ${s.done ? "line-through" : ""}`}
              style={{ color: s.done ? "var(--m-sub)" : "var(--m-text)", opacity: s.done ? 0.5 : undefined }}
            >
              {s.title}
            </span>

            {/* close(18) 删除：无确认直删（对齐桌面） */}
            <button
              type="button"
              aria-label="删除子任务"
              className="shrink-0 active:opacity-60"
              onClick={() => void mutate(() => todoSubtaskDelete(s.id))}
            >
              <MaterialIcon name="close" size={18} color="var(--m-sub)" />
            </button>
          </div>
        ))}

        {adding ? (
          /* 展开态：TextField(hint, autofocus, onSubmitted) + check_rounded 提交钮 */
          <div className="flex items-center gap-2 pt-1">
            <input
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  void submit();
                } else if (e.key === "Escape") {
                  collapse();
                }
              }}
              placeholder="子任务标题"
              className="min-w-0 flex-1 border-b border-black/[.12] bg-transparent py-1 text-[15px] text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] focus:border-[#3B82F6] dark:border-white/[.12]"
            />
            <button
              type="button"
              aria-label="提交子任务"
              disabled={!draft.trim()}
              className="grid h-8 w-8 shrink-0 place-items-center disabled:opacity-30 active:opacity-60"
              onClick={() => void submit()}
            >
              <MaterialIcon name="check_rounded" size={22} color={TODO_ACCENT} />
            </button>
          </div>
        ) : (
          /* 收起态：TextButton.icon(add_rounded 20,"添加子任务") */
          <button
            type="button"
            onClick={() => setAdding(true)}
            className="-ml-2 flex items-center gap-1 rounded-lg px-2 py-1.5 text-sm font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
            style={{ color: TODO_ACCENT }}
          >
            <MaterialIcon name="add_rounded" size={20} />
            添加子任务
          </button>
        )}
      </div>
    </SectionCard>
  );
}
