/**
 * 日期工具（本地时区口径的单一真相源）
 *
 * 收敛前 `startOfDay` 在 4 处、`formatYmd` 在 2 处各写一份（月历 / 日历视图 /
 * 快捷日期 / NLP 解析），口径漂移风险高；G1 周视图新增 `startOfWeek` 时一并
 * 收敛到本模块——日历（月/周/年/议程）、快捷日期、模板套用、NLP 解析统一引用。
 *
 * 约定（docs/03 + AGENTS「日期分桶按本地时区日界」）：
 * - 全部按**本地时区**取年月日，不涉及 UTC / 时区切换
 * - `startOfDay` / `startOfWeek` / `addDays` 恒返回**新实例**，调用方可安全 mutate
 * - `YYYY-MM-DD` 字符串字典序即时间序（周档区间过滤依赖此性质）
 */

const DAY_MS = 86_400_000;

/** 当日零点（本地时区） */
export function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/** 加/减 N 天，结果归零到当日零点 */
export function addDays(d: Date, n: number): Date {
  const x = startOfDay(d);
  x.setDate(x.getDate() + n);
  return x;
}

/**
 * 本周一零点（本地时区）
 *
 * 周一为首日，与月历网格列序（一 二 三 四 五 六 日）同口径；周日的
 * `getDay()` 为 0，`(0 + 6) % 7 = 6` → 退回本周一（周日是本周最后一天，
 * 不得前滚到下周）。
 */
export function startOfWeek(d: Date): Date {
  return addDays(d, -((d.getDay() + 6) % 7));
}

/** Date → 本地 YYYY-MM-DD（跨端字符串主键口径） */
export function formatYmd(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** due_date（本地毫秒）→ 本地 YYYY-MM-DD（按日聚合表的键，口径同 formatYmd） */
export function dayKey(ms: number): string {
  return formatYmd(new Date(ms));
}

/** 某日距今天的口语化天数（今天 / N天后 / N天前），按零点对齐取整 */
export function relativeLabel(date: Date): string {
  const diff = Math.round(
    (startOfDay(date).getTime() - startOfDay(new Date()).getTime()) / DAY_MS,
  );
  if (diff === 0) return "今天";
  return diff > 0 ? `${diff}天后` : `${-diff}天前`;
}

/** 中文日期标签（如 "9月6日"，不含年份——年维由所在视图标题承担） */
export function dayLabel(date: Date): string {
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

/**
 * 周区间中文标签（如 "9月1日 – 9月7日"）
 *
 * 跨年时起点前置年份（"2026年12月28日 – 1月3日"），同年不带年份——周档
 * 常在月/年边界翻页，跨年不带年份会出现"12月28日 – 1月3日"的歧义。
 */
export function weekRangeLabel(start: Date, end: Date): string {
  const head =
    start.getFullYear() === end.getFullYear()
      ? dayLabel(start)
      : `${start.getFullYear()}年${dayLabel(start)}`;
  return `${head} – ${dayLabel(end)}`;
}
