/**
 * SavedFilterDialog — 保存筛选器的可视化构建器（#35 升级）
 *
 * 替换原「名称 + 裸 JSON 手填」表单：七键条件全部控件化（状态/优先级下限/
 * 项目/标签/截止窗口/逾期/收藏），用户不再接触 JSON；高级键（如 due_overdue
 * 与 due_within_days 互斥不可同选）在 UI 层约束。
 *
 * 预填模式：面板「存为视图」把工具栏当前筛选映射进表单（toolbarToForm），
 * 用户补个名字即可固化常用切片——Todoist Filters 同款体验。
 */
import { useEffect, useState } from "react";
import { Star, TriangleAlert } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
  type FilterFormState,
} from "../shared/saved-filter-builder";

export interface SavedFilterDialogProps {
  open: boolean;
  /** 预填条件 JSON（存为视图入口传工具栏映射结果；空 "{}" = 全新） */
  initialConditions: string;
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
  projects,
  labels,
  onCancel,
  onSubmit,
}: SavedFilterDialogProps) {
  const [name, setName] = useState("");
  const [form, setForm] = useState<FilterFormState>(EMPTY_FILTER_FORM);

  // 打开时重置表单 + 预填（initialConditions 变化即新一轮）
  useEffect(() => {
    if (open) {
      setName("");
      setForm(parseConditions(initialConditions));
    }
  }, [open, initialConditions]);

  const set = <K extends keyof FilterFormState>(key: K, value: FilterFormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  // 逾期与截止窗口互斥：白名单语义上一个任务不可能同时命中两条件仍被 AND 组合
  const toggleOverdue = (on: boolean) =>
    setForm((f) => ({ ...f, overdueOnly: on, dueWithinDays: on ? null : f.dueWithinDays }));

  const toggleDueWindow = (days: number | null) =>
    setForm((f) => ({ ...f, dueWithinDays: days, overdueOnly: days != null ? false : f.overdueOnly }));

  const submit = () => {
    if (!name.trim()) return;
    onSubmit(name.trim(), buildConditions(form));
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onCancel()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>保存筛选器</DialogTitle>
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
            保存
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
