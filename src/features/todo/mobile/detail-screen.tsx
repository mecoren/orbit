/**
 * DetailScreen —— 任务详情全屏 /todo/:id（05 §4.3 前半；M4 Task 13）
 *
 * 页面结构：LiquidGlassTitleBar（title=任务标题截断或"详情"）+ 滚动容器
 * + 尾部留白 80 + m-safe-bottom。区块顺序：标题区 → 基本信息 → 描述 →
 * （Task 14 插槽固定序：子任务 → 标签 → 提醒 → 关联任务 → 评论）。
 *
 * 数据源 todoTaskGetDetail(id) 聚合查询（react-query key ["todo-task-detail", id]，
 * 返回 TodoTaskDetail = 任务本体 + subtasks/labels/comments/relations/reminders）；
 * 更新统一走 patchTask 出口（todoTaskUpdate 缺省键=跳过语义，02 §三要点 3），
 * 成功后失效 ["todo_tasks"] 与详情 key。
 */
import { useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import { EqSpinner } from "@/components/mobile/eq-spinner";
import { LiquidGlassTitleBar } from "@/components/mobile/liquid-glass-title-bar";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoTaskGetDetail,
  todoTaskUpdate,
  type TodoTaskDetail,
  type TodoTaskUpdateInput,
} from "@/lib/tauri";

import { TODO_ACCENT } from "../shared/constants";
import { applyDoneToggle } from "../shared/task-actions";
import { DescriptionSection } from "./detail/description-section";
import { InfoSection } from "./detail/info-section";
import { SectionCard } from "./section-card";

/** 详情标题区（05 §4.3）：28px 完成 checkbox 在左 + headlineSmall(24px/w400) 原地编辑 */
function TitleSection({
  task,
  onPatch,
}: {
  task: TodoTaskDetail;
  onPatch: (input: TodoTaskUpdateInput) => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.title);
  const inputRef = useRef<HTMLInputElement>(null);
  /** Escape 取消标记：blur 时据此跳过提交（对应 onTapOutside 保存的例外路径） */
  const cancelRef = useRef(false);

  const startEdit = () => {
    setDraft(task.title);
    setEditing(true);
  };

  /** 保存：trim 空 / 未变化仅退出编辑态不请求（05 §4.3 标题区语义）；成功失效由 onPatch 统一处理 */
  const commit = async () => {
    const v = draft.trim();
    setEditing(false);
    if (!v || v === task.title) return;
    await onPatch({ title: v });
  };

  const cancel = () => {
    cancelRef.current = true;
    setDraft(task.title);
    inputRef.current?.blur();
  };

  return (
    <SectionCard>
      <div className="flex items-start gap-3">
        {/* 28px 圆形 checkbox（border-2；完成填 accent #3B82F6 + check18 白），点按 applyDoneToggle 同源语义 */}
        <button
          type="button"
          aria-label={task.done ? "标记未完成" : "标记完成"}
          className="mt-1 grid h-7 w-7 shrink-0 place-items-center rounded-full border-2 transition-colors"
          style={{
            borderColor: task.done ? TODO_ACCENT : "var(--m-sub)",
            opacity: task.done ? undefined : 0.4,
            background: task.done ? TODO_ACCENT : "transparent",
          }}
          onClick={() => void onPatch(applyDoneToggle(task))}
        >
          {task.done ? <MaterialIcon name="check" size={18} color="#FFFFFF" /> : null}
        </button>

        <div className="min-w-0 flex-1">
          {editing ? (
            /* 原地 TextField：InputBorder.none 等价 = 无边框 outline-none + bg-transparent + 紧凑行高(isDense) */
            <input
              ref={inputRef}
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onBlur={() => {
                // onTapOutside 等价出口；Escape 取消时跳过提交
                if (cancelRef.current) {
                  cancelRef.current = false;
                  setEditing(false);
                  return;
                }
                void commit();
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  inputRef.current?.blur(); // onSubmitted 收敛到同一 blur 提交路径，避免双触发
                } else if (e.key === "Escape") {
                  cancel();
                }
              }}
              className="w-full bg-transparent py-0 text-2xl font-normal leading-tight text-[var(--m-text)] outline-none"
            />
          ) : (
            <h2
              className={`min-w-0 cursor-text break-words text-2xl font-normal leading-tight text-[var(--m-text)] ${
                task.done ? "line-through opacity-50" : ""
              }`}
              onClick={startEdit}
            >
              {task.title}
            </h2>
          )}
        </div>
      </div>
    </SectionCard>
  );
}

export function DetailScreen() {
  const params = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  // 滚动容器 ref：与标题栏同 commit 赋值（LiquidGlassTitleBar scrollRef 契约）
  const scrollRef = useRef<HTMLDivElement>(null);

  // 路由参数 id 合法性校验（非正整数为非法直达）
  const rawId = params.id;
  const taskId = rawId != null && /^\d+$/.test(rawId) && Number(rawId) > 0 ? Number(rawId) : null;

  const detailQuery = useQuery({
    queryKey: ["todo-task-detail", taskId],
    queryFn: () => todoTaskGetDetail(taskId!),
    enabled: taskId != null,
    retry: 1,
  });
  const detail = detailQuery.data;

  /**
   * 更新统一出口：缺省键=跳过语义直传（禁止全量回传）；
   * 成功失效 ["todo_tasks"] 列表与 ["todo-task-detail", id] 详情；失败 destructive toast。
   */
  const patchTask = async (input: TodoTaskUpdateInput) => {
    if (taskId == null) return;
    try {
      await todoTaskUpdate(taskId, input);
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
      void qc.invalidateQueries({ queryKey: ["todo-task-detail", taskId] });
    } catch {
      waitToast.destructive("更新失败");
    }
  };

  return (
    <div className="h-dvh bg-[var(--m-bg)] text-[var(--m-text)]">
      <div ref={scrollRef} className="h-full overflow-y-auto overscroll-y-contain">
        <LiquidGlassTitleBar
          title={detail?.title || "详情"}
          scrollRef={scrollRef}
          onBack={() => navigate(-1)}
        />

        {taskId == null || detailQuery.isError ? (
          /* 失败态：记录不存在或加载失败 + 返回钮 */
          <div className="flex flex-col items-center gap-4 pt-32">
            <p className="text-sm text-[var(--m-sub)]">记录不存在或加载失败</p>
            <button
              type="button"
              onClick={() => navigate(-1)}
              className="rounded-lg px-4 py-2 text-sm font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
              style={{ color: TODO_ACCENT }}
            >
              返回
            </button>
          </div>
        ) : !detail ? (
          /* 加载态：EqSpinner 居中 48px（扣除标题栏 56px 后垂直居中） */
          <div className="grid place-items-center" style={{ minHeight: "calc(100dvh - 56px)" }}>
            <EqSpinner size={48} />
          </div>
        ) : (
          <div className="space-y-3 px-4 pb-20 pt-3">
            {/* 区块顺序（05 §4.3）：标题区 → 基本信息 → 描述 */}
            <TitleSection task={detail} onPatch={patchTask} />
            <InfoSection task={detail} onPatch={patchTask} />
            <DescriptionSection task={detail} onPatch={patchTask} />
            {/* Task 14 插槽（顺序预留）：子任务 → 标签 → 提醒 → 关联任务 → 评论 */}
          </div>
        )}

        {/* 页面尾留白 80（pb-20）+ 底部安全区/手势条兜底（05 §4.3/§五） */}
        <div className="m-safe-bottom" aria-hidden />
      </div>
    </div>
  );
}
