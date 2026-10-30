/**
 * 侧栏快捷视图角标口径（与移动端 sidebarCountsProvider 同口径）
 *
 * 角标回答「这一栏还剩多少要做」：全部/未完成共用未完成总数（与默认开启的
 * 「隐藏已完成」一致），已完成视图给完成数，今天/近7天把逾期也算进
 * （截止 < 明日零点 / 七日后零点）。各档 COUNT 由调用方用
 * `todoTaskOverview` 的谓词下推分别取，本函数只负责归一。
 */
import type { QuickViewKey } from "./constants";

export type QuickViewCounts = Record<QuickViewKey, number>;

/** 六路 overview COUNT 的原始读数（全部与未完成共用 undone） */
export interface QuickViewCountInput {
  undone: number;
  done: number;
  today: number;
  week: number;
  favorite: number;
  myDay: number;
}

export function buildQuickViewCounts(input: QuickViewCountInput): QuickViewCounts {
  return {
    all: input.undone,
    undone: input.undone,
    done: input.done,
    today: input.today,
    week: input.week,
    favorite: input.favorite,
    my_day: input.myDay,
  };
}
