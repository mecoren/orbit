/**
 * timeslot-drag 单测：吸附 / 跨列夹取 / 倒推块落库口径（固定日期锁定）。
 */
import { describe, expect, it } from "vitest";

import type { TodoTask } from "@/lib/tauri";
import {
  MAX_SLOT_MINUTES,
  MIN_SLOT_MINUTES,
  resolveTimeslotMove,
  resolveTimeslotResize,
  snapDayDelta,
  snapMinutesDelta,
  SNAP_MINUTES,
  timeslotDropPatch,
} from "./timeslot-drag";
import { DEFAULT_BLOCK_MINUTES, type TaskTimeBlock } from "./time-block";

const HOUR_PX = 48;
/** 2026-10-05 周一 */
const MONDAY = new Date(2026, 9, 5);
const MON0 = MONDAY.getTime();
const at = (d: number, h: number, m = 0) => new Date(2026, 9, 5 + d, h, m).getTime();

function block(partial: Partial<TaskTimeBlock> = {}): TaskTimeBlock {
  return {
    taskId: 1,
    title: "t",
    startMs: at(0, 17),
    durationMin: 60,
    done: false,
    dayStartMs: MON0,
    ...partial,
  };
}

function task(partial: Partial<TodoTask> = {}): TodoTask {
  return {
    id: 1,
    uuid: "u",
    title: "t",
    description: null,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    repeat_after: 0,
    repeat_mode: 0,
    repeat_weekdays: 0,
    repeat_end_type: 0,
    repeat_end_param: 0,
    repeat_from_done: 0,
    repeat_month_mode: 0,
    repeat_nth_week: 0,
    percent_done: 0,
    position: 0,
    is_favorite: 0,
    my_day_date: null,
    duration_minutes: null,
    is_deleted: 0,
    created_at: 0,
    updated_at: 0,
    deleted_at: null,
    version: 1,
    ...partial,
  } as TodoTask;
}

describe("吸附粒度", () => {
  it("纵向位移 → 15 分钟整数倍（就近吸附）", () => {
    expect(SNAP_MINUTES).toBe(15);
    expect(snapMinutesDelta(HOUR_PX, HOUR_PX)).toBe(60);
    expect(snapMinutesDelta(HOUR_PX * 0.5, HOUR_PX)).toBe(30);
    // 24px = 30 分钟 → 2 格 = 30；7px（14 分钟）就近吸到 15
    expect(snapMinutesDelta(HOUR_PX * 0.25, HOUR_PX)).toBe(15);
    expect(snapMinutesDelta(7, HOUR_PX)).toBe(15);
    expect(snapMinutesDelta(-7, HOUR_PX)).toBe(-15);
    // 24h 满格 = 96 格
    expect(snapMinutesDelta(HOUR_PX * 24, HOUR_PX)).toBe(24 * 60);
  });

  it("非法几何 → 0（防 NaN 传播到写库）", () => {
    expect(snapMinutesDelta(Number.NaN, HOUR_PX)).toBe(0);
    expect(snapMinutesDelta(HOUR_PX, 0)).toBe(0);
    expect(snapMinutesDelta(HOUR_PX, Number.NaN)).toBe(0);
  });

  it("横向位移 → 整列偏移，边界夹取（跨周无落点）", () => {
    const COL = 120;
    expect(snapDayDelta(COL, COL, 7, 0)).toBe(1);
    expect(snapDayDelta(COL * 3.4, COL, 7, 0)).toBe(3);
    expect(snapDayDelta(-COL * 2, COL, 7, 4)).toBe(-2);
    // 左越界：列 0 不能再往左
    expect(snapDayDelta(-COL * 5, COL, 7, 1)).toBe(-1);
    // 右越界：末列不能再往右
    expect(snapDayDelta(COL * 5, COL, 7, 5)).toBe(1);
    expect(snapDayDelta(100, 0, 7, 0)).toBe(0);
    expect(snapDayDelta(100, COL, 0, 0)).toBe(0);
  });
});

describe("resolveTimeslotMove（移动落点）", () => {
  const grid = { hourPx: HOUR_PX, columnWidthPx: 120 };

  it("同列竖移：起点按吸附增量平移，时长不变", () => {
    const b = block();
    const r = resolveTimeslotMove(b, 0, 7, { x: 0, y: HOUR_PX }, grid);
    expect(r.startMs).toBe(at(0, 18));
    expect(r.durationMin).toBe(60);
    expect(r.dayIndex).toBe(0);
    expect(r.dayStartMs).toBe(MON0);
  });

  it("跨列落点：横移 2 列 + 竖移 30 分钟", () => {
    const r = resolveTimeslotMove(block(), 0, 7, { x: 250, y: HOUR_PX / 2 }, grid);
    expect(r.dayIndex).toBe(2);
    expect(r.dayStartMs).toBe(at(2, 0));
    expect(r.startMs).toBe(at(2, 17, 30));
  });

  it("顶/底夹取：起点不早于 00:00，块不越过 24:00", () => {
    // 起点 17:00 上拖 3 小时 → 14:00（未越界）
    expect(resolveTimeslotMove(block(), 0, 7, { x: 0, y: -HOUR_PX * 3 }, grid).startMs).toBe(
      at(0, 14),
    );
    // 上拖 24 小时 → 夹到当日 00:00
    expect(resolveTimeslotMove(block(), 0, 7, { x: 0, y: -HOUR_PX * 30 }, grid).startMs).toBe(
      at(0, 0),
    );
    // 下拖 24 小时 + 时长 60 分钟 → 起点夹到 23:00（块完整落在列内）
    expect(resolveTimeslotMove(block(), 0, 7, { x: 0, y: HOUR_PX * 30 }, grid).startMs).toBe(
      at(0, 23),
    );
  });

  it("跨列越界夹回边界列（不产生跨周落点）", () => {
    // 末列（周日）的块向右拖 5 列：夹回末列
    const r = resolveTimeslotMove(block({ startMs: at(6, 17), dayStartMs: at(6, 0) }), 6, 7, { x: 600, y: 0 }, grid);
    expect(r.dayIndex).toBe(6);
    expect(r.dayStartMs).toBe(at(6, 0));
    const left = resolveTimeslotMove(block(), 0, 7, { x: -600, y: 0 }, grid);
    expect(left.dayIndex).toBe(0);
    expect(left.dayStartMs).toBe(at(0, 0));
  });

  it("零位移 → 原起点原列（无变化由 timeslotDropPatch 兜底判空）", () => {
    const r = resolveTimeslotMove(block(), 0, 7, { x: 0, y: 0 }, grid);
    expect(r.startMs).toBe(at(0, 17));
    expect(r.dayIndex).toBe(0);
  });
});

