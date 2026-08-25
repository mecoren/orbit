import { afterEach, describe, expect, it, vi } from "vitest";

import { createDelayedRun } from "./undo-delete";

afterEach(() => vi.useRealTimers());

describe("createDelayedRun", () => {
  it("超时后执行一次", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    createDelayedRun(run, 1000);
    expect(run).not.toHaveBeenCalled();
    vi.advanceTimersByTime(999);
    expect(run).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(run).toHaveBeenCalledTimes(1);
  });

  it("cancel 拦截执行并返回 true", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    const d = createDelayedRun(run, 1000);
    expect(d.cancel()).toBe(true);
    vi.advanceTimersByTime(5000);
    expect(run).not.toHaveBeenCalled();
  });

  it("重复 cancel 第二次返回 false", () => {
    vi.useFakeTimers();
    const d = createDelayedRun(vi.fn(), 1000);
    expect(d.cancel()).toBe(true);
    expect(d.cancel()).toBe(false);
  });

  it("flush 立即执行且计时器不再触发", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    const d = createDelayedRun(run, 1000);
    d.flush();
    expect(run).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(5000);
    expect(run).toHaveBeenCalledTimes(1);
    expect(d.cancel()).toBe(false);
  });
});
