/**
 * SavedFilterDialog — 保存筛选器的可视化构建器（#35 升级；#71 起十四键）
 *
 * 替换原「名称 + 裸 JSON 手填」表单：十四键条件全部控件化（状态/优先级下限/
 * 项目/标签/截止窗口/逾期/收藏/截止区间/创建下限/完成下限/提醒·附件·
 * 未完成子任务存在三态），用户不再接触 JSON；高级键（due_overdue 与
 * due_within_days/区间三互斥不可同选）在 UI 层约束。
 *
 * 预填模式：面板「存为视图」把工具栏当前筛选映射进表单（toolbarToForm），
 * 用户补个名字即可固化常用切片——Todoist Filters 同款体验。
 */
import { useEffect, useState } from "react";
import { Star, TriangleAlert } from "lucide-react";
import { format } from "date-fns";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { DatePicker } from "@/components/business/date-picker";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { PRIORITY_LABELS } from "../shared/constants";
import {
  buildConditions,
  EMPTY_FILTER_FORM,
  parseConditions,
  type ExistenceTriState,
  type FilterFormState,
} from "../shared/saved-filter-builder";

/** ms → 日期输入值（YYYY-MM-DD；null = 空） */
const msToDateInput = (ms: number | null): string =>
  ms == null ? "" : format(new Date(ms), "yyyy-MM-dd");

/** 日期输入值 → 当日零点 ms；空/非法 → null（维度不过滤） */
const dateInputToMs = (v: string): number | null => {
  if (!v) return null;
  const ms = new Date(`${v}T00:00:00`).getTime();
  return Number.isNaN(ms) ? null : ms;
};

/** 存在三态 chips（不限 / 有 / 无） */
function TriStateRow({
  label,
  value,
  onChange,
}: {
  label: string;
  value: ExistenceTriState;
  onChange: (v: ExistenceTriState) => void;
}) {
  const opts: Array<{ v: ExistenceTriState; t: string }> = [
    { v: null, t: "不限" },
    { v: true, t: "有" },
    { v: false, t: "无" },
  ];
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className="text-xs text-muted-foreground">{label}：</span>
      {opts.map((o) => (
        <button
          key={o.t}
          type="button"
          aria-pressed={value === o.v}
          onClick={() => onChange(value === o.v ? null : o.v)}
          className={cn(
            "h-7 rounded-full border px-2.5 text-xs transition-colors",
            value === o.v
              ? "border-primary/40 bg-primary/10 text-primary"
              : "border-border text-muted-foreground hover:bg-accent",
          )}
        >
          {o.t}
        </button>
      ))}
    </div>
  );
}

export interface SavedFilterDialogProps {
  open: boolean;
  /** 预填条件 JSON（存为视图入口传工具栏映射结果；空 "{}" = 全新） */
  initialConditions: string;
  /** 预填名称：编辑既有筛选器时回填（新建为空） */
  initialName?: string;
  /** 编辑态只改标题/按钮文案，提交仍走同一个 onSubmit */
  mode?: "create" | "edit";
  projects: { id: number; title: string; hex_color: string }[];
  labels: { id: number; title: string; hex_color: string }[];
  onCancel: () => void;
  onSubmit: (name: string, conditions: string) => void;
}

/** 截止窗口常用档位（Todoist quick filters 同款节奏） */
const DUE_WINDOW_CHOICES = [1, 3, 7, 14, 30, 90];

