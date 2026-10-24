/**
 * PlanDayDialog — 规划今天（F3，docs/13 §五 F3 / §八 U3，ADR 0013）
 *
 * 本地启发式排程：core 按五桶排序（逾期 → 今日截止 EDF → 纯日期截止 →
 * 我的一天 → 未排期带时长，同档短任务优先）+ 硬约束（不排过去、工作窗挖
 * 午休、今日带时刻截止不越线）产出时段建议，每条带可解释理由徽标；放不下
 * 的进「未排入」区带原因，总量超容量给警示条。
 *
 * **阶段二应用**：每条槽位带勾选（默认全选）→「应用」走 dayPlanApply——
 * 写 my_day_date + start_date、**不改 due_date**（core 单事务）；prev 快照
 * 经通用撤销栈回滚（Ctrl+Z）。应用后弹窗内即时重拉预览（候选集随 my_day/
 * start 变化收敛）。
 */
import { useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarClock, TriangleAlert } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DAY_PLAN_DEFAULT_PREFS,
  dayPlanApply,
  dayPlanPrefsGet,
  dayPlanPrefsSet,
  dayPlanPreview,
  todoTaskUpdate,
  type ApplySlotInput,
  type DayPlanPrefs,
} from "@/lib/tauri";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { EmptyState } from "@/components/business/empty-state";
import { pushUndo } from "../shared/undo-bridge";

interface PlanDayDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

