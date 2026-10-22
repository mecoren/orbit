/**
 * TodayStrip — 今日上下文条（G2 正反馈 + G4 容量规划）
 *
 * 品类两处普遍缺口的合并落点：
 * - G2 情绪减负：打开应用先看到「今日已达成 N 项」的正向反馈，
 *   而不是只剩红色逾期与未完成堆积；
 * - G4 容量规划：把「今天装得下多少」量化为「今日已排 X / 预算 Y」，
 *   超载/偏紧档给醒目提示（My Day 类功能普遍只回答「做什么」）。
 *
 * 数据口径全在内存任务集上算（todayLoadMinutes / doneToday 计数），
 * 不引新查询、不改 core。预算落 localStorage（本机偏好，与
 * todo_view_mode 等视图态键同族），未设预算时容量档只报已排量。
 */
import { useEffect, useMemo, useState } from "react";
import { CircleCheck, Timer } from "lucide-react";

import { NumberInput } from "@/components/ui/number-input";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { type TodoTaskListItem } from "@/lib/tauri";
import {
  DEFAULT_CAPACITY_MINUTES,
  capacityHint,
  capacityStatus,
  todayLoadMinutes,
} from "../shared/capacity";

/** 每日容量预算（分钟）本机偏好键；未设 → null（不做超载判定） */
export const LS_CAPACITY_BUDGET = "todo_capacity_budget_minutes";

/** 读容量预算：缺省/非法/非正 → null（视同未设） */
export function loadCapacityBudget(raw: string | null): number | null {
  if (raw == null) return null;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : null;
}

interface TodayStripProps {
  /** 内存任务集（今日口径在本组件内算） */
  tasks: TodoTaskListItem[];
}

export function TodayStrip({ tasks }: TodayStripProps) {
  const [budgetInput, setBudgetInput] = useState<string>(() => {
    if (typeof window === "undefined") return "";
    const v = loadCapacityBudget(window.localStorage.getItem(LS_CAPACITY_BUDGET));
    return v == null ? "" : String(v);
  });

  // 预算落盘（空串 = 清除 → 容量档退化为「只报已排」）
  useEffect(() => {
    const n = loadCapacityBudget(budgetInput.trim() === "" ? null : budgetInput.trim());
    if (n == null) window.localStorage.removeItem(LS_CAPACITY_BUDGET);
    else window.localStorage.setItem(LS_CAPACITY_BUDGET, String(n));
  }, [budgetInput]);

  const { doneToday, loadMinutes, budgetMinutes, status } = useMemo(() => {
    const now = Date.now();
    const dayStart = new Date(now);
    dayStart.setHours(0, 0, 0, 0);
    const dayStartMs = dayStart.getTime();
    const doneToday = tasks.filter(
      (t) => t.done && t.done_at != null && t.done_at >= dayStartMs && t.done_at < dayStartMs + 86_400_000,
    ).length;
    const loadMinutes = todayLoadMinutes(tasks, now);
    const budgetMinutes = loadCapacityBudget(budgetInput.trim() === "" ? null : budgetInput.trim());
    return {
      doneToday,
      loadMinutes,
      budgetMinutes,
      status: capacityStatus(loadMinutes, budgetMinutes),
    };
  }, [tasks, budgetInput]);

  // 两项皆无内容（今天没达成也没排程）时整条不占位，避免空噪音
  if (doneToday === 0 && loadMinutes === 0 && budgetMinutes == null) return null;

  return (
    <div
      className="flex flex-wrap items-center gap-x-4 gap-y-1 border-b bg-muted/30 px-4 py-1.5 text-xs"
      data-testid="today-strip"
    >
      {/* G2 正反馈：今日已达成（绿调，数字为体） */}
      <Tooltip>
        <TooltipTrigger asChild>
          <span className="flex items-center gap-1.5 text-muted-foreground">
            <CircleCheck className="size-3.5 text-emerald-600" />
            今日已达成{" "}
            <b className={cn("tabular-nums", doneToday > 0 ? "text-emerald-600" : "text-muted-foreground")}>
              {doneToday}
            </b>{" "}
            项
          </span>
        </TooltipTrigger>
        <TooltipContent>今天完成的任务数（本地日界）</TooltipContent>
      </Tooltip>

      <span className="h-3 w-px bg-border" />

      {/* G4 容量：今日已排 vs 预算（超载/偏紧给色调提示） */}
      <Tooltip>
        <TooltipTrigger asChild>
          <span
            className={cn(
              "flex items-center gap-1.5",
              status.level === "over"
                ? "text-destructive"
                : status.level === "tight"
                  ? "text-amber-600"
                  : "text-muted-foreground",
            )}
          >
            <Timer className="size-3.5" />
            {capacityHint(loadMinutes, budgetMinutes)}
          </span>
        </TooltipTrigger>
        <TooltipContent>
          {status.level === "over"
            ? "已超出每日容量，考虑顺延部分任务或延长预算"
            : status.level === "tight"
              ? "接近每日容量上限"
              : "今日排程量按未完成任务的预计时长合计（未设时长不计）"}
        </TooltipContent>
      </Tooltip>

      {/* 预算编辑：分钟数直改（空 = 清除预算） */}
      <label className="ml-auto flex items-center gap-1.5 text-muted-foreground">
        每日容量
        <NumberInput
          value={budgetInput}
          onValueChange={setBudgetInput}
          min={1}
          step={15}
          placeholder={String(DEFAULT_CAPACITY_MINUTES)}
          className="h-6 w-16"
          ariaLabel="每日容量预算（分钟）"
        />
        <span className="tabular-nums">min</span>
      </label>
    </div>
  );
}
