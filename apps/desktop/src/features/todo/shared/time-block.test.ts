import { describe, expect, it } from "vitest";

import type { TodoTask } from "@/lib/tauri";
import {
  assignLanes,
  blockDayIndex,
  DEFAULT_BLOCK_MINUTES,
  hasTimePart,
  layoutTimeBlock,
  taskTimeBlock,
  type TaskTimeBlock,
} from "./time-block";

const DAY = 86_400_000;

/** 本地某日 HH:mm 的时间戳（避开 UTC 取模坑，构造即真值） */
function at(day: number, h: number, m = 0): number {
  const d = new Date(day);
  d.setHours(h, m, 0, 0);
  return d.getTime();
}
function day0(offset = 0): number {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime() + offset * DAY;
}

function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1,
    uuid: "u1",
    title: "任务",
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
  };
}

describe("hasTimePart（本地字段判时刻）", () => {
  it("纯日期（本地零点）→ false；带时分 → true", () => {
    expect(hasTimePart(day0())).toBe(false);
    expect(hasTimePart(at(day0(), 9, 30))).toBe(true);
    expect(hasTimePart(null)).toBe(false);
  });
});

describe("taskTimeBlock（块起算口径）", () => {
  it("start_date 带时刻 → 直接作起点，最优先", () => {
    const start = at(day0(), 14);
    const block = taskTimeBlock(mk({ start_date: start, due_date: at(day0(1), 9), duration_minutes: 90 }));
    expect(block).not.toBeNull();
    expect(block!.startMs).toBe(start);
    expect(block!.durationMin).toBe(90);
  });

  it("无 start、due 带时刻 + 时长 → 按截止倒推 due − 时长", () => {
    const due = at(day0(), 18);
    const block = taskTimeBlock(mk({ due_date: due, duration_minutes: 60 }));
    expect(block!.startMs).toBe(due - 60 * 60_000);
  });

  it("带时刻但未设时长 → 默认 30 分钟块", () => {
    const due = at(day0(), 10);
    const block = taskTimeBlock(mk({ due_date: due }));
    expect(block!.durationMin).toBe(DEFAULT_BLOCK_MINUTES);
    expect(block!.startMs).toBe(due - DEFAULT_BLOCK_MINUTES * 60_000);
  });

  it("两处都无时刻（纯日期/无日期）→ null，不出时间块", () => {
    expect(taskTimeBlock(mk({ due_date: day0(), start_date: day0() }))).toBeNull();
    expect(taskTimeBlock(mk({}))).toBeNull();
  });

  it("块所在日 = 起点所在本地日；完成态随行", () => {
    const block = taskTimeBlock(mk({ start_date: at(day0(2), 8), done: 1 }));
    expect(block!.dayStartMs).toBe(day0(2));
    expect(block!.done).toBe(true);
  });
});

describe("layoutTimeBlock（clamp 比例）", () => {
  const day = day0();
  const base: TaskTimeBlock = {
    taskId: 1,
    title: "t",
    startMs: at(day, 6),
    durationMin: 120,
    done: false,
    dayStartMs: day,
  };

  it("常规块：top/height 按当日比例", () => {
    const l = layoutTimeBlock(base, day);
    expect(l.topRatio).toBeCloseTo(6 / 24);
    expect(l.heightRatio).toBeCloseTo(2 / 24);
  });

  it("倒推跨零点：起点 clamp 到 0 点（贴顶渲染）", () => {
    const l = layoutTimeBlock({ ...base, startMs: at(day, 0) - 30 * 60_000, durationMin: 60 }, day);
    expect(l.topRatio).toBe(0);
    expect(l.heightRatio).toBeCloseTo(0.5 / 24);
  });

  it("跨午夜截断：终点 clamp 到 24 点，高度不满一格", () => {
    const l = layoutTimeBlock({ ...base, startMs: at(day, 23), durationMin: 180 }, day);
    expect(l.topRatio).toBeCloseTo(23 / 24);
    expect(l.heightRatio).toBeCloseTo(1 / 24);
  });
});

describe("blockDayIndex（周定位）", () => {
  it("周内 0-6；前后周 -1", () => {
    const weekStart = day0();
    const mkBlock = (dayOffset: number): TaskTimeBlock => ({
      taskId: 1,
      title: "t",
      startMs: at(day0(dayOffset), 9),
      durationMin: 30,
      done: false,
      dayStartMs: day0(dayOffset),
    });
    expect(blockDayIndex(mkBlock(0), weekStart)).toBe(0);
    expect(blockDayIndex(mkBlock(6), weekStart)).toBe(6);
    expect(blockDayIndex(mkBlock(-1), weekStart)).toBe(-1);
    expect(blockDayIndex(mkBlock(7), weekStart)).toBe(-1);
  });
});

describe("assignLanes（重叠分车道）", () => {
  it("互不重叠 → 全部车道 0", () => {
    const lanes = assignLanes([
      { topRatio: 0, heightRatio: 0.1 },
      { topRatio: 0.2, heightRatio: 0.1 },
    ]);
    expect(lanes).toEqual([0, 0]);
  });

  it("两块重叠 → 车道 0/1；不重叠不占新车道", () => {
    const lanes = assignLanes([
      { topRatio: 0.0, heightRatio: 0.2 },
      { topRatio: 0.1, heightRatio: 0.2 },
      { topRatio: 0.3, heightRatio: 0.1 },
    ]);
    expect(lanes).toEqual([0, 1, 0]);
  });

  it("三块两两叠 → 车道 0/1/2（排序后贪心分配）", () => {
    const lanes = assignLanes([
      { topRatio: 0.4, heightRatio: 0.2 },
      { topRatio: 0.0, heightRatio: 0.5 },
      { topRatio: 0.1, heightRatio: 0.6 },
    ]);
    expect([...lanes].sort()).toEqual([0, 1, 2]);
  });

  it("空输入 → 空数组", () => {
    expect(assignLanes([])).toEqual([]);
  });
});
