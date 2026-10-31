/**
 * SavedFilterDialog — 保存筛选器的可视化构建器（#35 升级；#71 起十四键）
 *
 * 替换原「名称 + 裸 JSON 手填」表单：十四键条件全部控件化（状态/优先级下限/
 * 项目/标签/截止窗口/逾期/收藏/截止区间/创建下限/完成下限/提醒·附件·
 * 未完成子任务存在三态），用户不再接触 JSON；高级键（due_overdue 与
 * due_within_days/区间三互斥不可同选）在 UI 层约束。
 *
 * 预填模式：面板「保存为筛选器」把工具栏当前筛选映射进表单（toolbarToForm），
 * 用户补个名字即可固化常用切片——Todoist Filters 同款体验。
 *
 * 版式（2026-10-29）：名称即标题（无边框大标题输入，与任务创建抽屉同款，
 * 不随条件区滚走），条件按「状态 / 截止时间 / 范围 / 时间范围 / 属性」分组，
 * 头部与底部动作条固定、仅中段滚动——长表单不再把「保存」按钮顶出视口
 * （与项目编辑弹窗同为底部常驻动作条口径）。
 */
import { useEffect, useState, type ReactNode } from "react";
import { Star, TriangleAlert } from "lucide-react";
import { format } from "date-fns";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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

/**
 * 条件胶囊：状态档/日期档/项目/标签/三态共用一套外观。
 * tone 只区分语义色（逾期=红、收藏=黄），其余走待办强调色。
 */
function FilterChip({
  active,
  onClick,
  accentColor,
  tone = "primary",
  children,
}: {
  active: boolean;
  onClick: () => void;
  /** 选中时用该项自身色作边框（项目/标签） */
  accentColor?: string;
  tone?: "primary" | "danger" | "favorite";
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cn(
        "flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs transition-colors",
        active
          ? tone === "danger"
            ? "border-destructive/40 bg-destructive/10 text-destructive"
            : tone === "favorite"
              ? "border-yellow-400/50 bg-yellow-400/10 text-yellow-600"
              : "border-primary/40 bg-primary/10 text-primary"
          : "border-border text-muted-foreground hover:bg-accent",
      )}
      style={active && accentColor ? { borderColor: accentColor } : undefined}
    >
      {children}
    </button>
  );
}

/** 分组标题（右侧可挂「清除区间」这类就地操作） */
function SectionHeader({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string;
  children?: ReactNode;
}) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <span className="text-xs font-medium text-foreground">{title}</span>
      {hint && <span className="text-[11px] text-muted-foreground">{hint}</span>}
      {children && <div className="ml-auto">{children}</div>}
    </div>
  );
}

/** 存在三态 chips（不限 / 有 / 无）；定宽标签让四行属性左缘对齐 */
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
    <div className="flex items-center gap-2">
      <span className="w-24 shrink-0 text-xs text-muted-foreground">{label}</span>
      <div className="flex flex-wrap items-center gap-1.5">
        {opts.map((o) => (
          <FilterChip
            key={o.t}
            active={value === o.v}
            onClick={() => onChange(value === o.v ? null : o.v)}
          >
            {o.t}
          </FilterChip>
        ))}
      </div>
    </div>
  );
}

export interface SavedFilterDialogProps {
  open: boolean;
  /** 预填条件 JSON（「保存为筛选器」入口传工具栏映射结果；空 "{}" = 全新） */
  initialConditions: string;
  /** 预填名称：编辑既有筛选器时回填（新建为空） */
  initialName?: string;
  /** 编辑态只改标题/按钮文案，提交仍走同一个 onSubmit */
  mode?: "create" | "edit";
  projects: { id: number; title: string; hex_color: string }[];
  labels: { id: number; title: string; hex_color: string }[];
  onCancel: () => void;
  /** 允许异步：父层写入期间弹层保持 pending，防止双击保存建出两个筛选器 */
  onSubmit: (name: string, conditions: string) => void | Promise<void>;
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

