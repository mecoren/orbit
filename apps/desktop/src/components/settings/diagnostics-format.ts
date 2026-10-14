/**
 * 诊断分区的纯格式化函数（可单测，不依赖 DOM）
 *
 * 口径：
 * - 体积按 1024 进制（KB/MB/GB），保留一位小数、去掉无意义的 `.0`；
 * - 负数/NaN 一律显示 `—`（后端读数异常时不要让界面出现 `NaN MB`）。
 */
const UNITS = ["B", "KB", "MB", "GB", "TB"] as const;

export function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return "—";
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  // 字节档不带小数（1 字节不是 1.0 字节）
  const text = unit === 0 ? String(Math.round(value)) : value.toFixed(1).replace(/\.0$/, "");
  return `${text} ${UNITS[unit]}`;
}

/** 行数：千分位分组（10000 → 10,000） */
export function formatCount(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  return Math.round(n).toLocaleString("en-US");
}
