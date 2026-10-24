/**
 * ReviewCenter — 回顾中心（F1 项目回顾节奏，docs/13 §五 F1 / §八 U1）
 *
 * OmniFocus Review 的本地等价物：每个项目自带回顾周期（todo_projects 三列），
 * 到期项目按「逾期天数」降序归集在此；逐项目走三步向导（复用周回顾组件，
 * 任务集按项目过滤），完成即标记 review_last_at（下次到期 = 今天 + 周期）。
 *
 * 入口：侧栏「回顾」壳层路由（与回收站/统计同构）；侧栏项目行的「待回顾」
 * 点徽标直达这里。数据真值（到期/逾期/计数）全部来自 core
 * project_review_api，前端零口径复刻。
 */
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarCheck, CheckCheck, Clock3 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/business/empty-state";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import {
  todoProjectMarkReviewed,
  todoProjectSnoozeReview,
  todoProjectsDueForReview,
  type ProjectReviewStatus,
} from "@/lib/tauri";
import { TODO_ACCENT } from "../shared/constants";
import {
  formatLastReviewed,
  formatOverdueDays,
  formatReviewInterval,
} from "../shared/project-review";
import { useTodoShell } from "./todo-shell";
import { WeeklyReviewDialog } from "./weekly-review-dialog";

/** 到期清单查询键：挂 ["todo-project"] 前缀下，db-change 表级失效自动覆盖
 *  （todo_projects 写事件刷它；todo_tasks 侧的映射另补了本键，计数随之收敛） */
export const REVIEW_DUE_QUERY_KEY = ["todo-project", "review-due"] as const;

/** 稍后一周（暂缓档与移动端一致） */
const SNOOZE_DAYS = 7;

export function ReviewPanel() {
  const qc = useQueryClient();
  const { tasks } = useTodoShell();
  const [reviewing, setReviewing] = useState<ProjectReviewStatus | null>(null);
  const [busyId, setBusyId] = useState<number | null>(null);

  const dueQuery = useQuery({
    queryKey: REVIEW_DUE_QUERY_KEY,
    queryFn: () => todoProjectsDueForReview(Date.now()),
    staleTime: 60 * 1000,
  });

  /** 向导任务集：按项目过滤（回顾的是「这个项目里的待处置」，
   *  与 collectWeeklyReview 的三桶口径天然兼容——它只消费传入集合） */
  const reviewingTasks = useMemo(
    () => (reviewing == null ? [] : tasks.filter((t) => t.project_id === reviewing.project.id)),
    [tasks, reviewing],
  );

  const refresh = () => qc.invalidateQueries({ queryKey: REVIEW_DUE_QUERY_KEY });

  const handleSnooze = async (status: ProjectReviewStatus) => {
    if (busyId != null) return;
    setBusyId(status.project.id);
    try {
      await todoProjectSnoozeReview(status.project.id, SNOOZE_DAYS, Date.now());
      await refresh();
    } finally {
      setBusyId(null);
    }
  };

  const handleMarkReviewed = async (status: ProjectReviewStatus) => {
    if (busyId != null) return;
    setBusyId(status.project.id);
    try {
      await todoProjectMarkReviewed(status.project.id);
      await refresh();
    } finally {
      setBusyId(null);
    }
  };

  /** 向导走完（或中途关闭后由完成按钮触达）才标记已回顾——
   *  关闭弹窗本身不标记（允许中途退出不推进周期） */
  const handleFinishReview = async () => {
    if (reviewing == null) return;
    const id = reviewing.project.id;
    setReviewing(null);
    await todoProjectMarkReviewed(id);
    await refresh();
  };

  const due = dueQuery.data;

  return (
    <div className="flex h-full flex-col">
      {/* 工具栏 */}
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
        <div className="flex items-baseline gap-2">
          <h1 className="text-lg font-semibold">回顾</h1>
          <span className="text-xs text-muted-foreground">
            {due ? `待回顾项目 ${due.length} 个` : "按项目周期归集到期回顾"}
          </span>
        </div>
      </div>

      {dueQuery.isPending ? (
        <div className="grid h-full place-items-center">
          <EqualizerLoader />
        </div>
      ) : due == null || due.length === 0 ? (
        <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto">
          <EmptyState
            icon={CalendarCheck}
            title="没有待回顾的项目"
            hint="在项目编辑里设置回顾周期（每周/每两周/每月），到期后会出现在这里"
          />
        </div>
      ) : (
        <ScrollArea className="min-h-0 flex-1">
          <ul className="mx-auto max-w-3xl space-y-2 p-4">
            {due.map((status) => (
              <li
                key={status.project.id}
                data-testid="review-row"
                className="rounded-lg border px-4 py-3"
              >
                <div className="flex items-center gap-2.5">
                  <span
                    className="size-2.5 shrink-0 rounded-full"
                    style={{ background: status.project.hex_color || TODO_ACCENT }}
                  />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium">{status.project.title}</p>
                    <p className="mt-0.5 text-xs text-muted-foreground">
                      {formatReviewInterval(status.project.review_interval_days)} ·{" "}
                      {formatLastReviewed(status.project.review_last_at)}
                      {status.open_task_count > 0 && ` · ${status.open_task_count} 件未完成`}
                    </p>
                  </div>
                  <span
                    className={cn(
                      "shrink-0 rounded-md px-2 py-0.5 text-xs tabular-nums",
                      status.overdue_days > 0
                        ? "bg-red-500/10 text-red-600 dark:text-red-400"
                        : "bg-primary/10 text-primary",
                    )}
                  >
                    {formatOverdueDays(status.overdue_days)}
                  </span>
                </div>
                <div className="mt-2.5 flex items-center justify-end gap-2">
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={busyId === status.project.id}
                    onClick={() => void handleSnooze(status)}
                  >
                    <Clock3 className="size-3.5" />
                    稍后一周
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={busyId === status.project.id}
                    onClick={() => void handleMarkReviewed(status)}
                  >
                    <CheckCheck className="size-3.5" />
                    已回顾
                  </Button>
                  <Button size="sm" variant="outline" onClick={() => setReviewing(status)}>
                    <CalendarCheck className="size-3.5" />
                    开始回顾
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        </ScrollArea>
      )}

      <WeeklyReviewDialog
        open={reviewing != null}
        onOpenChange={(o) => !o && setReviewing(null)}
        tasks={reviewingTasks}
        heading={reviewing ? `项目回顾 · ${reviewing.project.title}` : undefined}
        onFinish={() => void handleFinishReview()}
      />
    </div>
  );
}
