/**
 * 节假日范围补写进度（`holiday-progress` 事件 ⇄ 设置页进度区）
 *
 * 单一订阅点：core（`holiday_api` 进度广播）→ 桌面进度泵
 * （`commands/holiday_scheduler::holiday_progress_pump_start`）→ Tauri 事件
 * `holiday-progress`。事件只在「范围补写」期间产生（单年 / 立即更新不发），
 * 故消费方只有设置页一处。
 *
 * 终态（done / error）由消费方在收起进度区时调用 `clear()` 复位——此处不自动
 * 清除，避免「事件刚到就被清掉」导致用户看不到结果。
 *
 * `failedYears` 是**汇总结果的必要补充**：范围补写的终态 `done` 只带失败**计数**，
 * 而「哪一年失败」只出现在中间态的逐年事件里。消费方（设置页 toast）据此如实报出
 * 失败年份；熔断中止时未尝试的年份不会产生逐年事件，故该列表可能短于 `failed`
 * 计数（消费方不得据此反推「已全部列出」）。
 */
import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

import type { HolidayProgress } from "@/lib/tauri";

/** 进度事件名（与 Rust 侧 `emit("holiday-progress", ..)` 严格一致） */
export const HOLIDAY_PROGRESS_EVENT = "holiday-progress";

export interface HolidayProgressState {
  /** 最新一条进度；null = 未开始或已复位 */
  progress: HolidayProgress | null;
  /** 本轮范围补写中报告失败的年份（事件到达顺序，去重） */
  failedYears: number[];
}

export const INITIAL_HOLIDAY_PROGRESS: HolidayProgressState = {
  progress: null,
  failedYears: [],
};

/**
 * 进度事件 → 状态（纯函数，便于单测）：
 * `starting` 开启新一轮并清空失败年份；逐年失败追加年份；其余只换 `progress`。
 */
export function applyHolidayProgress(
  prev: HolidayProgressState,
  p: HolidayProgress,
): HolidayProgressState {
  if (p.phase === "starting") return { progress: p, failedYears: [] };
  if (p.phase === "year" && !p.ok) {
    return prev.failedYears.includes(p.year)
      ? { progress: p, failedYears: prev.failedYears }
      : { progress: p, failedYears: [...prev.failedYears, p.year] };
  }
  return { progress: p, failedYears: prev.failedYears };
}

/** 失败年份列表文案（升序、顿号分隔）；空数组返回空串 */
export function holidayFailedYearsLabel(years: number[]): string {
  return [...years].sort((a, b) => a - b).join("、");
}

export function useHolidayProgress(): HolidayProgressState & { clear: () => void } {
  const [state, setState] = useState<HolidayProgressState>(
    INITIAL_HOLIDAY_PROGRESS,
  );

  useEffect(() => {
    const unlistenPromise = listen<HolidayProgress>(
      HOLIDAY_PROGRESS_EVENT,
      (evt) => setState((prev) => applyHolidayProgress(prev, evt.payload)),
    );
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, []);

  return {
    ...state,
    clear: () => setState((prev) => ({ ...prev, progress: null })),
  };
}

/** 进度百分比（0-100）；非逐年阶段返回 null（进度区据此退化为不确定态） */
export function holidayProgressPercent(p: HolidayProgress | null): number | null {
  if (!p || p.phase === "done" || p.phase === "error") return null;
  if (p.phase === "starting") return 0;
  if (p.total <= 0) return null;
  return Math.min(100, Math.round((p.done / p.total) * 100));
}

/** 进度文案（纯函数，供进度区与单测共用） */
export function holidayProgressLabel(p: HolidayProgress | null): string {
  if (!p) return "";
  switch (p.phase) {
    case "starting":
      return `准备更新 ${p.total} 个年份…`;
    case "year": {
      const mark = p.ok ? (p.empty ? "无数据" : "完成") : "失败";
      return `已处理 ${p.done}/${p.total} 年（${p.year} 年 ${mark}）`;
    }
    case "done": {
      if (p.cancelled) return "已取消（已完成的年份保留）";
      const parts = [`成功 ${p.ok}`];
      if (p.failed > 0) parts.push(`失败 ${p.failed}`);
      return `更新完成：${parts.join(" · ")}`;
    }
    case "error":
      return p.message;
  }
}
