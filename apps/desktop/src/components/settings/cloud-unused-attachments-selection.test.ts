import { describe, expect, it } from "vitest";

import type { CloudUnusedAttachmentView } from "@/lib/tauri";
import {
  cloudAttachmentLabel,
  cloudItemBytes,
  cloudKindLabel,
  formatCloudLastModified,
  summarizeCloudSelection,
  toggleAllCloud,
} from "./cloud-unused-attachments-selection";

function item(
  hash: string,
  overrides: Partial<CloudUnusedAttachmentView> = {},
): CloudUnusedAttachmentView {
  return {
    hash,
    cipher_bytes: 0,
    last_modified: 0,
    kind: "whole",
    original_name: "",
    size_bytes: 0,
    is_local_cached: 0,
    is_uploaded: 0,
    ...overrides,
  };
}

describe("cloudItemBytes", () => {
  it("密文体积优先", () => {
    expect(cloudItemBytes(item("a", { cipher_bytes: 120, size_bytes: 100 }))).toBe(120);
  });

  it("分片形态没有密文长度时回退本地账本明文体积", () => {
    expect(cloudItemBytes(item("a", { cipher_bytes: 0, size_bytes: 100 }))).toBe(100);
  });

  it("两边都缺记 0（UI 用「体积未知」兜底）", () => {
    expect(cloudItemBytes(item("a"))).toBe(0);
  });
});

describe("summarizeCloudSelection", () => {
  it("合计已勾选条数与体积（密文优先口径）", () => {
    const items = [
      item("a", { cipher_bytes: 100 }),
      item("b", { cipher_bytes: 0, size_bytes: 250 }),
      item("c", { cipher_bytes: 5 }),
    ];
    expect(summarizeCloudSelection(items, new Set(["a", "b"]))).toEqual({
      count: 2,
      bytes: 350,
      allSelected: false,
    });
  });

  it("空清单不算全选", () => {
    expect(summarizeCloudSelection([], new Set())).toEqual({
      count: 0,
      bytes: 0,
      allSelected: false,
    });
  });
});

describe("toggleAllCloud", () => {
  it("未全选时点击 → 勾选全部", () => {
    const items = [item("a"), item("b")];
    expect([...toggleAllCloud(items, new Set(["a"]))]).toEqual(["a", "b"]);
  });

  it("已全选时点击 → 清空", () => {
    const items = [item("a"), item("b")];
    expect(toggleAllCloud(items, new Set(["a", "b"])).size).toBe(0);
  });
});

describe("cloudAttachmentLabel", () => {
  it("有原始文件名时原样显示", () => {
    expect(cloudAttachmentLabel(item("abcdef123456789", { original_name: "报告.pdf" }))).toBe(
      "报告.pdf",
    );
  });

  it("账本无记录时用 hash 前 12 位兜底", () => {
    expect(cloudAttachmentLabel(item("abcdef1234567890"))).toBe("abcdef123456…");
  });
});

describe("cloudKindLabel", () => {
  it("三种形态各有明确文案（两种布局都要删，不能让用户误以为只删一份）", () => {
    expect(cloudKindLabel("whole")).toBe("整包");
    expect(cloudKindLabel("chunked")).toBe("分片");
    expect(cloudKindLabel("both")).toBe("整包+分片");
  });
});

describe("formatCloudLastModified", () => {
  it("服务端未提供 mtime 时不给假时间", () => {
    expect(formatCloudLastModified(0)).toBe("时间未知");
    expect(formatCloudLastModified(-1)).toBe("时间未知");
  });

  it("按本地时区格式化为 YYYY-MM-DD", () => {
    const secs = new Date(2026, 9, 23, 12, 0, 0).getTime() / 1000;
    expect(formatCloudLastModified(secs)).toBe("2026-10-23");
  });
});
