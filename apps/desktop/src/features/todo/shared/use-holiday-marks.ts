/**
 * 节假日标记（日历视图 ⇄ 日期选择器共用同一份缓存）
 *
 * 单一数据源：queryKey `["holidays","list"]`——Rust 侧 `cfg_holidays` 本地缓存，
 * 空库回落预置表，每日守护 + 手动更新写入。日历视图的 `MonthCalendar` 与
 * 日期选择器的 `PickerCalendar` 都从这里取 marks，保证「休/班」徽标、休息日
 * 底色渲染在同一批数据上；更新侧只失效前缀 `["holidays"]`，两处同步刷新。
 */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";

import { holidaysList } from "@/lib/tauri";
import type { HolidayMark } from "@/components/business/month-calendar";

/** 节假日全量缓存 key（更新/失效按 `["holidays"]` 前缀操作） */
export const HOLIDAYS_LIST_KEY = ["holidays", "list"] as const;

export function useHolidayMarks(): Record<string, HolidayMark> {
  const { data } = useQuery({
    queryKey: HOLIDAYS_LIST_KEY,
    queryFn: holidaysList,
    staleTime: 5 * 60_000,
  });

  return useMemo(() => {
    const marks: Record<string, HolidayMark> = {};
    for (const h of data ?? []) {
      marks[h.date] = { isOffDay: h.is_holiday, name: h.name };
    }
    return marks;
  }, [data]);
}
