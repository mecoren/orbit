// apps/desktop/src/features/todo/shared/sidebar-collapsed.test.ts
// 窄窗侧栏折叠语义（07 报告 #21 接线 + 04 §二「<1024 自动折叠」设计要求）
import { describe, expect, it } from "vitest";

import { resolveSidebarCollapsed } from "./sidebar-collapsed";

describe("resolveSidebarCollapsed", () => {
  it("窄窗（<lg）且无手动状态 → 自动折叠", () => {
    expect(resolveSidebarCollapsed({ isNarrow: true, manual: null })).toBe(true);
  });

  it("宽窗（≥lg）且无手动状态 → 展开", () => {
    expect(resolveSidebarCollapsed({ isNarrow: false, manual: null })).toBe(false);
  });

  it("用户手动展开优先于窄窗自动折叠", () => {
    expect(resolveSidebarCollapsed({ isNarrow: true, manual: false })).toBe(false);
  });

  it("用户手动折叠优先于宽窗展开',手动值透传", () => {
    expect(resolveSidebarCollapsed({ isNarrow: false, manual: true })).toBe(true);
  });

  it("跨断点往返不丢手动状态语义（同输入同输出，纯函数）", () => {
    const a = resolveSidebarCollapsed({ isNarrow: true, manual: true });
    const b = resolveSidebarCollapsed({ isNarrow: true, manual: true });
    expect(a).toBe(b);
  });
});