/** 分钟数 → HH:mm（相对今天零点） */
function hhmmOf(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** 理由徽标的色调（逾期/截止 = 警示系；其余中性） */
function reasonTone(reason: string): string {
  if (reason.startsWith("已逾期")) return "bg-red-500/10 text-red-600 dark:text-red-400";
  if (reason.startsWith("截止")) return "bg-amber-500/15 text-amber-600 dark:text-amber-400";
  if (reason === "紧急优先" || reason === "高优先级")
    return "bg-primary/10 text-primary";
  return "bg-muted text-muted-foreground";
}

export function PlanDayDialog({ open, onOpenChange }: PlanDayDialogProps) {
  const qc = useQueryClient();
  // 阶段三：作息偏好从 cfg_kv 载入（单一来源）——预览/编辑/保存共用同一份，
  // 保存后 setPrefs 触发 queryKey 变化重拉预览
  const [prefs, setPrefs] = useState<DayPlanPrefs | null>(null);
  // 勾选集（task_id；默认全选——新预览到达时重置）
  const [checked, setChecked] = useState<ReadonlySet<number>>(new Set());
  const [applying, setApplying] = useState(false);
  // 阶段三作息编辑：null = 收起；展开时从 cfg_kv 载入当前偏好
  const [prefsOpen, setPrefsOpen] = useState(false);
  const [prefsDraft, setPrefsDraft] = useState<DayPlanPrefs | null>(null);
  const [prefsSaving, setPrefsSaving] = useState(false);

  useEffect(() => {
    if (open && prefs == null) {
      void dayPlanPrefsGet().then(setPrefs);
    }
  }, [open, prefs]);

  const planQuery = useQuery({
    queryKey: ["day-plan", prefs],
    queryFn: () => dayPlanPreview(prefs ?? DAY_PLAN_DEFAULT_PREFS, Date.now()),
    enabled: open && prefs != null,
    staleTime: 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const plan = planQuery.data;
  const slots = useMemo(() => plan?.slots ?? [], [plan]);

  // 新预览到达 → 勾选重置为全选（prev 集里已消失的 id 不残留）
  const slotIds = useMemo(() => new Set(slots.map((s) => s.task_id)), [slots]);
  const effectiveChecked = useMemo(() => {
    const next = new Set<number>();
    for (const id of slotIds) {
      if (checked.size === 0 || checked.has(id)) next.add(id);
    }
    return next;
  }, [checked, slotIds]);

  const toggle = (id: number) => {
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const openPrefs = () => {
    setPrefsDraft(prefs ?? DAY_PLAN_DEFAULT_PREFS);
    setPrefsOpen((v) => !v);
  };

  const savePrefs = async () => {
    if (prefsDraft == null || prefsSaving) return;
    setPrefsSaving(true);
    try {
      const saved = await dayPlanPrefsSet(prefsDraft);
      setPrefsDraft(saved);
      setPrefs(saved); // queryKey 变化 → 预览按新作息重拉
    } finally {
      setPrefsSaving(false);
    }
  };

  const applyChecked = async () => {
    if (applying || plan == null || effectiveChecked.size === 0) return;
    const dayStartMs = plan.day_start_ms;
    const picked: ApplySlotInput[] = slots
      .filter((s) => effectiveChecked.has(s.task_id))
      .map((s) => ({ task_id: s.task_id, start_ms: s.start_ms }));
    setApplying(true);
    try {
      const r = await dayPlanApply(dayStartMs, picked);
      const prevBy = new Map(r.applied.map((a) => [a.task_id, a]));
      pushUndo({
        label: "应用排程",
        count: r.applied.length,
        undo: async () => {
          // prev 快照逐条写回（core 只返回快照，撤销走既有更新通道）
          for (const a of r.applied) {
            const prev = prevBy.get(a.task_id);
            await todoTaskUpdate(a.task_id, {
              my_day_date: prev?.prev_my_day_date ?? null,
              start_date: prev?.prev_start_date ?? null,
            });
          }
        },
      });
      // 失效链（聚合事件）已刷任务缓存；预览自身键重拉（候选集已变化）
      await qc.invalidateQueries({ queryKey: ["day-plan"] });
    } finally {
      setApplying(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <CalendarClock className="size-4 text-primary" />
            规划今天
            <button
              type="button"
              onClick={() => void openPrefs()}
              className={cn(
                "ml-auto rounded-md px-2 py-0.5 text-xs",
                prefsOpen
                  ? "bg-primary/10 font-medium text-primary"
                  : "text-muted-foreground hover:bg-accent/50",
              )}
            >
              作息
            </button>
            <span className="text-xs font-normal text-muted-foreground">
              剩余可排 {plan ? plan.capacity_minutes : "–"} 分钟 · 候选{" "}
              {plan ? plan.load_minutes : "–"} 分钟
            </span>
          </DialogTitle>
          <DialogDescription>
            勾选要排入的建议——应用后写入「开始时间 + 我的一天」，不改变截止日期（Ctrl+Z 可撤销）。
          </DialogDescription>
        </DialogHeader>

        {planQuery.isPending || plan == null ? (
          <div className="grid place-items-center py-10">
            <EqualizerLoader />
          </div>
        ) : plan.slots.length === 0 && plan.unscheduled.length === 0 ? (
          <div className="py-6">
            <EmptyState
              icon={CalendarClock}
              title="没有可规划的任务"
              hint="给任务设置截止日期、加入我的一天或填写预计时长后，这里会给出排程建议"
            />
          </div>
        ) : (
          <>
            {plan.overloaded && (
              <div className="flex items-center gap-2 rounded-md bg-amber-500/10 px-3 py-2 text-xs text-amber-600 dark:text-amber-400">
                <TriangleAlert className="size-3.5 shrink-0" />
                候选总量超出今日剩余容量 {plan.load_minutes - plan.capacity_minutes} 分钟——
                建议把低优先级项移到明天。
              </div>
            )}

            {/* 时间轴建议列表（勾选即选入应用集） */}
            {slots.length > 0 ? (
              <ul className="max-h-72 space-y-1 overflow-y-auto" data-testid="plan-slots">
                {slots.map((s) => (
                  <li
                    key={s.task_id}
                    className="flex items-center gap-2.5 rounded-md border px-3 py-2"
                  >
                    <Checkbox
                      checked={effectiveChecked.has(s.task_id)}
                      onCheckedChange={() => toggle(s.task_id)}
                      aria-label={`选择 ${s.title}`}
                    />
                    <span className="w-28 shrink-0 text-xs tabular-nums text-muted-foreground">
                      {hhmmOf(s.start_ms)} – {hhmmOf(s.end_ms)}
                    </span>
                    <span className="min-w-0 flex-1 truncate text-sm">{s.title}</span>
                    <span
                      className={cn(
                        "shrink-0 rounded-md px-1.5 py-0.5 text-[10px]",
                        reasonTone(s.reason),
                      )}
                    >
                      {s.reason}
                    </span>
                  </li>
                ))}
              </ul>
            ) : null}

            {/* 未排入区（放不下/越线，带原因） */}
            {plan.unscheduled.length > 0 && (
              <div>
                <p className="mb-1 text-xs text-muted-foreground">
                  未排入（{plan.unscheduled.length}）
                </p>
                <ul className="max-h-32 space-y-1 overflow-y-auto">
                  {plan.unscheduled.map((u) => (
                    <li
                      key={u.task_id}
                      className="flex items-center gap-2 rounded-md border border-dashed px-3 py-1.5 text-xs text-muted-foreground"
                    >
                      <span className="min-w-0 flex-1 truncate">{u.title}</span>
                      <span className="shrink-0">{u.reason}</span>
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </>
        )}

        {/* 阶段三作息编辑：cfg_kv 本机偏好（不同步），保存即重拉预览 */}
        {prefsOpen && prefsDraft != null && (
          <div className="space-y-2 rounded-lg border p-3" data-testid="plan-prefs">
            <div className="grid grid-cols-2 gap-2">
              <PrefSelect
                label="工作开始"
                value={prefsDraft.work_start_minute}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, work_start_minute: v })}
              />
              <PrefSelect
                label="工作结束"
                value={prefsDraft.work_end_minute}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, work_end_minute: v })}
              />
              <PrefSelect
                label="午休开始"
                value={prefsDraft.lunch_start_minute}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, lunch_start_minute: v })}
              />
              <PrefSelect
                label="午休结束"
                value={prefsDraft.lunch_end_minute}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, lunch_end_minute: v })}
              />
              <PrefSelect
                label="排程粒度"
                value={prefsDraft.granularity_minutes}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, granularity_minutes: v })}
                options={[5, 10, 15, 30, 60]}
              />
              <PrefSelect
                label="无时长兜底"
                value={prefsDraft.default_task_minutes}
                onChange={(v) => setPrefsDraft({ ...prefsDraft, default_task_minutes: v })}
                options={[15, 30, 45, 60, 90, 120]}
              />
            </div>
            <div className="flex items-center justify-between">
              <label className="flex items-center gap-2 text-sm">
                <Checkbox
                  checked={prefsDraft.include_overdue}
                  onCheckedChange={(v) =>
                    setPrefsDraft({ ...prefsDraft, include_overdue: v === true })
                  }
                />
                把逾期任务纳入排程
              </label>
              <Button
                size="sm"
                disabled={prefsSaving}
                onClick={() => void savePrefs()}
              >
                {prefsSaving ? "保存中…" : "保存作息"}
              </Button>
            </div>
            <p className="text-[10px] text-muted-foreground">
              作息保存在本机（不参与云同步），越界值保存时自动回落默认。
            </p>
          </div>
        )}

        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            关闭
          </Button>
          <Button
            disabled={applying || effectiveChecked.size === 0}
            onClick={() => void applyChecked()}
          >
            {applying
              ? "应用中…"
              : `应用到 ${effectiveChecked.size} 条任务`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** 作息档位选择（半小时时间档或给定数值档） */
function PrefSelect({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: number;
  onChange: (v: number) => void;
  /** 给定数值档（粒度/兜底时长）；缺省 = 时间半小时档 */
  options?: number[];
}) {
  const opts = options ?? Array.from({ length: 48 }, (_, i) => i * 30);
  const labelOf = (v: number) =>
    options
      ? `${v} 分钟`
      : `${String(Math.floor(v / 60) % 24).padStart(2, "0")}:${String(v % 60).padStart(2, "0")}`;
  const id = `plan-pref-${label}`;
  return (
    <div className="space-y-1">
      <label className="text-xs text-muted-foreground" htmlFor={id}>
        {label}
      </label>
      <Select value={String(value)} onValueChange={(v) => onChange(Number(v))}>
        <SelectTrigger id={id} className="w-full">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {opts.map((o) => (
            <SelectItem key={o} value={String(o)}>
              {labelOf(o)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}
