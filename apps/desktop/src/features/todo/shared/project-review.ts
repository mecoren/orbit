/**
 * 项目回顾节奏（F1）展示层纯函数——周期档位映射与行内文案。
 *
 * 到期/逾期的判定真值在 Rust core（project_review_api，本地时区日界），
 * 前端只做档位标签映射与相对时间文案；天数为唯一真值，label 仅是展示层
 * 映射（移动端 logic/project_review.dart 逐字同口径）。
 */

/** 回顾周期档位（与 core set_project_review_interval 语义一致：≤0 = 关闭） */
export const REVIEW_INTERVAL_PRESETS: readonly { days: number; label: string }[] = [
  { days: 1, label: "每天" },
  { days: 7, label: "每周" },
  { days: 14, label: "每两周" },
  { days: 30, label: "每月" },
];

/** 「关闭回顾」档的 Select 哨兵值（Radix Select 不接受空串 value） */
export const REVIEW_OFF = "__off__";

/** 周期天数 → 档位标签；非档位天数回退「每 N 天」 */
export function formatReviewInterval(days: number | null | undefined): string {
  if (days == null || days <= 0) return "关闭";
  const preset = REVIEW_INTERVAL_PRESETS.find((p) => p.days === days);
  return preset ? preset.label : `每 ${days} 天`;
}

/** 逾期天数 → 行内文案（0 = 今天到期；core overdue_days 同口径） */
export function formatOverdueDays(overdueDays: number): string {
  if (overdueDays <= 0) return "今天到期";
  if (overdueDays === 1) return "已逾期 1 天";
  return `已逾期 ${overdueDays} 天`;
}

/** 本地日差（两侧毫秒时间戳 → 日历天数差；用本地年月日拼 UTC 零点，
 *  不受 DST 偏移影响） */
function localDayDiff(aMs: number, bMs: number): number {
  const a = new Date(aMs);
  const b = new Date(bMs);
  const aDay = Date.UTC(a.getFullYear(), a.getMonth(), a.getDate());
  const bDay = Date.UTC(b.getFullYear(), b.getMonth(), b.getDate());
  return Math.round((aDay - bDay) / 86_400_000);
}

/** 上次回顾时间 → 相对文案（从未 / 今天 / 昨天 / N 天前 / 日期） */
export function formatLastReviewed(
  ms: number | null | undefined,
  nowMs: number = Date.now(),
): string {
  if (ms == null) return "从未回顾";
  const diff = localDayDiff(nowMs, ms);
  if (diff <= 0) return "今天回顾过";
  if (diff === 1) return "昨天回顾过";
  if (diff < 30) return `${diff} 天前回顾`;
  const d = new Date(ms);
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()} 回顾`;
}
