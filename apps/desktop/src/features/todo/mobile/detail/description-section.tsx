/**
 * DescriptionSection —— 详情描述区（05 §4.3 描述行；M4 Task 13）
 *
 * trailing TextButton 编辑/取消切换；展示态 whitespace-pre-wrap 15px
 * （空显"暂无描述" sub@50%）；编辑态 multiline 5 行 OutlineInputBorder 等价
 * （border + rounded-lg）+ FilledButton 风格保存钮；trim 空串提交 null
 * （UpdateInput {description:null} 三态语义，02 §三要点 3）。
 */
import { useState } from "react";
import type { TodoTaskDetail, TodoTaskUpdateInput } from "@/lib/tauri";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

interface DescriptionSectionProps {
  task: TodoTaskDetail;
  onPatch: (input: TodoTaskUpdateInput) => Promise<void>;
}

/** TextButton 风格小钮（accent 文字 + active 反馈） */
function TextActionButton({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="rounded-lg px-2 py-1 text-sm font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
      style={{ color: TODO_ACCENT }}
    >
      {label}
    </button>
  );
}

export function DescriptionSection({ task, onPatch }: DescriptionSectionProps) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");

  const startEdit = () => {
    setDraft(task.description ?? "");
    setEditing(true);
  };

  /**
   * 保存：trim 空串 → null（清空语义）；与现值相同仅退出编辑态不请求；
   * 成功失效由父级 patchTask 统一处理。
   */
  const save = async () => {
    const next = draft.trim() || null;
    setEditing(false);
    if (next === (task.description ?? null)) return;
    await onPatch({ description: next });
  };

  return (
    <SectionCard
      title="描述"
      trailing={
        editing ? (
          <TextActionButton label="取消" onClick={() => setEditing(false)} />
        ) : (
          <TextActionButton label="编辑" onClick={startEdit} />
        )
      }
    >
      {editing ? (
        <div className="space-y-2">
          {/* OutlineInputBorder 等价：1px 边框 + rounded-lg，聚焦转 accent */}
          <textarea
            autoFocus
            rows={5}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className="w-full resize-none rounded-lg border border-black/[.12] bg-transparent p-3 text-[15px] leading-snug text-[var(--m-text)] outline-none focus:border-[#3B82F6] dark:border-white/[.12]"
          />
          <div className="flex justify-end">
            {/* FilledButton 风格：accent 实底白字 r8（05 §4.3 描述行） */}
            <button
              type="button"
              onClick={() => void save()}
              className="rounded-lg px-4 py-2 text-sm font-medium text-white transition-opacity active:opacity-80"
              style={{ background: TODO_ACCENT }}
            >
              保存
            </button>
          </div>
        </div>
      ) : (
        <p
          className="whitespace-pre-wrap break-words text-[15px] leading-relaxed text-[var(--m-text)]"
          style={task.description ? undefined : { color: "var(--m-sub)", opacity: 0.5 }}
        >
          {task.description || "暂无描述"}
        </p>
      )}
    </SectionCard>
  );
}
