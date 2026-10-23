import { describe, expect, it } from "vitest";

import type { UnusedAttachmentView } from "@/lib/tauri";
import {
  attachmentLabel,
  summarizeSelection,
  toggleAll,
} from "./unused-attachments-selection";

function item(hash: string, size: number, name = ""): UnusedAttachmentView {
  return {
    hash,
    original_name: name,
    mime_type: "application/octet-stream",
    size_bytes: size,
    is_uploaded: 0,
    is_local_cached: 1,
    created_at: 0,
  };
}

describe("summarizeSelection", () => {
  it("合计已勾选条数与体积，未全选时 allSelected 为 false", () => {
    const items = [item("a", 100), item("b", 250), item("c", 5)];
    expect(summarizeSelection(items, new Set(["a", "c"]))).toEqual({
      count: 2,
      bytes: 105,
      allSelected: false,
    });
  });

  it("空清单不算全选", () => {
    expect(summarizeSelection([], new Set())).toEqual({
      count: 0,
      bytes: 0,
      allSelected: false,
    });
  });
});

describe("toggleAll", () => {
  it("未全选时点击 → 勾选全部", () => {
    const items = [item("a", 1), item("b", 2)];
    expect([...toggleAll(items, new Set(["a"]))]).toEqual(["a", "b"]);
  });

  it("已全选时点击 → 清空", () => {
    const items = [item("a", 1), item("b", 2)];
    expect(toggleAll(items, new Set(["a", "b"])).size).toBe(0);
  });
});

describe("attachmentLabel", () => {
  it("有原始文件名时原样显示", () => {
    expect(attachmentLabel(item("abcdef123456789", 1, "报告.pdf"))).toBe("报告.pdf");
  });

  it("无文件名时用 hash 前 12 位兜底", () => {
    expect(attachmentLabel(item("abcdef1234567890", 1, "   "))).toBe("abcdef123456…");
  });
});
