/**
 * PlanDayDialog — 规划今天（F3 日排程阶段一，docs/13 §五 F3 / §八 U3，ADR 0013）
 *
 * 本地启发式排程的只读预览：core 按五桶排序（逾期 → 今日截止 EDF → 纯日期
 * 截止 → 我的一天 → 未排期带时长，同档短任务优先）+ 硬约束（不排过去、
 * 工作窗挖午休、今日带时刻截止不越线）产出时段建议，每条带可解释理由徽标；
 * 放不下的进「未排入」区带原因，总量超容量给警示条。
 *
 * **阶段一只读**：不写库——应用（写 my_day_date + start_date，不改 due_date）
 * 属阶段二；弹窗内明确标注「预览」。写路径复用既有更新通道，零新协议。
 */
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CalendarClock, TriangleAlert } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { DAY_PLAN_DEFAULT_PREFS, dayPlanPreview, type DayPlanPrefs } from "@/lib/tauri";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { EmptyState } from "@/components/business/empty-state";

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
  const [prefs] = useState<DayPlanPrefs>(DAY_PLAN_DEFAULT_PREFS);

  const planQuery = useQuery({
    queryKey: ["day-plan", prefs],
    queryFn: () => dayPlanPreview(prefs, Date.now()),
    enabled: open,
    staleTime: 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const plan = planQuery.data;

  // 时间轴行： HH:mm – HH:mm + 标题 + 理由
  const rows = useMemo(() => plan?.slots ?? [], [plan]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <CalendarClock className="size-4 text-primary" />
            规划今天
            <span className="ml-auto text-xs font-normal text-muted-foreground">
              剩余可排 {plan ? plan.capacity_minutes : "–"} 分钟 · 候选{" "}
              {plan ? plan.load_minutes : "–"} 分钟
            </span>
          </DialogTitle>
          <DialogDescription>
            按逾期 → 截止 → 优先级与空档排出的建议（只读预览，暂不写入任务时间）。
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

            {/* 时间轴建议列表 */}
            {rows.length > 0 ? (
              <ul className="max-h-72 space-y-1 overflow-y-auto" data-testid="plan-slots">
                {rows.map((s) => (
                  <li
                    key={s.task_id}
                    className="flex items-center gap-2.5 rounded-md border px-3 py-2"
                  >
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

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            关闭
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
