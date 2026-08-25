/**
 * CommentsSection —— 详情评论区（05 §4.3 后半；M4 Task 14）
 *
 * 行 = 内容 15px + 相对时间 12px/sub（shared/time formatRelativeTime）+
 * delete_outline(18)（删除走 WaitAlertDialog destructive 确认——移动端规格
 * 要求的删除保护，较桌面直删为强约束）；底部输入框(hint 输入评论...) +
 * send_rounded(accent) 提交 todoCommentCreate({task_id,content})。
 *
 * 失效约定：增删均经父级 refreshDetail 统一失效，禁 setQueryData 局部合并。
 */
import { useState } from "react";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { WaitAlertDialog } from "@/components/mobile/wait-alert-dialog";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoCommentCreate,
  todoCommentDelete,
  type TodoTaskDetail,
} from "@/lib/tauri";
import { formatRelativeTime } from "../../shared/time";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

interface CommentsSectionProps {
  task: TodoTaskDetail;
  /** 统一失效出口：["todo-task-detail", id] + ["todo_tasks"] */
  refreshDetail: () => Promise<void>;
}

export function CommentsSection({ task, refreshDetail }: CommentsSectionProps) {
  const [draft, setDraft] = useState("");
  /** 待删除评论 id（destructive 确认弹层挂载锚点） */
  const [pendingDelete, setPendingDelete] = useState<number | null>(null);

  const submit = async () => {
    const v = draft.trim();
    if (!v) return;
    setDraft("");
    try {
      await todoCommentCreate({ task_id: task.id, content: v });
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  const confirmDelete = async () => {
    const id = pendingDelete;
    if (id == null) return;
    try {
      await todoCommentDelete(id);
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  return (
    <SectionCard title="评论">
      <div className="space-y-2">
        {task.comments.map((c) => (
          <div key={c.id} className="rounded-lg bg-black/[.04] p-2.5 dark:bg-white/[.06]">
            <p className="whitespace-pre-wrap break-words text-[15px] leading-snug text-[var(--m-text)]">
              {c.content}
            </p>
            <div className="mt-1 flex items-center gap-2">
              <span className="text-xs text-[var(--m-sub)]">{formatRelativeTime(c.created_at)}</span>
              <div className="flex-1" />
              <button
                type="button"
                aria-label="删除评论"
                className="active:opacity-60"
                onClick={() => setPendingDelete(c.id)}
              >
                <MaterialIcon name="delete_outline" size={18} color="var(--m-sub)" />
              </button>
            </div>
          </div>
        ))}
        {task.comments.length === 0 && (
          <p className="text-[13px]" style={{ color: "var(--m-sub)", opacity: 0.5 }}>
            暂无评论
          </p>
        )}

        {/* 底部输入框(hint 输入评论...) + send_rounded(accent) */}
        <div className="flex items-center gap-1 border-t border-black/[.08] pt-2 dark:border-white/[.08]">
          <input
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void submit();
              }
            }}
            placeholder="输入评论..."
            className="min-w-0 flex-1 bg-transparent py-1 text-[15px] text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)]"
          />
          <button
            type="button"
            aria-label="发送评论"
            disabled={!draft.trim()}
            className="grid h-9 w-9 shrink-0 place-items-center disabled:opacity-30 active:opacity-60"
            onClick={() => void submit()}
          >
            <MaterialIcon name="send_rounded" size={22} color={TODO_ACCENT} />
          </button>
        </div>
      </div>

      {/* 删除保护：WaitAlertDialog destructive 红字确认（05 §四删除保护文案流） */}
      <WaitAlertDialog
        open={pendingDelete != null}
        title="删除评论"
        message="确定要删除这条评论吗？此操作无法撤销。"
        onClose={() => setPendingDelete(null)}
        destructiveLabel="删除"
        onConfirm={() => void confirmDelete()}
      />
    </SectionCard>
  );
}
