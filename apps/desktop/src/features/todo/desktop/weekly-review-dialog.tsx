/**
 * WeeklyReviewDialog — 引导式周回顾向导（G5）
 *
 * GTD 周回顾的产品化：三步引导（逾期处置 → 无日期排期 → 停滞唤醒），
 * 每步列出待处置任务并给「一键处理」快捷动作，免用户逐清单翻找。
 *
 * - 步骤 1 逾期：复用 G1 顺延（顺延到今天/明天）或逐条清（跳过）；
 * - 步骤 2 无日期：逐条排「今天/明天/下周」或跳过（保留无日期）；
 * - 步骤 3 停滞：逐条「动一动」（更新 updated_at 唤醒）或跳过。
 *
 * 写路径走既有 todoTaskUpdate / rolloverOverdueTasks，零 core 改动。
 */
import { useMemo, useState } from "react";
import { ArrowRight, CheckCircle2, Clock, ListTodo, TriangleAlert } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { type TodoTaskListItem } from "@/lib/tauri";
import { todoTaskUpdate } from "@/lib/tauri";
import { collectWeeklyReview } from "../shared/weekly-review";
import { rolloverOverdueTasks } from "../shared/batch-actions";
import { planRollover } from "../shared/rollover-overdue";

/** 向导三步 */
type ReviewStep = "overdue" | "undated" | "stalled";

interface WeeklyReviewDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 内存任务集（回顾清单在其上归集） */
  tasks: TodoTaskListItem[];
  /** 标题前缀（默认「周回顾」；回顾中心按项目发起时传项目名） */
  heading?: string;
  /** 向导走完最后一步时回调（项目回顾在此标记 review_last_at） */
  onFinish?: () => void | Promise<void>;
}

/** 每步的标题/图标/说明 */
const STEP_META: Record<ReviewStep, { title: string; icon: typeof TriangleAlert; desc: string }> = {
  overdue: { title: "逾期任务", icon: TriangleAlert, desc: "这些任务已过截止还没完成——顺延到今天/明天，或逐条决定去留" },
  undated: { title: "无日期任务", icon: ListTodo, desc: "没有截止日的任务容易被遗忘——给它们排个日期，或先留着" },
  stalled: { title: "停滞任务", icon: Clock, desc: "超过 7 天没动过的任务——碰一下表示「还在关注」，或关掉别再看" },
};

const STEP_ORDER: ReviewStep[] = ["overdue", "undated", "stalled"];

/** 无日期/停滞档的排期快捷（与批量改期档同口径：今天/明天/下周一） */
function presetDueMs(preset: "today" | "tomorrow" | "nextWeek"): number {
  const now = new Date();
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const DAY = 86_400_000;
  switch (preset) {
    case "today":
      return day.getTime() + 18 * 3600_000;
    case "tomorrow":
      return day.getTime() + DAY + 18 * 3600_000;
    case "nextWeek": {
      const offset = (8 - day.getDay()) % 7 || 7;
      return day.getTime() + offset * DAY + 18 * 3600_000;
    }
  }
}

