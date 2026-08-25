/**
 * 时间展示助手（M4 Task 14）
 *
 * 相对时间口径与桌面 task-detail-drawer.tsx CommentsSection 完全一致：
 * <1min 刚刚；<1h N分钟前；<24h N小时前；<7d N天前；否则绝对日期 yyyy-MM-dd。
 */

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

/** 评论相对时间：刚刚/N分钟前/N小时前/N天前/yyyy-MM-dd（05 §4.3 评论行） */
export function formatRelativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < MIN) return "刚刚";
  if (diff < HOUR) return `${Math.floor(diff / MIN)}分钟前`;
  if (diff < DAY) return `${Math.floor(diff / HOUR)}小时前`;
  if (diff < 7 * DAY) return `${Math.floor(diff / DAY)}天前`;
  return formatDateTime(ms).slice(0, 10);
}

/** yyyy-MM-dd HH:mm 本地时区（提醒行展示 / picker 占位默认值共用） */
export function formatDateTime(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
