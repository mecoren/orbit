/**
 * InfoSection —— 详情基本信息区（05 §4.3 基本信息行序固定五行；M4 Task 13/15）
 *
 * 行序：优先级(P0–P5 文本 + 10×10 色点，0 显"无") / 状态(待办·进行中·已完成 + 色点) /
 * 项目(项目名或"未分组") / 截止日期(yyyy-MM-dd 或"无") / 进度(N% 仅 percent_done>0 显示，
 * 只读无箭头)。编辑一律 SelectSheet（优先级/状态/项目三项）；截止日期行经 WaitDatePickerSheet
 * 选择（Task 15 注入，date 模式）。
 *
 * 状态切换与桌面 task-detail-drawer.tsx PropertyGrid.setStatus 完全同源：
 * 选 done → { status:"done", done:1, done_at:now }；切走 → { status:key, done:0, done_at:null }。
 */
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { MaterialIcon } from "@/components/mobile/material-icon";
import { SelectSheet } from "@/components/mobile/select-sheet";
import { WaitDatePickerSheet } from "@/components/mobile/wait-date-picker-sheet";
import {
  todoProjectList,
  type TodoTaskDetail,
  type TodoTaskUpdateInput,
} from "@/lib/tauri";
import { PRIORITY_COLOR, STATUS_COLOR, TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

/** 优先级文案（与桌面 task-detail-drawer PRIORITY_LABELS 一致） */
const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

/** 状态三项行序（色值复用共享 STATUS_COLOR，勿另立色板） */
const STATUS_ITEMS = [
  { key: "pending", label: "待办" },
  { key: "doing", label: "进行中" },
  { key: "done", label: "已完成" },
] as const;

/** yyyy-MM-dd 本地时区（同 todo-task-tile formatDue 口径） */
function formatDue(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

interface InfoSectionProps {
  task: TodoTaskDetail;
  onPatch: (input: TodoTaskUpdateInput) => Promise<void>;
}

type SheetKind = "priority" | "status" | "project" | null;

/** _InfoTile（05 §4.3）：InkWell 等价 active:bg 反馈 rounded-lg + v-padding8；
 * Row[label 12px/sub 固定列宽 80 → value 行：10×10 色点 + 15px 文本] → 尾 keyboard_arrow_right_rounded(20/sub) */
function _InfoTile({
  label,
  value,
  dot,
  onClick,
  arrow = true,
}: {
  label: string;
  value: string;
  /** 10×10 语义色点（空值不渲染） */
  dot?: string;
  /** 缺省为只读行（无按压反馈）；进度行为只读且无箭头 */
  onClick?: () => void;
  arrow?: boolean;
}) {
  const inner = (
    <>
      <span className="w-20 shrink-0 text-xs text-[var(--m-sub)]">{label}</span>
      <span className="flex min-w-0 flex-1 items-center gap-2">
        {dot ? <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: dot }} /> : null}
        <span className="truncate text-[15px] text-[var(--m-text)]">{value}</span>
      </span>
      {arrow ? (
        <MaterialIcon name="keyboard_arrow_right_rounded" size={20} color="var(--m-sub)" className="shrink-0" />
      ) : null}
    </>
  );
  if (!onClick) {
    return <div className="flex items-center rounded-lg py-2">{inner}</div>;
  }
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center rounded-lg py-2 text-left transition-colors active:bg-black/[.04] dark:active:bg-white/[.04]"
    >
      {inner}
    </button>
  );
}

