/**
 * 节假日缓存查看纯函数（设置页「日历」分区的数据缓存卡与本单测共用）。
 *
 * 数据源 `holidays_list`（`cfg_holidays` 本地缓存，date 升序；空库回落
 * Rust 预置表）。只读聚合，不写库、不进同步白名单。
 */
import type { HolidayInfo } from "@/lib/tauri";

/** 缓存汇总：总数 + 放假/补班拆分 + 覆盖年份倒序 */
export interface HolidayCacheSummary {
  total: number;
  offDays: number;
  workdays: number;
  years: number[];
}

export function summarizeHolidayCache(list: HolidayInfo[]): HolidayCacheSummary {
  const years = [...new Set(list.map((h) => h.year))].sort((a, b) => b - a);
  return {
    total: list.length,
    offDays: list.filter((h) => h.is_holiday).length,
    workdays: list.filter((h) => !h.is_holiday).length,
    years,
  };
}

/** 按年分组（年份倒序，组内保持 date 升序；调用方传原序即可） */
export function groupHolidaysByYear(
  list: HolidayInfo[],
): { year: number; items: HolidayInfo[] }[] {
  const map = new Map<number, HolidayInfo[]>();
  for (const h of list) {
    const arr = map.get(h.year) ?? [];
    arr.push(h);
    map.set(h.year, arr);
  }
  return [...map.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([year, items]) => ({ year, items }));
}

/** YYYY-MM-DD → M月D日（年份由分组头承载，行内不重复；脏串原样返回） */
export function holidayMdLabel(date: string): string {
  const [y, m, d] = date.split("-");
  const mm = Number(m);
  const dd = Number(d);
  if (y === undefined || !Number.isInteger(mm) || !Number.isInteger(dd)) {
    return date;
  }
  return `${mm}月${dd}日`;
}
