/**
 * holiday-meta 分支锁：自动更新口径短句、时间戳文案（含跨年补年前缀）、
 * 记账三行文案（失败态才亮「上次尝试 / 连续失败」）、tooltip 失败后缀。
 *
 * 时间戳断言一律用本地 `Date` 组件拼期望值，不写死字面量——CI 与本地时区
 * 不同时字面量会假红，而格式化本身走的是本地时区（与界面一致）。
 */
import { describe, expect, it } from "vitest";

import {
  holidayAutoLabel,
  holidayFailureSuffix,
  holidayMetaLines,
  holidayStampLabel,
} from "./holiday-meta";
import type { HolidayMeta } from "@/lib/tauri";

const baseMeta: HolidayMeta = {
  last_update_ms: 0,
  last_attempt_ms: 0,
  failure_count: 0,
  auto_enabled: true,
};

/** 本地 `M月d日 HH:mm` 期望值。
 *  断言的对象是**分支行为**（哪个字段出、要不要补年前缀、失败态给不给），
 *  数字本身用同一套本地格式化复算，避免写死字面量在别的时区机器上假红。 */
function localMd(d: Date): string {
  const two = (n: number) => n.toString().padStart(2, "0");
  return `${d.getMonth() + 1}月${d.getDate()}日 ${two(d.getHours())}:${two(d.getMinutes())}`;
}

describe("holidayAutoLabel", () => {
  it("开关两态各有短句（每月口径，不再有更新时刻）", () => {
    expect(holidayAutoLabel(true)).toBe("每月自动更新");
    expect(holidayAutoLabel(false)).toBe("已关闭每月自动更新");
  });
});

describe("holidayStampLabel", () => {
  it("本年只给月日时分", () => {
    const now = new Date();
    const stamp = new Date(now.getFullYear(), 8, 29, 15, 4);
    expect(holidayStampLabel(stamp.getTime(), now)).toBe(localMd(stamp));
  });

  it("非本年补年份前缀（跨年未开机时看不出是哪一年）", () => {
    const now = new Date();
    const stamp = new Date(now.getFullYear() - 1, 11, 31, 8, 0);
    expect(holidayStampLabel(stamp.getTime(), now)).toBe(
      `${stamp.getFullYear()}年${localMd(stamp)}`,
    );
  });
});

describe("holidayMetaLines", () => {
  it("无记账（未取到 meta）只给兜底文案，失败行不渲染", () => {
    expect(holidayMetaLines(undefined)).toEqual({
      lastUpdate: "尚未成功更新过",
      lastAttempt: null,
      failure: null,
    });
  });

  it("从未成功但失败计数为 0：同样不亮失败行", () => {
    const lines = holidayMetaLines({ ...baseMeta, last_attempt_ms: 123 });
    expect(lines.lastUpdate).toBe("尚未成功更新过");
    expect(lines.lastAttempt).toBeNull();
    expect(lines.failure).toBeNull();
  });

  it("正常态：只有成功时间，无尝试时刻与失败计数", () => {
    const now = new Date();
    const d = new Date(now.getFullYear(), 8, 30, 9, 30);
    const lines = holidayMetaLines(
      { ...baseMeta, last_update_ms: d.getTime(), last_attempt_ms: d.getTime() },
      now,
    );
    expect(lines.lastUpdate).toBe(`上次成功更新：${localMd(d)}`);
    expect(lines.lastAttempt).toBeNull();
    expect(lines.failure).toBeNull();
  });

  it("失败态：成功时间 + 上次尝试 + 连续失败计数三行齐出", () => {
    const now = new Date();
    const ok = new Date(now.getFullYear(), 8, 1, 8, 0);
    const attempt = new Date(now.getFullYear(), 8, 30, 15, 20);
    const lines = holidayMetaLines(
      {
        ...baseMeta,
        last_update_ms: ok.getTime(),
        last_attempt_ms: attempt.getTime(),
        failure_count: 3,
      },
      now,
    );
    expect(lines.lastUpdate).toBe(`上次成功更新：${localMd(ok)}`);
    expect(lines.lastAttempt).toBe(`上次尝试：${localMd(attempt)}`);
    expect(lines.failure).toBe("连续失败 3 次（旧缓存保留可用）");
  });

  it("失败计数存在但从未尝试过：不产生空尝试行", () => {
    const lines = holidayMetaLines({ ...baseMeta, failure_count: 2 });
    expect(lines.failure).toBe("连续失败 2 次（旧缓存保留可用）");
    expect(lines.lastAttempt).toBeNull();
  });
});

describe("holidayFailureSuffix", () => {
  it("失败态给 tooltip 后缀，正常态为空串", () => {
    expect(holidayFailureSuffix(undefined)).toBe("");
    expect(holidayFailureSuffix(baseMeta)).toBe("");
    expect(holidayFailureSuffix({ ...baseMeta, failure_count: 3 })).toBe(
      "，连续失败 3 次",
    );
  });
});
