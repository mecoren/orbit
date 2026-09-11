/**
 * reschedule-due — 日历拖拽改期的时间语义（纯函数）
 *
 * 拖拽月格圆点到另一格 = 修改任务截止日期。时间语义（对齐视图内
 * 新增默认 18:00 与 QuickDateMenu date 档零点口径的折中）：
 * - 原截止有时间（非 00:00）→ 保留原时分秒，只换日期；
 * - 原截止为零点/无截止 → 目标日 18:00（「今日/本周截止」归一口径）。
 * 目标与原日期相同 → 返回 null（无变化，不写库）。
 */

/** 18:00:00 的日内毫秒数（视图默认截止时点） */
export const DEFAULT_DUE_TIME_MS = 18 * 3600_000;

/** 判断时间戳是否恰为本地零点（= 仅日期、无时刻语义） */
function isLocalMidnight(ms: number): boolean {
  const d = new Date(ms);
  return d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0 && d.getMilliseconds() === 0;
}

/** 拖拽改期：原 due 毫秒 + 目标日（任意时刻的 Date，取其本地日期）→ 新 due；无变化返回 null */
export function rescheduleDue(originalDue: number | null, targetDay: Date): number | null {
  const target = new Date(
    targetDay.getFullYear(),
    targetDay.getMonth(),
    targetDay.getDate(),
  );
  // 同日落回原处：无论原时刻语义如何都无变化（先判同日，零点分支才不会
  // 把「零点同日」误升级成 18:00 产生无意义写库）
  if (originalDue != null) {
    const orig = new Date(originalDue);
    const sameDay =
      orig.getFullYear() === target.getFullYear() &&
      orig.getMonth() === target.getMonth() &&
      orig.getDate() === target.getDate();
    if (sameDay) return null;
    if (isLocalMidnight(originalDue)) {
      return target.getTime() + DEFAULT_DUE_TIME_MS;
    }
    // 保留时刻：把原时刻分量（含秒/毫秒）拼到目标日
    const next = new Date(target);
    next.setHours(orig.getHours(), orig.getMinutes(), orig.getSeconds(), orig.getMilliseconds());
    return next.getTime();
  }
  return target.getTime() + DEFAULT_DUE_TIME_MS;
}
