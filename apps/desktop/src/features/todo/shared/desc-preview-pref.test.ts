/**
 * desc-preview-pref 纯函数测试
 *
 * vitest 全局 node 环境无 jsdom（vitest.config.ts 口径），localStorage
 * 用内存 stub 注入；被测函数本身对「无 localStorage」也有 try/catch 兜底。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  DESC_PREVIEW_DELAY_DEFAULT,
  getDescPreviewDelayMs,
  getDescPreviewEnabled,
  setDescPreviewDelayMs,
  setDescPreviewEnabled,
} from "./desc-preview-pref";
import { LS_DESC_PREVIEW_DELAY, LS_DESC_PREVIEW_ENABLED } from "./constants";

/** 内存 localStorage stub（足够覆盖 getItem/setItem/removeItem 路径） */
function stubStorage(): Storage {
  const map = new Map<string, string>();
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, String(v)),
    removeItem: (k) => void map.delete(k),
    clear: () => map.clear(),
    key: (i) => [...map.keys()][i] ?? null,
    get length() {
      return map.size;
    },
  } as Storage;
}

beforeEach(() => {
  vi.stubGlobal("localStorage", stubStorage());
});

afterEach(() => {
  localStorage.removeItem(LS_DESC_PREVIEW_ENABLED);
  localStorage.removeItem(LS_DESC_PREVIEW_DELAY);
  vi.unstubAllGlobals();
});

describe("getDescPreviewEnabled", () => {
  it("缺省时默认开启", () => {
    expect(getDescPreviewEnabled()).toBe(true);
  });

  it("写 0 后关闭、写 1 后开启", () => {
    setDescPreviewEnabled(false);
    expect(getDescPreviewEnabled()).toBe(false);
    setDescPreviewEnabled(true);
    expect(getDescPreviewEnabled()).toBe(true);
  });

  it("非法存量值视为关闭（严格 1/0 口径，防误读）", () => {
    localStorage.setItem(LS_DESC_PREVIEW_ENABLED, "yes");
    expect(getDescPreviewEnabled()).toBe(false);
  });
});

describe("getDescPreviewDelayMs", () => {
  it("缺省时回退默认 800ms", () => {
    expect(getDescPreviewDelayMs()).toBe(DESC_PREVIEW_DELAY_DEFAULT);
    expect(DESC_PREVIEW_DELAY_DEFAULT).toBe(800);
  });

  it("合法档位读写一致", () => {
    setDescPreviewDelayMs(1500);
    expect(getDescPreviewDelayMs()).toBe(1500);
  });

  it("非法存量值（NaN/负数/超大）回退默认", () => {
    localStorage.setItem(LS_DESC_PREVIEW_DELAY, "abc");
    expect(getDescPreviewDelayMs()).toBe(DESC_PREVIEW_DELAY_DEFAULT);
    localStorage.setItem(LS_DESC_PREVIEW_DELAY, "-5");
    expect(getDescPreviewDelayMs()).toBe(DESC_PREVIEW_DELAY_DEFAULT);
    localStorage.setItem(LS_DESC_PREVIEW_DELAY, "99999");
    expect(getDescPreviewDelayMs()).toBe(DESC_PREVIEW_DELAY_DEFAULT);
  });
});
