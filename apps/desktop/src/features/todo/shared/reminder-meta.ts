/**
 * reminder-meta —— 行内提醒展示元信息（列表行/看板卡/日历行共用）
 *
 * 任务可能有多条提醒（详情抽屉多提醒区），行内只展示一条：
 * - 有未来行 → 最近的未来一条（下一个将响的时刻）；
 * - 全部已过期 → 最早一条（fired=true 红色警示态：响过没处理/错过了）。
 * fired 判定叠加任务完成态——完成实例不再警示（P1#10 同口径），
 * 已完成任务的过期提醒按普通 muted 展示。
 *
 * 纯函数无 React/IPC 依赖，便于单测；数据经 useTaskReminders join。
 */

/** 行内展示所需的提醒行最小载荷（TodoReminder 结构子集） */
export interface TaskReminderMeta {
  id: number;
  remind_at: number;
  is_deleted: number;
}

/** 行内展示口径：一条提醒 + 派生态 */
export interface DisplayReminder {
  /** 选中展示的提醒行 id */
  id: number;
  /** HH:mm 文案 */
  clock: string;
  /** 已到期且任务未完成（红色警示态；完成/未来恒 false） */
  fired: boolean;
}

/** 提醒时刻 → HH:mm（zh-CN 2-digit；与 toast 副标题同口径） */
export function reminderClockLabel(remindAt: number): string {
  return new Date(remindAt).toLocaleString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * 行内展示选取：软删行过滤 → 未来最近 / 全过期最早 → fired 判定。
 * 无存活行返回 null（调用方不渲染）。
 */
export function displayReminder(
  rows: TaskReminderMeta[],
  nowMs: number,
  taskDone: boolean,
): DisplayReminder | null {
  const live = rows.filter((r) => !r.is_deleted);
  if (live.length === 0) return null;

  let pick: TaskReminderMeta;
  const future = live.filter((r) => r.remind_at > nowMs);
  if (future.length > 0) {
    // 未来最近一条（升序取首个）
    pick = future.reduce((a, b) => (a.remind_at <= b.remind_at ? a : b));
  } else {
    // 全部已过期：最早一条（系列首响时刻，展示「错过了什么」而非最后一响）
    pick = live.reduce((a, b) => (a.remind_at <= b.remind_at ? a : b));
  }
  return {
    id: pick.id,
    clock: reminderClockLabel(pick.remind_at),
    fired: !taskDone && pick.remind_at <= nowMs,
  };
}
