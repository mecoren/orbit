/**
 * sync-status 纯函数单测（左上角云图标的口径锁定）
 *
 * 覆盖：状态派生优先级（未配置 > 未就绪 > 运行态）、上次/下次同步时间文案、
 * 「下次自动同步」估算边界（开关/间隔/无历史）、进度与结果摘要文案。
 */
import { describe, expect, it } from "vitest";

import {
  deriveSyncStatus,
  estimateNextSyncAt,
  formatLastSynced,
  formatNextSync,
  syncProgressText,
  syncResultSummary,
  syncStatusLabel,
  type SyncRunPhase,
} from "./sync-status";

const MINUTE_MS = 60_000;

describe("deriveSyncStatus", () => {
  it("无激活配置时恒为 unconfigured（即使运行态非 idle）", () => {
    expect(
      deriveSyncStatus({
        hasConfig: false,
        hasPassword: true,
        isUnlocked: true,
        runPhase: "syncing",
      }),
    ).toBe("unconfigured");
  });

  it("有配置但未设置同步密码时归 locked", () => {
    expect(
      deriveSyncStatus({
        hasConfig: true,
        hasPassword: false,
        isUnlocked: false,
        runPhase: "idle",
      }),
    ).toBe("locked");
  });

  it("已设置密码但未解锁时归 locked", () => {
    expect(
      deriveSyncStatus({
        hasConfig: true,
        hasPassword: true,
        isUnlocked: false,
        runPhase: "idle",
      }),
    ).toBe("locked");
  });

  it("已配置且已解锁时跟随运行态", () => {
    const phases: SyncRunPhase[] = ["idle", "syncing", "success", "error"];
    for (const runPhase of phases) {
      expect(
        deriveSyncStatus({ hasConfig: true, hasPassword: true, isUnlocked: true, runPhase }),
      ).toBe(runPhase);
    }
  });
});

describe("syncStatusLabel", () => {
  it("各状态给出可读中文文案", () => {
    expect(syncStatusLabel("unconfigured")).toBe("未配置云同步");
    expect(syncStatusLabel("locked", true)).toBe("同步密码已锁定");
    expect(syncStatusLabel("locked", false)).toBe("未设置同步密码");
    expect(syncStatusLabel("idle")).toBe("已就绪");
    expect(syncStatusLabel("syncing")).toBe("正在同步…");
    expect(syncStatusLabel("success")).toBe("同步完成");
    expect(syncStatusLabel("error")).toBe("同步失败");
  });
});

describe("formatLastSynced", () => {
  it("null / 0 均显示从未同步", () => {
    expect(formatLastSynced(null)).toBe("从未同步");
    expect(formatLastSynced(0)).toBe("从未同步");
  });

  it("毫秒时间戳按本地时间展示（与设置页同步卡同口径）", () => {
    const ts = Date.UTC(2026, 8, 17, 3, 30);
    expect(formatLastSynced(ts)).toBe(new Date(ts).toLocaleString());
  });
});

describe("estimateNextSyncAt", () => {
  const base = {
    auto_sync_enabled: true,
    interval_minutes: 60,
    last_synced_at: 1_700_000_000_000,
  };

  it("正常：上次同步时间 + 间隔分钟", () => {
    expect(estimateNextSyncAt(base)).toBe(base.last_synced_at + 60 * MINUTE_MS);
  });

  it("关闭定时同步时无估算", () => {
    expect(estimateNextSyncAt({ ...base, auto_sync_enabled: false })).toBeNull();
  });

  it("间隔 <= 0 时无估算", () => {
    expect(estimateNextSyncAt({ ...base, interval_minutes: 0 })).toBeNull();
  });

  it("从未同步（null / 0）时无估算", () => {
    expect(estimateNextSyncAt({ ...base, last_synced_at: null })).toBeNull();
    expect(estimateNextSyncAt({ ...base, last_synced_at: 0 })).toBeNull();
  });
});

describe("formatNextSync", () => {
  it("无估算值说明未启用定时同步", () => {
    expect(formatNextSync(null)).toBe("未启用定时同步");
  });

  it("有估算值带「约」前缀并按本地时间展示", () => {
    const ts = Date.UTC(2026, 8, 17, 4, 30);
    expect(formatNextSync(ts)).toBe(`约 ${new Date(ts).toLocaleString()}`);
  });
});

describe("syncProgressText", () => {
  it("各阶段映射为中文文案（含计数）", () => {
    expect(syncProgressText({ phase: "starting" })).toBe("准备同步…");
    expect(
      syncProgressText({ phase: "pushing", display_name: "任务", current: 1, total: 10 }),
    ).toBe("正在上传任务 1/10…");
    expect(
      syncProgressText({ phase: "pulling", display_name: "项目", current: 2, total: 3 }),
    ).toBe("正在下载项目 2/3…");
    expect(syncProgressText({ phase: "merging", display_name: "标签" })).toBe("正在合并标签…");
    expect(syncProgressText({ phase: "local_data_applied" })).toBe("本地数据已更新");
    expect(syncProgressText({ phase: "attachments" })).toBe("同步附件中…");
  });

  it("done / error 终态文案", () => {
    expect(syncProgressText({ phase: "done" })).toBe("同步完成");
    expect(syncProgressText({ phase: "error", message: "连接超时" })).toBe("同步失败：连接超时");
    expect(syncProgressText({ phase: "error" })).toBe("同步失败");
  });
});

describe("syncResultSummary", () => {
  it("忙时跳过明确提示已有任务", () => {
    expect(
      syncResultSummary({ pushed_modules: 0, pulled_modules: 0, skipped: true, errors: [] }),
    ).toBe("已有同步任务在进行中");
  });

  it("正常结果含推拉模块数", () => {
    expect(
      syncResultSummary({ pushed_modules: 2, pulled_modules: 1, skipped: false, errors: [] }),
    ).toBe("同步完成：推送 2 模块 / 拉取 1 模块");
  });

  it("有非致命错误时追加计数", () => {
    expect(
      syncResultSummary({
        pushed_modules: 2,
        pulled_modules: 1,
        skipped: false,
        errors: ["附件上传失败", "标签下拉失败"],
      }),
    ).toBe("同步完成：推送 2 模块 / 拉取 1 模块（2 个非致命错误）");
  });
});
