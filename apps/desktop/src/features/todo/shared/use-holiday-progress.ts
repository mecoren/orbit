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
 */
import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

import type { HolidayProgress } from "@/lib/tauri";

/** 进度事件名（与 Rust 侧 `emit("holiday-progress", ..)` 严格一致） */
export const HOLIDAY_PROGRESS_EVENT = "holiday-progress";

export interface HolidayProgressState {
  /** 最新一条进度；null = 未开始或已复位 */
  progress: HolidayProgress | null;
  /** 复位（收起进度区时调用） */
  clear: () => void;
}

export function useHolidayProgress(): HolidayProgressState {
  const [progress, setProgress] = useState<HolidayProgress | null>(null);

  useEffect(() => {
    const unlistenPromise = listen<HolidayProgress>(
      HOLIDAY_PROGRESS_EVENT,
      (evt) => setProgress(evt.payload),
    );
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, []);

  return { progress, clear: () => setProgress(null) };
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
