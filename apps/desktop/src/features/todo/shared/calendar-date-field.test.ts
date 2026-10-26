import { describe, expect, it } from "vitest";

import {
  calendarDateFieldLabel,
  calendarTaskDateMs,
  parseCalendarDateField,
  rescheduleStartDate,
} from "./calendar-date-field";

describe("parseCalendarDateField 持久化值解析", () => {
  it("只认 start，其余回落 due（历史默认）", () => {
    expect(parseCalendarDateField("start")).toBe("start");
    expect(parseCalendarDateField("due")).toBe("due");
    expect(parseCalendarDateField(null)).toBe("due");
    expect(parseCalendarDateField("")).toBe("due");
    expect(parseCalendarDateField("Start")).toBe("due");
  });
});

describe("calendarTaskDateMs 口径取值", () => {
  const task = { due_date: 100, start_date: 200 };

  it("due / start 各取各的字段，缺失不回落另一字段", () => {
    expect(calendarTaskDateMs(task, "due")).toBe(100);
    expect(calendarTaskDateMs(task, "start")).toBe(200);
    expect(calendarTaskDateMs({ due_date: 100, start_date: null }, "start")).toBeNull();
    expect(calendarTaskDateMs({ due_date: null, start_date: 200 }, "due")).toBeNull();
  });
});

describe("calendarDateFieldLabel 空态/提示文案", () => {
  it("两种口径各给中文标签", () => {
    expect(calendarDateFieldLabel("due")).toBe("截止日期");
    expect(calendarDateFieldLabel("start")).toBe("开始日期");
  });
});

describe("rescheduleStartDate 拖拽改开始日期", () => {
  it("零点原值保持零点（不升级 18:00）", () => {
    const orig = new Date(2026, 8, 10, 0, 0, 0, 0).getTime();
    const target = new Date(2026, 8, 20);
    expect(rescheduleStartDate(orig, target)).toBe(
      new Date(2026, 8, 20, 0, 0, 0, 0).getTime(),
    );
  });

  it("带时刻原值保留时分秒只换日期", () => {
    const orig = new Date(2026, 8, 10, 15, 30, 0, 0).getTime();
    const target = new Date(2026, 8, 20, 3, 0, 0, 0);
    expect(rescheduleStartDate(orig, target)).toBe(
      new Date(2026, 8, 20, 15, 30, 0, 0).getTime(),
    );
  });

  it("同日返回 null（含零点同日）", () => {
    const orig = new Date(2026, 8, 10, 15, 30, 0, 0).getTime();
    expect(rescheduleStartDate(orig, new Date(2026, 8, 10))).toBeNull();
    expect(
      rescheduleStartDate(new Date(2026, 8, 10).getTime(), new Date(2026, 8, 10)),
    ).toBeNull();
  });

  it("无原值兜底目标日零点", () => {
    expect(rescheduleStartDate(null, new Date(2026, 8, 20))).toBe(
      new Date(2026, 8, 20, 0, 0, 0, 0).getTime(),
    );
  });

  it("跨年边界正确换算", () => {
    const orig = new Date(2026, 11, 30, 9, 0, 0, 0).getTime();
    expect(rescheduleStartDate(orig, new Date(2027, 0, 2))).toBe(
      new Date(2027, 0, 2, 9, 0, 0, 0).getTime(),
    );
  });
});