export function WeeklyReviewDialog({ open, onOpenChange, tasks, heading, onFinish }: WeeklyReviewDialogProps) {
  const qc = useQueryClient();
  const [stepIdx, setStepIdx] = useState(0);
  /** 已处置的任务 id（各步内「跳过/处理」都算处置，出清单） */
  const [handled, setHandled] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);

  const step: ReviewStep = STEP_ORDER[stepIdx];
  const meta = STEP_META[step];

  // 三组清单（含已处置过滤，随 handled 实时收缩）
  const buckets = useMemo(() => collectWeeklyReview(tasks), [tasks]);
  const currentList = useMemo(() => {
    const all = buckets[step];
    return all.filter((t) => !handled.has(t.id));
  }, [buckets, step, handled]);

  const totalRemaining = useMemo(
    () =>
      STEP_ORDER.reduce((n, s) => n + buckets[s].filter((t) => !handled.has(t.id)).length, 0),
    [buckets, handled],
  );

  /** 标记已处置并失效缓存 */
  const markHandled = (ids: number[], label: string) => {
    setHandled((prev) => {
      const next = new Set(prev);
      for (const id of ids) next.add(id);
      return next;
    });
    void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    if (ids.length > 0) toast.success(`${label} ${ids.length} 条`);
  };

  /** 步骤 1：顺延全部逾期（按实际写入行标记处置，不用「前 N 条」近似） */
  const handleRolloverAll = async (preset: "today" | "tomorrow") => {
    if (busy) return;
    setBusy(true);
    try {
      // 先算计划集：planRollover 会过滤「同日无变化」行，写入集与它同源
      const planIds = planRollover(currentList, preset).map((p) => p.task.id);
      await rolloverOverdueTasks(currentList, preset, qc);
      markHandled(planIds, preset === "today" ? "顺延到今天" : "顺延到明天");
    } finally {
      setBusy(false);
    }
  };

  /** 步骤 2/3：单条排期 / 唤醒 */
  const handleSetDue = async (t: TodoTaskListItem, preset: "today" | "tomorrow" | "nextWeek") => {
    if (busy) return;
    setBusy(true);
    try {
      await todoTaskUpdate(t.id, { due_date: presetDueMs(preset) });
      markHandled([t.id], "已排期");
    } catch (e) {
      console.error("排期失败:", e);
    } finally {
      setBusy(false);
    }
  };

  /** 步骤 3：唤醒（touch updated_at，数据模型写 updated_at 由更新路径自动带） */
  const handleWake = async (t: TodoTaskListItem) => {
    if (busy) return;
    setBusy(true);
    try {
      // 空 patch 仍走 update 通道（core 对每条写都刷 updated_at），表示「动过」
      await todoTaskUpdate(t.id, {});
      markHandled([t.id], "已唤醒");
    } catch (e) {
      console.error("唤醒失败:", e);
    } finally {
      setBusy(false);
    }
  };

  /** 跳过单条（出清单，不动数据） */
  const handleSkip = (t: TodoTaskListItem) => markHandled([t.id], "已跳过");

  const goNext = () => {
    if (stepIdx < STEP_ORDER.length - 1) setStepIdx(stepIdx + 1);
    else {
      onOpenChange(false);
      setStepIdx(0);
      setHandled(new Set());
      toast.success(`${heading ?? "周回顾"}完成`, { description: "清单已收拢，保持节奏" });
      void onFinish?.();
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        onOpenChange(o);
        if (!o) {
          setStepIdx(0);
          setHandled(new Set());
        }
      }}
    >
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <meta.icon className="size-4 text-primary" />
            {heading ?? "周回顾"} · {meta.title}
            <span className="ml-auto text-xs font-normal text-muted-foreground">
              第 {stepIdx + 1} / {STEP_ORDER.length} 步
            </span>
          </DialogTitle>
          <DialogDescription>{meta.desc}</DialogDescription>
        </DialogHeader>

        {/* 步骤进度指示 */}
        <div className="flex items-center gap-1.5">
          {STEP_ORDER.map((s, i) => (
            <div
              key={s}
              className={`h-1.5 flex-1 rounded-full ${i <= stepIdx ? "bg-primary" : "bg-muted"}`}
            />
          ))}
        </div>

        {/* 本步清单 */}
        <div className="max-h-64 overflow-y-auto">
          {currentList.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-muted-foreground">
              <CheckCircle2 className="size-8 text-success" />
              <p className="text-sm">{meta.title}已处理完</p>
            </div>
          ) : (
            <ul className="space-y-1.5">
              {currentList.map((t) => (
                <li key={t.id} className="flex items-center gap-2 rounded-md border px-2.5 py-1.5">
                  <span className="flex-1 truncate text-sm">{t.title}</span>
                  {step === "overdue" && (
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => void handleSetDue(t, "today")}>
                      今天
                    </Button>
                  )}
                  {step === "undated" && (
                    <>
                      <Button size="sm" variant="ghost" disabled={busy} onClick={() => void handleSetDue(t, "today")}>
                        今天
                      </Button>
                      <Button size="sm" variant="ghost" disabled={busy} onClick={() => void handleSetDue(t, "tomorrow")}>
                        明天
                      </Button>
                    </>
                  )}
                  {step === "stalled" && (
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => void handleWake(t)}>
                      动一动
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" disabled={busy} onClick={() => handleSkip(t)}>
                    跳过
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </div>

        <DialogFooter className="gap-2">
          {step === "overdue" && currentList.length > 0 && (
            <>
              <Button variant="outline" disabled={busy} onClick={() => void handleRolloverAll("today")}>
                全部顺延到今天
              </Button>
              <Button variant="outline" disabled={busy} onClick={() => void handleRolloverAll("tomorrow")}>
                全部顺延到明天
              </Button>
            </>
          )}
          <Button className="ml-auto" disabled={busy} onClick={goNext}>
            {stepIdx < STEP_ORDER.length - 1 ? (
              <>
                下一步 <ArrowRight className="size-4" />
              </>
            ) : (
              "完成回顾"
            )}
          </Button>
        </DialogFooter>

        {totalRemaining > 0 && stepIdx === STEP_ORDER.length - 1 && (
          <p className="text-xs text-muted-foreground">
            还有 {totalRemaining} 条未处置（可在各步跳过保留）——回顾重在节奏，不必一次清零。
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}
