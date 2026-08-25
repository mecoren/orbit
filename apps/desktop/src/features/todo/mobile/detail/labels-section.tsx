/**
 * LabelsSection —— 详情标签区（05 §4.3 后半；M4 Task 14）
 *
 * Wrap(spacing8/runSpacing8) 等价 flex-wrap gap-2；chip 字13 按 hexColor 着色、
 * radius 8、边框标签色@30%（color-mix）、deleteIcon close(16)；添加 chip =
 * add_rounded(18) + "添加"，边框 accent@30%。
 *
 * 选择流：可选标签（未挂载）>0 → 多选弹层（12×12 圆点 ListTiles + 末项"新建标签"，
 * 点选即挂载、弹层保持展开供连续多选）；否则直达新建对话框（名称 input + 六色
 * 28×28 圆 border3 选中，创建后立即挂载）。
 *
 * 失效约定：挂载/卸载/新建均经父级 refreshDetail 统一失效（含 ["todo-label"]
 * 标签池联动），禁 setQueryData 局部合并。
 */
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { BottomSheet } from "@/components/mobile/bottom-sheet";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { WaitAlertDialog } from "@/components/mobile/wait-alert-dialog";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoLabelCreate,
  todoLabelList,
  todoTaskLabelCreate,
  todoTaskLabelDelete,
  type TaskLabelWithId,
  type TodoTaskDetail,
} from "@/lib/tauri";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

/** 新建标签六色板（05 §4.3 标签区；28×28 圆 border3 选中） */
const LABEL_COLORS = ["#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#8B5CF6", "#EC4899"];
const DEFAULT_COLOR = "#3B82F6";

interface LabelsSectionProps {
  task: TodoTaskDetail;
  /** 统一失效出口：["todo-task-detail", id] + ["todo_tasks"] + ["todo-label"] */
  refreshDetail: () => Promise<void>;
}

export function LabelsSection({ task, refreshDetail }: LabelsSectionProps) {
  // 标签池只读查询：key 与桌面 LabelsSection 同款（["todo-label","list"]），失效由 refreshDetail 联动
  const allLabelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
    staleTime: 60_000,
    placeholderData: (prev) => prev,
  });
  const allLabels = allLabelsQuery.data ?? [];

  const mountedIds = new Set(task.labels.map((l) => l.id));
  /** 可选标签 = 全量池 − 已挂载（决定多选弹层 vs 直达新建对话框） */
  const available = allLabels.filter((l) => !mountedIds.has(l.id));

  const [pickerOpen, setPickerOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  const [newColor, setNewColor] = useState(DEFAULT_COLOR);

  const openAdd = () => {
    if (available.length > 0) setPickerOpen(true);
    else startCreate();
  };

  const startCreate = () => {
    setNewTitle("");
    setNewColor(DEFAULT_COLOR);
    setCreating(true);
  };

  /** 挂载已有标签（todoTaskLabelCreate({task_id,label_id})）→ 统一失效 */
  const mount = async (labelId: number) => {
    try {
      await todoTaskLabelCreate({ task_id: task.id, label_id: labelId });
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  /** 卸载：用 detail.labels 携带的 task_label_id（todo_task_labels 主键） */
  const unmount = async (l: TaskLabelWithId) => {
    try {
      await todoTaskLabelDelete(l.task_label_id);
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  /** 新建并立即挂载（05 §4.3：创建后立即挂载） */
  const createAndMount = async () => {
    const v = newTitle.trim();
    if (!v) return;
    try {
      const created = await todoLabelCreate({ title: v, hex_color: newColor });
      await todoTaskLabelCreate({ task_id: task.id, label_id: created.id });
      setCreating(false);
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  return (
    <SectionCard title="标签">
      {/* Wrap(spacing8/runSpacing8) */}
      <div className="flex flex-wrap gap-2">
        {task.labels.map((l) => (
          <span
            key={l.task_label_id}
            className="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-[13px]"
            style={{
              color: l.hex_color,
              border: `1px solid color-mix(in srgb, ${l.hex_color} 30%, transparent)`,
            }}
          >
            {l.title}
            <button type="button" aria-label={`移除标签 ${l.title}`} onClick={() => void unmount(l)}>
              <MaterialIcon name="close" size={16} />
            </button>
          </span>
        ))}

        {/* 添加 chip：avatar add_rounded(18)+"添加"，边框 accent@30% */}
        <button
          type="button"
          onClick={openAdd}
          className="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-[13px] font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
          style={{ color: TODO_ACCENT, border: `1px solid color-mix(in srgb, ${TODO_ACCENT} 30%, transparent)` }}
        >
          <MaterialIcon name="add_rounded" size={18} />
          添加
        </button>
      </div>

      {/* 多选弹层：12×12 圆点 ListTiles + 末项"新建标签"；点选即挂载、保持展开连续多选 */}
      <BottomSheet open={pickerOpen} onClose={() => setPickerOpen(false)} title="选择标签" snapPoints={[0.55]}>
        <ul className="m-safe-bottom">
          {available.map((l) => (
            <li key={l.id}>
              <button
                type="button"
                className="flex h-12 w-full items-center gap-3 px-4 text-left active:bg-black/[.04] dark:active:bg-white/[.04]"
                onClick={() => void mount(l.id)}
              >
                <span className="h-3 w-3 shrink-0 rounded-full" style={{ background: l.hex_color }} />
                <span className="flex-1 truncate text-[15px] text-[var(--m-text)]">{l.title}</span>
              </button>
            </li>
          ))}
          <li>
            <button
              type="button"
              className="flex h-12 w-full items-center gap-3 px-4 text-left active:bg-black/[.04] dark:active:bg-white/[.04]"
              onClick={() => {
                setPickerOpen(false);
                startCreate();
              }}
            >
              <MaterialIcon name="add_rounded" size={18} color={TODO_ACCENT} />
              <span className="flex-1 text-[15px]" style={{ color: TODO_ACCENT }}>
                新建标签
              </span>
            </button>
          </li>
        </ul>
      </BottomSheet>

      {/* 新建对话框：名称 input + 六色 28×28 圆 border3 选中 */}
      <WaitAlertDialog
        open={creating}
        title="新建标签"
        message="输入名称并选择颜色。"
        onClose={() => setCreating(false)}
        actions={
          <div className="w-full space-y-3">
            <input
              autoFocus
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  void createAndMount();
                }
              }}
              placeholder="标签名称"
              className="w-full rounded-lg border border-black/[.12] bg-transparent px-3 py-2 text-sm text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] focus:border-[#3B82F6] dark:border-white/[.12]"
            />
            <div className="flex justify-center gap-2.5">
              {LABEL_COLORS.map((c) => {
                const selected = newColor === c;
                return (
                  <button
                    key={c}
                    type="button"
                    aria-label={`选择颜色 ${c}`}
                    onClick={() => setNewColor(c)}
                    className={`h-7 w-7 rounded-full ${selected ? "" : "border border-black/[.15] dark:border-white/[.25]"}`}
                    style={{ background: c, border: selected ? `3px solid ${TODO_ACCENT}` : undefined }}
                  />
                );
              })}
            </div>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                className="rounded-lg px-4 py-2 text-sm text-[var(--m-sub)]"
                onClick={() => setCreating(false)}
              >
                取消
              </button>
              <button
                type="button"
                disabled={!newTitle.trim()}
                className="rounded-lg px-4 py-2 text-sm font-medium text-white disabled:opacity-40"
                style={{ background: TODO_ACCENT }}
                onClick={() => void createAndMount()}
              >
                创建
              </button>
            </div>
          </div>
        }
      />
    </SectionCard>
  );
}
