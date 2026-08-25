/**
 * TodoTaskTile —— 任务行卡片（05 §4.5 逐条复刻）
 *
 * 卡片底 color-mix(in srgb, var(--m-surface) 50%, transparent)（§4.5 原文为
 * --surface-container-low，MVP token 简化为 --m-surface，记偏差）、radius 12、
 * 外边距 (12,4)、内边距 (12,8)。flex 行：24px 圆 checkbox + 标题 + RichText
 * 副标题 + 星标；长按 500ms 弹操作弹层（编辑/星标切换/删除），点按 → 详情。
 */
import { useState } from "react";
import { useNavigate } from "react-router";
import { useQueryClient } from "@tanstack/react-query";

import { BottomSheet } from "@/components/mobile/bottom-sheet";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { WaitAlertDialog } from "@/components/mobile/wait-alert-dialog";
import { waitToast } from "@/components/mobile/wait-toast";
import { todoTaskDelete, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";
import { useLongPress } from "./use-long-press";

interface TodoTaskTileProps {
  task: TodoTask;
  /** 副标题项目名；无项目（未分组）不渲染该段 */
  projectTitle?: string | null;
  /** 点按导航（缺省 navigate(`/todo/${task.id}`)） */
  onOpen?: () => void;
  /** 勾选/取消勾选（父级调 todoTaskUpdate(applyDoneToggle(task)) 后失效列表） */
  onToggleDone?: () => void;
  /** 收藏切换（父级写 is_favorite 后失效列表） */
  onToggleFavorite?: () => void;
  /** 长按菜单「编辑」入口（Task 15 表单抽屉接线）；缺省占位提示 */
  onEdit?: () => void;
}

/** 截止日期 yyyy-MM-dd（本地时区取数） */
function formatDue(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function TodoTaskTile({ task, projectTitle, onOpen, onToggleDone, onToggleFavorite, onEdit }: TodoTaskTileProps) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const longPress = useLongPress(() => setMenuOpen(true));

  // 逾期：due_date < 今日零点 且未完成 → 日期段 #F44336（05 §4.5）
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const overdue = task.due_date != null && !task.done && task.due_date < todayStart.getTime();
  const priorityDot = PRIORITY_COLOR[task.priority]; // index 0 = ""（无优先级不显）
  const hasSubtitle = !!(priorityDot || (projectTitle && task.project_id != null) || task.due_date != null);

  /** 删除确认后落库：todoTaskDelete + 失效任务列表（queryKey 前缀匹配全部 todo_tasks 查询） */
  const handleDelete = async () => {
    try {
      await todoTaskDelete(task.id);
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    } catch {
      waitToast.destructive("删除失败");
    }
  };

  return (
    <>
      {/* 卡片容器（05 §4.5）：radius 12 / 外边距 (12,4)=mx-3 my-1 / 内边距 (12,8)=px-3 py-2 */}
      <div
        role="button"
        tabIndex={0}
        aria-label={`任务 ${task.title}`}
        className="mx-3 my-1 cursor-pointer rounded-xl px-3 py-2 select-none active:bg-black/[.04] dark:active:bg-white/[.04]"
        style={{ background: "color-mix(in srgb, var(--m-surface) 50%, transparent)" }}
        onClick={() => (onOpen ? onOpen() : navigate(`/todo/${task.id}`))}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") (onOpen ? onOpen() : navigate(`/todo/${task.id}`));
        }}
        {...longPress}
      >
        <div className="flex items-center gap-3">
          {/* 24px 圆形 checkbox（border-2；完成填 accent #3B82F6 + check16 白） */}
          <button
            type="button"
            aria-label={task.done ? "标记未完成" : "标记完成"}
            className="grid h-6 w-6 shrink-0 place-items-center rounded-full border-2 transition-colors"
            style={{
              borderColor: task.done ? TODO_ACCENT : "var(--m-sub)",
              opacity: task.done ? undefined : 0.4,
              background: task.done ? TODO_ACCENT : "transparent",
            }}
            onClick={(e) => {
              e.stopPropagation(); // 不触发卡片导航
              onToggleDone?.();
            }}
          >
            {task.done ? <MaterialIcon name="check" size={16} color="#FFFFFF" /> : null}
          </button>

          {/* 标题 + RichText 副标题 */}
          <div className="min-w-0 flex-1">
            <div
              className="truncate text-base font-medium text-[var(--m-text)]"
              style={task.done ? { textDecoration: "line-through", opacity: 0.5 } : undefined}
            >
              {task.title}
            </div>
            {hasSubtitle && (
              <div className="mt-0.5 flex items-center gap-1 text-xs text-[var(--m-sub)]">
                {/* 8px 优先级色点（PRIORITY_COLOR[index]，index 0 不显） */}
                {priorityDot && (
                  <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: priorityDot }} />
                )}
                {projectTitle && task.project_id != null && <span>{projectTitle}</span>}
                {task.due_date != null && (
                  <span className="inline-flex items-center gap-1">
                    {(projectTitle && task.project_id != null) || priorityDot ? <span>·</span> : null}
                    <span style={{ color: overdue ? "#F44336" : undefined }}>
                      {formatDue(task.due_date)}
                    </span>
                  </span>
                )}
              </div>
            )}
          </div>

          {/* 星标 24px #FACC15（is_favorite truthy 才显示） */}
          {task.is_favorite ? (
            <MaterialIcon name="star" size={24} fill={1} color={FAVORITE_COLOR} className="shrink-0" />
          ) : null}
        </div>
      </div>

      {/* 长按操作弹层（05 §4.5）：简易 action sheet，三选项 */}
      <BottomSheet open={menuOpen} onClose={() => setMenuOpen(false)} title={task.title} snapPoints={[0.35]}>
        <ul className="pb-4">
          <li>
            <button
              type="button"
              className="flex h-12 w-full items-center gap-3 px-4 text-left"
              onClick={() => {
                setMenuOpen(false);
                if (onEdit) onEdit();
                else waitToast.message("表单抽屉将在 Task 15 接入");
              }}
            >
              <MaterialIcon name="edit_rounded" size={22} color="var(--m-sub)" />
              <span className="flex-1 text-[15px] text-[var(--m-text)]">编辑</span>
            </button>
          </li>
          <li>
            <button
              type="button"
              className="flex h-12 w-full items-center gap-3 px-4 text-left"
              onClick={() => {
                setMenuOpen(false);
                onToggleFavorite?.();
              }}
            >
              <MaterialIcon name="star" size={22} fill={1} color={FAVORITE_COLOR} />
              <span className="flex-1 text-[15px] text-[var(--m-text)]">
                {task.is_favorite ? "取消收藏" : "收藏"}
              </span>
            </button>
          </li>
          <li>
            <button
              type="button"
              className="flex h-12 w-full items-center gap-3 px-4 text-left"
              onClick={() => {
                setMenuOpen(false);
                setConfirmDelete(true); // destructive 确认流前置拦截
              }}
            >
              <MaterialIcon name="delete_outline_rounded" size={22} color="#F44336" />
              <span className="flex-1 text-[15px] text-[#F44336]">删除</span>
            </button>
          </li>
        </ul>
      </BottomSheet>

      {/* 删除保护（destructive 双钮确认） */}
      <WaitAlertDialog
        open={confirmDelete}
        title="删除任务"
        message={`确定要删除任务「${task.title}」吗？该操作不可撤销。`}
        onClose={() => setConfirmDelete(false)}
        destructiveLabel="删除"
        onConfirm={() => void handleDelete()}
      />
    </>
  );
}