export function SavedFilterDialog({
  open,
  initialConditions,
  initialName = "",
  mode = "create",
  projects,
  labels,
  onCancel,
  onSubmit,
}: SavedFilterDialogProps) {
  const [name, setName] = useState("");
  const [form, setForm] = useState<FilterFormState>(EMPTY_FILTER_FORM);

  // 打开时重置表单 + 预填（initialConditions/initialName 变化即新一轮）
  useEffect(() => {
    if (open) {
      setName(initialName);
      setForm(parseConditions(initialConditions));
    }
  }, [open, initialConditions, initialName]);

  const set = <K extends keyof FilterFormState>(key: K, value: FilterFormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  // 逾期 / 截止窗口 / 截止区间三互斥：语义上一个任务不可能同时命中
  // 多个日期条件仍被 AND 组合（区间与窗口叠加恒无命中，UI 层直接约束）
  const toggleOverdue = (on: boolean) =>
    setForm((f) => ({
      ...f,
      overdueOnly: on,
      dueWithinDays: on ? null : f.dueWithinDays,
      dueFrom: on ? null : f.dueFrom,
      dueUntil: on ? null : f.dueUntil,
    }));

  const toggleDueWindow = (days: number | null) =>
    setForm((f) => ({
      ...f,
      dueWithinDays: days,
      overdueOnly: days != null ? false : f.overdueOnly,
      dueFrom: days != null ? null : f.dueFrom,
      dueUntil: days != null ? null : f.dueUntil,
    }));

  const submit = () => {
    if (!name.trim()) return;
    onSubmit(name.trim(), buildConditions(form));
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onCancel()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{mode === "edit" ? "编辑筛选器" : "保存筛选器"}</DialogTitle>
        </DialogHeader>

        <Input
          autoFocus
          placeholder="名称（如：本周紧急）"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && name.trim()) submit();
          }}
        />

        <div className="grid grid-cols-2 gap-3">
          {/* 状态 */}
          <Select
            value={form.status ?? "all"}
            onValueChange={(v) => set("status", v === "all" ? null : v)}
          >
            <SelectTrigger className="h-8">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">任意状态</SelectItem>
              <SelectItem value="pending">待办</SelectItem>
              <SelectItem value="doing">进行中</SelectItem>
              <SelectItem value="done">已完成</SelectItem>
            </SelectContent>
          </Select>

          {/* 优先级下限 */}
          <Select
            value={form.priorityMin != null ? String(form.priorityMin) : "all"}
            onValueChange={(v) => set("priorityMin", v === "all" ? null : Number(v))}
          >
            <SelectTrigger className="h-8">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">任意优先级</SelectItem>
              {PRIORITY_LABELS.slice(1).map((label, lv) => (
                <SelectItem key={lv} value={String(lv + 1)}>
                  ≥ {label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {/* 截止窗口 + 逾期（互斥档） */}
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">截止：</span>
          <button
            type="button"
            aria-pressed={form.overdueOnly}
            onClick={() => toggleOverdue(!form.overdueOnly)}
            className={cn(
              "flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs transition-colors",
              form.overdueOnly
                ? "border-destructive/40 bg-destructive/10 text-destructive"
                : "border-border text-muted-foreground hover:bg-accent",
            )}
          >
            <TriangleAlert className="size-3" />
            已逾期
          </button>
          {DUE_WINDOW_CHOICES.map((d) => (
            <button
              key={d}
              type="button"
              aria-pressed={form.dueWithinDays === d}
              onClick={() => toggleDueWindow(form.dueWithinDays === d ? null : d)}
              className={cn(
                "h-7 rounded-full border px-2.5 text-xs transition-colors",
                form.dueWithinDays === d
                  ? "border-primary/40 bg-primary/10 text-primary"
                  : "border-border text-muted-foreground hover:bg-accent",
              )}
            >
              {d} 天内
            </button>
          ))}
        </div>

        {/* 截止区间（绝对日期；与「N 天内/已逾期」互斥——区间是精确切片） */}
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">截止区间：</span>
          <DatePicker
            value={msToDateInput(form.dueFrom)}
            onChange={(v) =>
              setForm((f) => ({
                ...f,
                dueFrom: dateInputToMs(v),
                dueWithinDays: null,
                overdueOnly: false,
              }))
            }
            placeholder="从"
            quick={false}
            className="h-7 w-32 px-2 text-xs"
          />
          <span className="text-xs text-muted-foreground">至</span>
          <DatePicker
            value={msToDateInput(form.dueUntil)}
            onChange={(v) =>
              setForm((f) => ({
                ...f,
                dueUntil: dateInputToMs(v),
                dueWithinDays: null,
                overdueOnly: false,
              }))
            }
            placeholder="到（含前一天）"
            quick={false}
            className="h-7 w-32 px-2 text-xs"
          />
          {(form.dueFrom != null || form.dueUntil != null) && (
            <button
              type="button"
              onClick={() => setForm((f) => ({ ...f, dueFrom: null, dueUntil: null }))}
              className="h-7 rounded-full border px-2.5 text-xs text-muted-foreground hover:bg-accent"
            >
              清除
            </button>
          )}
        </div>
        {form.dueFrom != null &&
          form.dueUntil != null &&
          form.dueFrom >= form.dueUntil && (
            <p className="text-xs text-destructive">
              起始不早于结束，该维度恒无命中（左闭右开）
            </p>
          )}

        {/* 项目集（任一命中） */}
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">项目：</span>
          <button
            type="button"
            aria-pressed={form.projectIds.length === 0}
            onClick={() => set("projectIds", [])}
            className={cn(
              "h-7 rounded-full border px-2.5 text-xs transition-colors",
              form.projectIds.length === 0
                ? "border-primary/40 bg-primary/10 text-primary"
                : "border-border text-muted-foreground hover:bg-accent",
            )}
          >
            任意
          </button>
          {projects.map((p) => (
            <button
              key={p.id}
              type="button"
              aria-pressed={form.projectIds.includes(p.id)}
              onClick={() =>
                set(
                  "projectIds",
                  form.projectIds.includes(p.id)
                    ? form.projectIds.filter((id) => id !== p.id)
                    : [...form.projectIds, p.id],
                )
              }
              className={cn(
                "h-7 rounded-full border px-2.5 text-xs transition-colors",
                form.projectIds.includes(p.id)
                  ? "border-primary/40 bg-primary/10 text-primary"
                  : "border-border text-muted-foreground hover:bg-accent",
              )}
              style={{ borderColor: form.projectIds.includes(p.id) ? p.hex_color : undefined }}
            >
              {p.title}
            </button>
          ))}
        </div>

        {/* 标签集（任一命中） */}
        {labels.length > 0 && (
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="text-xs text-muted-foreground">标签：</span>
            <button
              type="button"
              aria-pressed={form.labelIds.length === 0}
              onClick={() => set("labelIds", [])}
              className={cn(
                "h-7 rounded-full border px-2.5 text-xs transition-colors",
                form.labelIds.length === 0
                  ? "border-primary/40 bg-primary/10 text-primary"
                  : "border-border text-muted-foreground hover:bg-accent",
              )}
            >
              任意
            </button>
            {labels.map((l) => (
              <button
                key={l.id}
                type="button"
                aria-pressed={form.labelIds.includes(l.id)}
                onClick={() =>
                  set(
                    "labelIds",
                    form.labelIds.includes(l.id)
                      ? form.labelIds.filter((id) => id !== l.id)
                      : [...form.labelIds, l.id],
                  )
                }
                className={cn(
                  "h-7 rounded-full border px-2.5 text-xs transition-colors",
                  form.labelIds.includes(l.id)
                    ? "border-primary/40 bg-primary/10 text-primary"
                    : "border-border text-muted-foreground hover:bg-accent",
                )}
                style={{ borderColor: form.labelIds.includes(l.id) ? l.hex_color : undefined }}
              >
                {l.title}
              </button>
            ))}
          </div>
        )}

        {/* 创建/完成时间下限（绝对日期；完成维度下未完成任务恒不命中） */}
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">创建晚于：</span>
          <DatePicker
            value={msToDateInput(form.createdFrom)}
            onChange={(v) => set("createdFrom", dateInputToMs(v))}
            placeholder="不限"
            quick={false}
            className="h-7 w-32 px-2 text-xs"
          />
          <span className="text-xs text-muted-foreground">完成晚于：</span>
          <DatePicker
            value={msToDateInput(form.doneFrom)}
            onChange={(v) => set("doneFrom", dateInputToMs(v))}
            placeholder="不限"
            quick={false}
            className="h-7 w-32 px-2 text-xs"
          />
        </div>

        {/* 存在三态（有/无/不限） */}
        <TriStateRow label="提醒" value={form.hasReminder} onChange={(v) => set("hasReminder", v)} />
        <TriStateRow label="附件" value={form.hasAttachment} onChange={(v) => set("hasAttachment", v)} />
        <TriStateRow
          label="未完成子任务"
          value={form.hasOpenSubtask}
          onChange={(v) => set("hasOpenSubtask", v)}
        />

        {/* 收藏开关 */}
        <button
          type="button"
          aria-pressed={form.favoriteOnly}
          onClick={() => set("favoriteOnly", !form.favoriteOnly)}
          className={cn(
            "flex h-7 w-fit items-center gap-1.5 rounded-full border px-2.5 text-xs transition-colors",
            form.favoriteOnly
              ? "border-yellow-400/50 bg-yellow-400/10 text-yellow-600"
              : "border-border text-muted-foreground hover:bg-accent",
          )}
        >
          <Star className="size-3" />
          仅收藏
        </button>

        <DialogFooter>
          <Button variant="ghost" onClick={onCancel}>
            取消
          </Button>
          <Button disabled={!name.trim()} onClick={submit}>
            {mode === "edit" ? "保存修改" : "保存"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