export function InfoSection({ task, onPatch }: InfoSectionProps) {
  const [sheet, setSheet] = useState<SheetKind>(null);
  // 截止日期选择（Task 15 WaitDatePickerSheet，date 模式；initial=当前值）
  const [duePickerOpen, setDuePickerOpen] = useState(false);

  const projectsQuery = useQuery({
    queryKey: ["todo-project", "list"],
    queryFn: () => todoProjectList({ page: 1, page_size: 1000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const projects = projectsQuery.data ?? [];

  const projectTitle =
    task.project_id != null
      ? (projects.find((p) => p.id === task.project_id)?.title ?? "未分组")
      : "未分组";

  /** 状态切换：done 自动补 done_at=now、切走清空 done_at=null（桌面 setStatus 同源语义） */
  const handleStatusSelect = (key: string) => {
    if (key === "done") void onPatch({ status: "done", done: 1, done_at: Date.now() });
    else void onPatch({ status: key, done: 0, done_at: null });
  };

  // 项目弹层数据：首项"未分组" ↔ project_id=null（SelectItem 泛型限定 string|number，以 "" 哨兵承载 null）
  const projectItems = useMemo(
    () => [
      { value: "", label: "未分组" },
      ...projects.map((p) => ({
        value: String(p.id),
        label: p.title,
        colorDot: p.hex_color || TODO_ACCENT,
      })),
    ],
    [projects],
  );
  const projectCurrent = task.project_id != null ? String(task.project_id) : "";

  const priorityDot = PRIORITY_COLOR[task.priority] || undefined;
  const statusColor = STATUS_COLOR[task.status as keyof typeof STATUS_COLOR];

  return (
    <SectionCard title="基本信息">
      {/* 行序固定（05 §4.3）：优先级 → 状态 → 项目 → 截止日期 → 进度 */}
      <_InfoTile
        label="优先级"
        dot={priorityDot}
        value={PRIORITY_LABELS[task.priority] ?? "无"}
        onClick={() => setSheet("priority")}
      />
      <_InfoTile
        label="状态"
        dot={statusColor}
        value={STATUS_ITEMS.find((s) => s.key === task.status)?.label ?? task.status}
        onClick={() => setSheet("status")}
      />
      <_InfoTile label="项目" value={projectTitle} onClick={() => setSheet("project")} />
      <_InfoTile
        label="截止日期"
        value={task.due_date != null ? formatDue(task.due_date) : "无"}
        // 说明：截止日期更新后无需手动重调度提醒——到期拾取由 notification_scheduler
        // 前台轮询守护自动承担（R2 兜底基线），落库即生效。
        onClick={() => setDuePickerOpen(true)}
      />
      {/* 进度：仅 percent_done>0 显示，只读无箭头 */}
      {task.percent_done > 0 && (
        <_InfoTile label="进度" value={`${Math.round(task.percent_done)}%`} arrow={false} />
      )}

      {/* 编辑一律底部弹层选择器：12×12 圆点 ListTile + 当前值尾 check_rounded（SelectSheet 内建） */}
      <SelectSheet
        open={sheet === "priority"}
        title="优先级"
        items={PRIORITY_LABELS.map((label, i) => ({
          value: i,
          label,
          colorDot: i === 0 ? "#D1D5DB" : PRIORITY_COLOR[i], // P0"无"用灰点（桌面同款）
        }))}
        current={task.priority}
        onSelect={(v) => void onPatch({ priority: v })}
        onClose={() => setSheet(null)}
      />
      <SelectSheet
        open={sheet === "status"}
        title="状态"
        items={STATUS_ITEMS.map((s) => ({ value: s.key, label: s.label, colorDot: STATUS_COLOR[s.key] }))}
        current={task.status}
        onSelect={(v) => handleStatusSelect(v)}
        onClose={() => setSheet(null)}
      />
      <SelectSheet
        open={sheet === "project"}
        title="项目"
        items={projectItems}
        current={projectCurrent}
        onSelect={(v) => void onPatch({ project_id: v === "" ? null : Number(v) })}
        onClose={() => setSheet(null)}
      />

      {/* 截止日期选择：date 模式，确认走 patchTask（清除→null；轮询守护自动拾取提醒） */}
      <WaitDatePickerSheet
        open={duePickerOpen}
        mode="date"
        initial={task.due_date}
        onConfirm={(d) => void onPatch({ due_date: d ? d.getTime() : null })}
        onClose={() => setDuePickerOpen(false)}
      />
    </SectionCard>
  );
}