describe("resolveTimeslotResize（底边改时长）", () => {
  it("下拖 30 分钟 → 时长 +30（起点不动）", () => {
    expect(resolveTimeslotResize(block(), HOUR_PX / 2, HOUR_PX).durationMin).toBe(90);
    expect(resolveTimeslotResize(block(), HOUR_PX * 2, HOUR_PX).durationMin).toBe(180);
  });

  it("夹到 [15, 1440] 分钟", () => {
    expect(resolveTimeslotResize(block(), -HOUR_PX * 5, HOUR_PX).durationMin).toBe(
      MIN_SLOT_MINUTES,
    );
    expect(resolveTimeslotResize(block(), HOUR_PX * 48, HOUR_PX).durationMin).toBe(
      MAX_SLOT_MINUTES,
    );
  });

  it("短块拖到底也保底 15 分钟（不塌成 0）", () => {
    expect(
      resolveTimeslotResize(block({ durationMin: 15 }), -HOUR_PX, HOUR_PX).durationMin,
    ).toBe(MIN_SLOT_MINUTES);
  });
});

describe("timeslotDropPatch（落库口径）", () => {
  it("显式 start 块：移动改 start_date、resize 改 duration_minutes", () => {
    const t = task({ start_date: at(0, 17), duration_minutes: 60 });
    // 移动 1 小时
    expect(timeslotDropPatch(t, { startMs: at(0, 18), durationMin: 60 })).toEqual({
      start_date: at(0, 18),
    });
    // 改时长 90 分钟
    expect(timeslotDropPatch(t, { startMs: at(0, 17), durationMin: 90 })).toEqual({
      duration_minutes: 90,
    });
    // 两者同时
    expect(timeslotDropPatch(t, { startMs: at(0, 18), durationMin: 90 })).toEqual({
      start_date: at(0, 18),
      duration_minutes: 90,
    });
  });

  it("倒推块（due 带时刻）：移动改 due_date，不种 start_date", () => {
    const t = task({ due_date: at(0, 18), duration_minutes: 60 });
    const patch = timeslotDropPatch(t, { startMs: at(0, 19), durationMin: 60 });
    expect(patch).toEqual({ due_date: at(0, 20) });
    expect(patch?.start_date).toBeUndefined();
  });

  it("倒推块改时长：due 随之平移（块起点不变）", () => {
    // 原 due 18:00 / 60 分 → 块起点 17:00；时长改 90 → due 应为 18:30
    const t = task({ due_date: at(0, 18), duration_minutes: 60 });
    expect(timeslotDropPatch(t, { startMs: at(0, 17), durationMin: 90 })).toEqual({
      duration_minutes: 90,
      due_date: at(0, 18, 30),
    });
  });

  it("未设时长（渲染按默认 30）落库时写显式时长 + due 平移", () => {
    const t = task({ due_date: at(0, 18) });
    expect(DEFAULT_BLOCK_MINUTES).toBe(30);
    // 当前块起点 = 18:00 − 30（未设时长按默认块长渲染）
    const blockStart = at(0, 17, 30);
    // 原样落回：起点与默认块长都没变，但 duration_minutes 列是 null ≠ 30
    // → 须显式写入（补齐列值），due 保持 18:00
    expect(timeslotDropPatch(t, { startMs: blockStart, durationMin: 30 })).toEqual({
      duration_minutes: 30,
      due_date: at(0, 18),
    });
  });

  it("无变化 → null（不写库）", () => {
    const t = task({ start_date: at(0, 17), duration_minutes: 60 });
    expect(timeslotDropPatch(t, { startMs: at(0, 17), durationMin: 60 })).toBeNull();
  });

  it("纯日期任务（无带时刻 start/due）拖动只落时长，不臆造时刻字段", () => {
    const day0 = new Date(2026, 9, 5).getTime();
    const t = task({ start_date: day0, due_date: day0, duration_minutes: 60 });
    const patch = timeslotDropPatch(t, { startMs: day0, durationMin: 90 });
    expect(patch).toEqual({ duration_minutes: 90 });
  });
});