  // saving 兼作重入锁：Enter 与按钮共用同一入口，双击/连按都只落一条
  const [saving, setSaving] = useState(false);
  const submit = async () => {
    if (!name.trim() || saving) return;
    setSaving(true);
    try {
      await onSubmit(name.trim(), buildConditions(form));
    } catch {
      // 父层已 toast 具体原因；这里只解除 pending 让用户改了重试
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onCancel()}>
      <DialogContent className="flex max-h-[88vh] flex-col gap-0 overflow-hidden p-0 sm:max-w-2xl">
        {/* 名称即标题：与任务创建抽屉同款无边框大标题输入（标题语义留给 sr-only，
            视觉上第一行就是命名，说明行只讲「怎么算存好」） */}
        <DialogHeader className="shrink-0 gap-0 border-b px-6 pt-5 pb-4 pr-14">
          <DialogTitle className="sr-only">
            {mode === "edit" ? "编辑筛选器" : "保存筛选器"}
          </DialogTitle>
          <Input
            id="saved-filter-name"
            aria-label="筛选器名称"
            autoFocus
            placeholder="名称（如：本周紧急）"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && name.trim()) void submit();
            }}
            className="h-9 border-0 bg-transparent px-0 text-xl font-semibold shadow-none focus-visible:ring-0 dark:bg-transparent"
          />
          <p className="mt-1 text-[11px] text-muted-foreground">
            填写名称即可保存；条件不选即不限，随时从左侧「筛选器」回到这个切片
          </p>
        </DialogHeader>

        {/* 只有中段滚动：头部与底部动作条常驻，长表单不会把「保存」顶出视口 */}
        <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
          <div className="space-y-4">
            {/* 基础维度：状态 + 优先级下限 */}
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-1.5">
                <Label className="text-xs font-normal text-muted-foreground">状态</Label>
                <Select
                  value={form.status ?? "all"}
                  onValueChange={(v) => set("status", v === "all" ? null : v)}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">任意状态</SelectItem>
                    <SelectItem value="pending">待办</SelectItem>
                    <SelectItem value="doing">进行中</SelectItem>
                    <SelectItem value="done">已完成</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1.5">
                <Label className="text-xs font-normal text-muted-foreground">优先级</Label>
                <Select
                  value={form.priorityMin != null ? String(form.priorityMin) : "all"}
                  onValueChange={(v) => set("priorityMin", v === "all" ? null : Number(v))}
                >
                  <SelectTrigger className="w-full">
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
            </div>

            {/* 截止时间：相对窗口 / 逾期 / 绝对区间三选一（互斥，避免恒无命中） */}
            <section className="space-y-2">
              <SectionHeader title="截止时间" hint="N 天内 / 已逾期 / 区间，三选一">
                {(form.dueFrom != null || form.dueUntil != null) && (
                  <button
                    type="button"
                    onClick={() => setForm((f) => ({ ...f, dueFrom: null, dueUntil: null }))}
                    className="text-[11px] text-muted-foreground transition-colors hover:text-foreground"
                  >
                    清除区间
                  </button>
                )}
              </SectionHeader>
              <div className="flex flex-wrap items-center gap-1.5">
                <FilterChip
                  tone="danger"
                  active={form.overdueOnly}
                  onClick={() => toggleOverdue(!form.overdueOnly)}
                >
                  <TriangleAlert className="size-3" />
                  已逾期
                </FilterChip>
                {DUE_WINDOW_CHOICES.map((d) => (
                  <FilterChip
                    key={d}
                    active={form.dueWithinDays === d}
                    onClick={() => toggleDueWindow(form.dueWithinDays === d ? null : d)}
                  >
                    {d} 天内
                  </FilterChip>
                ))}
              </div>
              <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2">
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
                  placeholder="起始日"
                  quick={false}
                  className="h-8 w-full px-2.5 text-xs"
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
                  placeholder="结束日（不含）"
                  quick={false}
                  className="h-8 w-full px-2.5 text-xs"
                />
              </div>
              {form.dueFrom != null &&
                form.dueUntil != null &&
                form.dueFrom >= form.dueUntil && (
                  <p className="text-xs text-destructive">
                    起始不早于结束，该维度恒无命中（左闭右开）
                  </p>
                )}
            </section>

            {/* 范围：项目 / 标签（同维度任一命中，空选 = 不限） */}
            <section className="space-y-2">
              <SectionHeader title="范围" hint="同一维度内任一命中，不选 = 不限" />
              <div className="space-y-2">
                <div className="flex gap-2">
                  <span className="w-10 shrink-0 pt-1 text-xs text-muted-foreground">项目</span>
                  <div className="flex flex-wrap gap-1.5">
                    <FilterChip
                      active={form.projectIds.length === 0}
                      onClick={() => set("projectIds", [])}
                    >
                      任意
                    </FilterChip>
                    {projects.map((p) => (
                      <FilterChip
                        key={p.id}
                        active={form.projectIds.includes(p.id)}
                        accentColor={p.hex_color}
                        onClick={() =>
                          set(
                            "projectIds",
                            form.projectIds.includes(p.id)
                              ? form.projectIds.filter((id) => id !== p.id)
                              : [...form.projectIds, p.id],
                          )
                        }
                      >
                        {p.title}
                      </FilterChip>
                    ))}
                  </div>
                </div>

                {labels.length > 0 && (
                  <div className="flex gap-2">
                    <span className="w-10 shrink-0 pt-1 text-xs text-muted-foreground">标签</span>
                    <div className="flex flex-wrap gap-1.5">
                      <FilterChip
                        active={form.labelIds.length === 0}
                        onClick={() => set("labelIds", [])}
                      >
                        任意
                      </FilterChip>
                      {labels.map((l) => (
                        <FilterChip
                          key={l.id}
                          active={form.labelIds.includes(l.id)}
                          accentColor={l.hex_color}
                          onClick={() =>
                            set(
                              "labelIds",
                              form.labelIds.includes(l.id)
                                ? form.labelIds.filter((id) => id !== l.id)
                                : [...form.labelIds, l.id],
                            )
                          }
                        >
                          {l.title}
                        </FilterChip>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </section>

            {/* 创建/完成时间下限（绝对日期；完成维度下未完成任务恒不命中） */}
            <section className="space-y-2">
              <SectionHeader title="时间范围" hint="按创建 / 完成时间下限筛选" />
              <div className="grid gap-3 sm:grid-cols-2">
                <div className="space-y-1.5">
                  <span className="text-xs text-muted-foreground">创建晚于</span>
                  <DatePicker
                    value={msToDateInput(form.createdFrom)}
                    onChange={(v) => set("createdFrom", dateInputToMs(v))}
                    placeholder="不限"
                    quick={false}
                    className="h-8 w-full px-2.5 text-xs"
                  />
                </div>
                <div className="space-y-1.5">
                  <span className="text-xs text-muted-foreground">完成晚于</span>
                  <DatePicker
                    value={msToDateInput(form.doneFrom)}
                    onChange={(v) => set("doneFrom", dateInputToMs(v))}
                    placeholder="不限"
                    quick={false}
                    className="h-8 w-full px-2.5 text-xs"
                  />
                </div>
              </div>
            </section>

            {/* 属性：三个存在三态 + 收藏开关，两列对齐 */}
            <section className="space-y-2">
              <SectionHeader title="属性" hint="提醒 / 附件 / 子任务：不限 · 有 · 无" />
              <div className="grid gap-x-6 gap-y-2 sm:grid-cols-2">
                <TriStateRow
                  label="提醒"
                  value={form.hasReminder}
                  onChange={(v) => set("hasReminder", v)}
                />
                <TriStateRow
                  label="附件"
                  value={form.hasAttachment}
                  onChange={(v) => set("hasAttachment", v)}
                />
                <TriStateRow
                  label="未完成子任务"
                  value={form.hasOpenSubtask}
                  onChange={(v) => set("hasOpenSubtask", v)}
                />
                <div className="flex items-center gap-2">
                  <span className="w-24 shrink-0 text-xs text-muted-foreground">收藏</span>
                  <FilterChip
                    tone="favorite"
                    active={form.favoriteOnly}
                    onClick={() => set("favoriteOnly", !form.favoriteOnly)}
                  >
                    <Star className="size-3" />
                    仅收藏
                  </FilterChip>
                </div>
              </div>
            </section>
          </div>
        </div>

        <DialogFooter className="shrink-0 flex-row items-center justify-end gap-2 border-t bg-muted/30 px-6 py-3">
          <Button variant="outline" onClick={onCancel}>
            取消
          </Button>
          <Button disabled={!name.trim() || saving} onClick={() => void submit()}>
            {mode === "edit" ? "保存修改" : "保存"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
